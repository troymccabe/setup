#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Ephemeral Hyper-V-backed GitHub Actions runner — one-shot setup (Windows).

The Windows sibling of mac/runner/setup and linux/runner/setup. Same shape —
JIT runner registration + a run-one-job-then-destroy orchestrator + a boot
service — but the isolation primitive is a Hyper-V VM booted from a
differencing disk off a read-only base VHDX, the control channel is
PowerShell Direct (no SSH/WinRM), and the boot service is a Scheduled Task.

Named setup.ps1 (not bare "setup") because PowerShell needs the extension to
run natively on Windows.

Run from an elevated PowerShell, once per base image you want to serve. Inputs
come from environment variables (so `iwr | iex` works) or matching -Params:

    $env:GH_ORG='YourOrg'; $env:GH_PAT='ghp_xxxxx'
    $env:BASE_VHDX='D:\images\win2022-base.vhdx'; $env:VM_PASS='<base admin pw>'
    .\windows\runner\setup.ps1

Or straight from the raw file:

    $env:GH_ORG='YourOrg'; $env:GH_PAT='ghp_xxxxx'
    $env:BASE_VHDX='D:\images\win2022-base.vhdx'; $env:VM_PASS='<base admin pw>'
    iwr https://raw.githubusercontent.com/troymccabe/setup/main/windows/runner/setup.ps1 | iex

REQUIRED (env var / -Param):
  GH_ORG      / -GhOrg        GitHub organization
  GH_PAT      / -GhPat        PAT with "Self-hosted runners (Admin)" on the org
  BASE_VHDX   / -BaseVhdxPath  Path to a sysprepped, Gen2/UEFI Windows base VHDX
                               with a known local admin. This script provisions
                               the ORCHESTRATION; building the base image is a
                               one-time prerequisite (see README).
  VM_PASS     / -VmPass        Password of the base image's local admin account

OPTIONAL (defaults shown):
  VM_USER          / -VmUser          Base image local admin              [Administrator]
  IMAGE_LABEL      / -ImageLabel      Label for this base (e.g. server2022) [windows]
  RUNNER_GROUP     / -RunnerGroup     Org runner group                    [windows-runners]
  SHARED_LABEL     / -SharedLabel     Fleet label                         [windows-runner]
  HOST_LABEL       / -HostLabel       Per-host label                      [<hostname, lowercased>]
  EXTRA_LABELS     / -ExtraLabels     Comma-separated extra labels        [""]
  SCOPE_REPO       / -ScopeRepo       "owner/repo" to gate the group to   [""]
  SWITCH_NAME      / -SwitchName      Hyper-V switch for guest internet   [Default Switch]
  VM_MEMORY_MB     / -VmMemoryMb      Per-VM memory                       [8192]
  VM_CPU_COUNT     / -VmCpuCount      Per-VM CPUs                         [4]
  HOST_RESERVE_MB  / -HostReserveMb   RAM kept free for the host          [4096]
  SECURE_BOOT      / -SecureBoot      Gen2 secure boot ($true/$false)     [$true]
  NESTED_VIRT      / -NestedVirt      Expose virt extensions to guests    [$true]
                                      so Docker / nested containers work (needs
                                      Docker in the base image + a nesting-capable
                                      host; falls back gracefully if unsupported)
  CONFIG_DIR       / -ConfigDir       Config + scripts location           [%ProgramData%\gha-runner\<image>]

Serving multiple Windows versions:
  Each run provisions ONE base image as its own orchestrator (own task, own
  config dir, own IMAGE_LABEL). Run once per base VHDX; they coexist on the
  host and compete for RAM via HOST_RESERVE_MB. Workflows target a version by
  label: runs-on: [self-hosted, windows-runner] or [self-hosted, server2022].

Re-running is idempotent — the runner group + repo scoping are no-op on the
second pass, the orchestrator + scheduled task are overwritten, the task is
restarted.

Surviving reboots:
  Installs a Scheduled Task (AtStartup, SYSTEM, highest privileges), so it
  starts at boot with nobody logged in. Plain build/test jobs run headless;
  only interactive-desktop jobs would need guest autologon.

