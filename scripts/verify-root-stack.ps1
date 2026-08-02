[CmdletBinding()]
param(
  [string]$Serial
)

$ErrorActionPreference = 'Stop'

function Invoke-AdbRoot([string]$Command) {
  $adbArgs = @()
  if ($Serial) { $adbArgs += @('-s', $Serial) }
  $adbArgs += @('shell', 'su', '-c', $Command)
  $output = & adb @adbArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "adb root command failed: $Command`n$output"
  }
  return ($output -join "`n").Trim()
}

function Assert-Equal([string]$Name, [string]$Actual, [string]$Expected) {
  if ($Actual -ne $Expected) {
    throw "$Name mismatch: expected '$Expected', got '$Actual'"
  }
  Write-Host "OK   $Name = $Actual"
}

function Assert-AtLeast([string]$Name, [long]$Actual, [long]$Minimum) {
  if ($Actual -lt $Minimum) {
    throw "$Name is stale: $Actual < boot epoch $Minimum"
  }
  Write-Host "OK   $Name timestamp is current-boot"
}

$null = Invoke-AdbRoot 'id'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$uptime = [double](Invoke-AdbRoot 'cut -d" " -f1 /proc/uptime')
$bootEpoch = [long]($now - $uptime)

Assert-Equal 'SuSFS version' (Invoke-AdbRoot '/data/adb/ksu/bin/ksu_susfs show version') 'v2.2.0'

$expectedFeatures = @(
  'CONFIG_KSU_SUSFS_SUS_PATH',
  'CONFIG_KSU_SUSFS_SUS_MOUNT',
  'CONFIG_KSU_SUSFS_SUS_KSTAT',
  'CONFIG_KSU_SUSFS_SPOOF_UNAME',
  'CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS',
  'CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG',
  'CONFIG_KSU_SUSFS_OPEN_REDIRECT',
  'CONFIG_KSU_SUSFS_SUS_MAP'
)
$actualFeatures = (Invoke-AdbRoot '/data/adb/ksu/bin/ksu_susfs show enabled_features' -split '\r?\n') |
  Where-Object { $_ -and $_.Trim() } |
  ForEach-Object { $_.Trim() }
foreach ($feature in $expectedFeatures) {
  if ($actualFeatures -notcontains $feature) {
    throw "SuSFS feature missing: $feature"
  }
}
Write-Host "OK   SuSFS enabled feature surface ($($actualFeatures.Count) entries)"

$postFsLog = '/data/adb/ksu/log/dmesg.log'
$postFsMtime = [long](Invoke-AdbRoot "stat -c %Y $postFsLog")
Assert-AtLeast 'KernelSU dmesg log' $postFsMtime $bootEpoch
$postFs = Invoke-AdbRoot "grep -E 'post-fs-data triggered|post-fs-data.*exec|on_post_fs_data' $postFsLog || true"
if (-not $postFs) {
  throw 'No current-boot KernelSU post-fs-data event was recorded'
}
Write-Host 'OK   KernelSU post-fs-data event recorded this boot'

$activePath = '/data/adb/ksu/susfs4ksu/logs/susfs_active'
$activeMtime = [long](Invoke-AdbRoot "stat -c %Y $activePath")
Assert-AtLeast 'SuSFS activation marker' $activeMtime $bootEpoch
$active = Invoke-AdbRoot "cat $activePath"
if (-not $active.Trim()) {
  throw 'SuSFS activation marker is empty'
}
Write-Host 'OK   SuSFS activation marker is non-empty and current-boot'

$rzState = Invoke-AdbRoot 'test -s /data/adb/rezygisk/state.json && cat /data/adb/rezygisk/state.json || true'
if ($rzState) {
  Write-Host 'OK   ReZygisk state.json exists (module-specific injection validation remains separate)'
} else {
  Write-Warning 'ReZygisk state.json is absent; this is reported but not failed because ReZygisk is outside this repair branch.'
}

Write-Host 'verify-root-stack: OK'