Requires: Windows 11 or Server 2016+ with Hyper-V, run as Administrator.
#>
[CmdletBinding()]
param(
  [string]$GhOrg         = $env:GH_ORG,
  [string]$GhPat         = $env:GH_PAT,
  [string]$BaseVhdxPath  = $env:BASE_VHDX,
  [string]$VmPass        = $env:VM_PASS,
  [string]$VmUser        = $(if ($env:VM_USER)         { $env:VM_USER }         else { 'Administrator' }),
  [string]$ImageLabel    = $(if ($env:IMAGE_LABEL)     { $env:IMAGE_LABEL }     else { 'windows' }),
  [string]$RunnerGroup   = $(if ($env:RUNNER_GROUP)    { $env:RUNNER_GROUP }    else { 'windows-runners' }),
  [string]$SharedLabel   = $(if ($env:SHARED_LABEL)    { $env:SHARED_LABEL }    else { 'windows-runner' }),
  [string]$HostLabel     = $(if ($env:HOST_LABEL)      { $env:HOST_LABEL }      else { $env:COMPUTERNAME.ToLower() }),
  [string]$ExtraLabels   = $env:EXTRA_LABELS,
  [string]$ScopeRepo     = $env:SCOPE_REPO,
  [string]$SwitchName    = $(if ($env:SWITCH_NAME)     { $env:SWITCH_NAME }     else { 'Default Switch' }),
  [int]   $VmMemoryMb    = $(if ($env:VM_MEMORY_MB)    { [int]$env:VM_MEMORY_MB }    else { 8192 }),
  [int]   $VmCpuCount    = $(if ($env:VM_CPU_COUNT)    { [int]$env:VM_CPU_COUNT }    else { 4 }),
  [int]   $HostReserveMb = $(if ($env:HOST_RESERVE_MB) { [int]$env:HOST_RESERVE_MB } else { 4096 }),
  [bool]  $SecureBoot    = $(if ($env:SECURE_BOOT)     { [bool]::Parse($env:SECURE_BOOT) } else { $true }),
  [bool]  $NestedVirt    = $(if ($env:NESTED_VIRT)     { [bool]::Parse($env:NESTED_VIRT) } else { $true }),
  [string]$ConfigDir     = $env:CONFIG_DIR
)

$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host "`n==> $m" }

function Get-Slug([string]$s) {
  ($s.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
}

# -------------------------------------------------------------------------
# Required inputs
# -------------------------------------------------------------------------
foreach ($pair in @(@('GH_ORG', $GhOrg), @('GH_PAT', $GhPat), @('BASE_VHDX', $BaseVhdxPath), @('VM_PASS', $VmPass))) {
  if ([string]::IsNullOrWhiteSpace($pair[1])) { throw "$($pair[0]) must be set" }
}

$OrgSlug   = Get-Slug $GhOrg
$ImageSlug = Get-Slug $ImageLabel
if ([string]::IsNullOrWhiteSpace($ConfigDir)) {
  $ConfigDir = Join-Path $env:ProgramData "gha-runner\$ImageSlug"
}
$TaskName       = "gha-runner-$OrgSlug-$ImageSlug"
$InstancePrefix = "gha-$ImageSlug-"
$VhdDir         = Join-Path $ConfigDir 'vhd'
$ConfigFile     = Join-Path $ConfigDir 'config.json'
$OrchScript     = Join-Path $ConfigDir 'orchestrator.ps1'

switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { $ArchLabel = 'X64' }
  'ARM64' { $ArchLabel = 'ARM64' }
  default { throw "unsupported host arch $($env:PROCESSOR_ARCHITECTURE)" }
}

$ExtraLabelList = @()
if (-not [string]::IsNullOrWhiteSpace($ExtraLabels)) {
  $ExtraLabelList = @($ExtraLabels -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# -------------------------------------------------------------------------
# Sanity checks
# -------------------------------------------------------------------------
Step 'Sanity checks'
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
  throw 'This script is for Windows — use mac/ or linux/runner on other platforms.'
}
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue) -or ($hv -and $hv.State -ne 'Enabled')) {
  Step 'Enabling Hyper-V (a reboot will be required, then re-run this script)'
  if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools   # Server
  } else {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart   # client
  }
  Write-Host 'Hyper-V enabled. Reboot, then run this script again.' -ForegroundColor Yellow
  return
}
if (-not (Test-Path -LiteralPath $BaseVhdxPath)) {
  throw "BASE_VHDX not found: $BaseVhdxPath (build a base image first — see README)"
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
  throw "Hyper-V switch '$SwitchName' not found. Pass -SwitchName for an existing switch, " +
        "or create one (e.g. a NAT switch). 'Default Switch' exists on Windows client SKUs."
}
Write-Host "  $([System.Environment]::OSVersion.VersionString), org=$GhOrg, image=$ImageLabel ($ArchLabel) ✓"

# -------------------------------------------------------------------------
# GitHub API helpers + runner group / repo scoping (mirrors mac + linux)
# -------------------------------------------------------------------------
function Invoke-GhApi {
  param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Url, $Body)
  $headers = @{
    Authorization          = "Bearer $GhPat"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
  if ($null -ne $Body) {
    Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $Body -ContentType 'application/json'
  } else {
    Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers
  }
}

Step "Ensuring runner group '$RunnerGroup' exists"
$groups  = Invoke-GhApi -Url "https://api.github.com/orgs/$GhOrg/actions/runner-groups"
$groupId = ($groups.runner_groups | Where-Object { $_.name -eq $RunnerGroup } | Select-Object -First 1).id
if (-not $groupId) {
  $visibility = if ($ScopeRepo) { 'selected' } else { 'all' }
  $body = @{ name = $RunnerGroup; visibility = $visibility; selected_repository_ids = @(); allows_public_repositories = $false } | ConvertTo-Json
  $groupId = (Invoke-GhApi -Method POST -Url "https://api.github.com/orgs/$GhOrg/actions/runner-groups" -Body $body).id
  Write-Host "  created group id=$groupId (visibility=$visibility)"
} else {
  Write-Host "  found existing group id=$groupId"
}
if ($ScopeRepo) {
  Step "Scoping group to $ScopeRepo"
  $repoId = (Invoke-GhApi -Url "https://api.github.com/repos/$ScopeRepo").id
  Invoke-GhApi -Method PUT -Url "https://api.github.com/orgs/$GhOrg/actions/runner-groups/$groupId/repositories/$repoId" | Out-Null
  Write-Host "  repo id=$repoId added to group"
}

# -------------------------------------------------------------------------
# Persist config (locked down to SYSTEM + Administrators — holds the PAT
# and the VM password)
# -------------------------------------------------------------------------
Step "Writing config to $ConfigFile"
New-Item -ItemType Directory -Force -Path $ConfigDir, $VhdDir | Out-Null
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($id in 'SYSTEM', 'BUILTIN\Administrators') {
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
      $id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
Set-Acl -Path $ConfigDir -AclObject $acl

@{
  GhOrg = $GhOrg; GhPat = $GhPat; RunnerGroup = $RunnerGroup
  SharedLabel = $SharedLabel; HostLabel = $HostLabel; ImageLabel = $ImageLabel
  ExtraLabels = $ExtraLabelList; ScopeRepo = $ScopeRepo; ArchLabel = $ArchLabel
  BaseVhdxPath = $BaseVhdxPath; VhdDir = $VhdDir; InstancePrefix = $InstancePrefix
  VmUser = $VmUser; VmPass = $VmPass; VmMemoryMb = $VmMemoryMb; VmCpuCount = $VmCpuCount
  HostReserveMb = $HostReserveMb; SwitchName = $SwitchName; SecureBoot = $SecureBoot
  NestedVirt = $NestedVirt
} | ConvertTo-Json | Set-Content -LiteralPath $ConfigFile -Encoding UTF8

# -------------------------------------------------------------------------
# Orchestrator
# -------------------------------------------------------------------------
Step "Writing $OrchScript"
$orchestrator = @'
# Ephemeral Hyper-V GHA runner orchestrator. Generated by windows/runner/setup.ps1.
# Loops: differencing disk off base VHDX -> boot VM -> install runner via
# PowerShell Direct -> run one JIT ephemeral job -> destroy VM.
param([string]$ConfigDir = "$env:ProgramData\gha-runner")

$ErrorActionPreference = 'Continue'
Start-Transcript -Path (Join-Path $ConfigDir 'orchestrator.log') -Append | Out-Null
$c = Get-Content -LiteralPath (Join-Path $ConfigDir 'config.json') -Raw | ConvertFrom-Json

$sec  = ConvertTo-SecureString $c.VmPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($c.VmUser, $sec)

function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" }

function Invoke-GhApi {
  param([string]$Method = 'GET', [string]$Url, $Body)
  $h = @{ Authorization = "Bearer $($c.GhPat)"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
  if ($null -ne $Body) { Invoke-RestMethod -Method $Method -Uri $Url -Headers $h -Body $Body -ContentType 'application/json' }
  else { Invoke-RestMethod -Method $Method -Uri $Url -Headers $h }
}

function Get-GroupId {
  (Invoke-GhApi -Url "https://api.github.com/orgs/$($c.GhOrg)/actions/runner-groups").runner_groups |
    Where-Object { $_.name -eq $c.RunnerGroup } | Select-Object -First 1 -ExpandProperty id
}

function Remove-Instance($name) {
  $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
  if ($vm) {
    $disks = @($vm.HardDrives.Path)
    Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $name -Force -ErrorAction SilentlyContinue
    foreach ($d in $disks) {
      if ($d -and (Test-Path -LiteralPath $d) -and $d -ne $c.BaseVhdxPath) {
        Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Get-FreeMb { [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024) }
function Wait-Ram($needMb) {
  while ((Get-FreeMb) -lt $needMb) { Log "waiting for RAM (need $needMb MB, $(Get-FreeMb) MB free)"; Start-Sleep 15 }
}

# Reap orphans from a restart that killed us mid-job.
Get-VM | Where-Object { $_.Name -like "$($c.InstancePrefix)*" } | ForEach-Object { Remove-Instance $_.Name }

while ($true) {
  $sfx  = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
  $inst = "$($c.InstancePrefix)$sfx"
  $runnerName = "$($c.HostLabel)-$($c.ImageLabel)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Log "spawning instance=$inst runner=$runnerName"

  try { $gid = Get-GroupId } catch { Log "ERROR: group lookup failed: $_"; Start-Sleep 30; continue }
  if (-not $gid) { Log "ERROR: runner group '$($c.RunnerGroup)' not found"; Start-Sleep 60; continue }

  # JIT runners don't inherit platform labels, so the set must be COMPLETE.
  $labels = @('self-hosted', 'Windows', $c.ArchLabel, $c.SharedLabel, $c.HostLabel, $c.ImageLabel) + @($c.ExtraLabels)
  $body = @{ name = $runnerName; runner_group_id = $gid; labels = $labels; work_folder = '_work' } | ConvertTo-Json
  try { $jit = (Invoke-GhApi -Method POST -Url "https://api.github.com/orgs/$($c.GhOrg)/actions/runners/generate-jitconfig" -Body $body).encoded_jit_config }
  catch { Log "ERROR: generate-jitconfig failed: $_"; Start-Sleep 30; continue }
  if (-not $jit) { Log 'ERROR: empty JIT config'; Start-Sleep 30; continue }

  # Resolve the runner version on the HOST (authenticated -> 5000/hr) so the
  # guest (sharing a NAT IP) never hits the unauthenticated rate limit.
  try { $ver = (Invoke-GhApi -Url 'https://api.github.com/repos/actions/runner/releases/latest').tag_name.TrimStart('v') }
  catch { Log "ERROR: runner version lookup failed: $_"; Start-Sleep 30; continue }

  Wait-Ram ($c.VmMemoryMb + $c.HostReserveMb)

  $child = Join-Path $c.VhdDir "$inst.avhdx"
  try {
    New-VHD -Path $child -ParentPath $c.BaseVhdxPath -Differencing | Out-Null
    New-VM -Name $inst -MemoryStartupBytes ($c.VmMemoryMb * 1MB) -VHDPath $child -Generation 2 -SwitchName $c.SwitchName | Out-Null
    Set-VMProcessor -VMName $inst -Count $c.VmCpuCount
    Set-VMMemory -VMName $inst -DynamicMemoryEnabled $false
    if ($c.SecureBoot) { Set-VMFirmware -VMName $inst -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows }
    else { Set-VMFirmware -VMName $inst -EnableSecureBoot Off }
    # Expose virtualization extensions so Docker / Hyper-V-isolated or WSL2
    # containers work inside the guest — you can't control whether a workflow
    # runs `docker`. Requires Docker in the base image to be useful, and a
    # host CPU that supports nesting; if it doesn't, warn once and carry on
    # (plain jobs are unaffected). Dynamic memory is already off (required).
    if ($c.NestedVirt) {
      try {
        Set-VMProcessor -VMName $inst -ExposeVirtualizationExtensions $true
        # Nested guests' traffic egresses under a different MAC, so the VM's
        # adapter must permit spoofing or their networking silently breaks.
        Set-VMNetworkAdapter -VMName $inst -MacAddressSpoofing On
      } catch {
        if (-not $script:nestedWarned) {
          Log "WARN: host cannot expose virtualization extensions; Docker/nested jobs will fail ($($_.Exception.Message))"
          $script:nestedWarned = $true
        }
      }
    }
    Start-VM -Name $inst | Out-Null
  } catch {
    Log "ERROR: VM create/start failed: $_"; Remove-Instance $inst; Start-Sleep 30; continue
  }

  # Wait until PowerShell Direct works (guest booted, integration up, creds valid).
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    try { if (Invoke-Command -VMName $inst -Credential $cred -ScriptBlock { $true } -ErrorAction Stop) { $ready = $true; break } }
    catch { Start-Sleep 5 }
  }
  if (-not $ready) { Log 'ERROR: instance never became ready'; Remove-Instance $inst; Start-Sleep 30; continue }

  # Install + run the runner inside the guest via PowerShell Direct (no network
  # control channel). A fresh differencing disk has no runner cached; bake it
  # into the base image if the per-job download cost matters.
  $exit = Invoke-Command -VMName $inst -Credential $cred -ArgumentList $jit, $ver -ScriptBlock {
    param($jit, $ver)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $dir = 'C:\actions-runner'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Location $dir
    $url = "https://github.com/actions/runner/releases/download/v$ver/actions-runner-win-$arch-$ver.zip"
    Invoke-WebRequest -Uri $url -OutFile "$dir\runner.zip" -UseBasicParsing
    Expand-Archive -Path "$dir\runner.zip" -DestinationPath $dir -Force
    Remove-Item "$dir\runner.zip" -Force
    & "$dir\run.cmd" --jitconfig $jit
    return $LASTEXITCODE
  }
  Log "instance $inst runner exited (code=$exit)"

  Remove-Instance $inst
  if ($exit -ne 0) { Log 'backoff 30s on non-zero exit'; Start-Sleep 30 }
}
'@
Set-Content -LiteralPath $OrchScript -Value $orchestrator -Encoding UTF8

# -------------------------------------------------------------------------
# Scheduled Task (AtStartup, SYSTEM → starts at boot with no login)
# -------------------------------------------------------------------------
Step "Installing scheduled task ($TaskName)"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$OrchScript`" -ConfigDir `"$ConfigDir`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
Step 'Setup complete'
$extra = if ($ExtraLabelList) { ' + ' + ($ExtraLabelList -join ' + ') } else { '' }
@"

Service:
  * Task:     $TaskName  (Scheduled Task, AtStartup, SYSTEM)
  * Logs:     Get-Content -Wait '$ConfigDir\orchestrator.log'
  * Status:   Get-ScheduledTask $TaskName | Get-ScheduledTaskInfo
  * Stop:     Stop-ScheduledTask $TaskName
  * Restart:  Stop-ScheduledTask $TaskName; Start-ScheduledTask $TaskName
  * Remove:   Unregister-ScheduledTask $TaskName -Confirm:`$false

GitHub:
  * Each job spawns a fresh Hyper-V VM ($ImageLabel) with labels:
      self-hosted, Windows, $ArchLabel + $SharedLabel + $HostLabel + $ImageLabel$extra

Workflow usage:
  runs-on: [self-hosted, $SharedLabel]     # any Windows host in the fleet
  runs-on: [self-hosted, $ImageLabel]      # this base image
  runs-on: [self-hosted, $HostLabel]       # this specific host

Adding another Windows version on this host:
  Re-run with a different BASE_VHDX and IMAGE_LABEL. Each gets its own task
  and coexists here, competing for RAM via HOST_RESERVE_MB.
"@
