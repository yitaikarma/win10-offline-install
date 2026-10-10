<#
.SYNOPSIS
    Upgrade (or roll back) an offline DeepSeek Harness web installation.

.DESCRIPTION
    RUN THIS ON THE AIR-GAPPED WINDOWS 10 x64 HOST, as the same user that ran the
    installer. Bring a NEW bundle built by Make-DshWebOfflineBundle.ps1.

    Why an upgrade script at all: dsh has NO self-update command. An upgrade is
    "materialize a new version beside the old one, switch the launcher, restart" -
    and that is also what makes a rollback a one-liner. The install root is
    versioned for exactly this reason:

        C:\DshWeb\versions\0.2.0-rc.2\   still installed, still bootable
        C:\DshWeb\versions\0.2.1\        the new one
        C:\DshWeb\current.txt            which one bin\dsh.cmd launches

    Order of operations (the failure matrix assumes it):
      1. verify the bundle (manifest, hashes, release artifact)
      2. BACK UP %USERPROFILE%\.dsh  (sessions, profiles, credentials, settings)
      3. stop the running Web UI and wait for the port to be released
      4. install the new version into versions\<new> WITHOUT touching current.txt
      5. verify it (version, win32-x64 native packages, launcher)
      6. switch current.txt over
      7. start it and smoke-test (CLI + HTTP + activation URL)
    If step 4-7 fails, the script restores current.txt to the previous version,
    restarts it, and tells you so. State is a different story: a state migration
    does not roll back, so the backup from step 2 is the only way back - that is
    why it happens before anything else.

.PARAMETER BundleDir
    Folder of the NEW bundle. Defaults to this script's folder.

.PARAMETER InstallRoot
    Existing installation root. Default C:\DshWeb.

.PARAMETER DryRun
    Verify the bundle, print the plan and the rollback path, change nothing.

.PARAMETER Rollback
    Do not install anything: switch back to a previously installed version.

.PARAMETER RollbackTo
    Exact version to roll back to (with -Rollback). Defaults to the
    last-known-good version, then to the newest other installed version.

.PARAMETER List
    Print the installed versions, the active one and the available state backups.

.PARAMETER SkipBackup
    Do not snapshot %USERPROFILE%\.dsh. Only for a throwaway host.

.PARAMETER BackupRoot
    Where the state snapshots go. Default <InstallRoot>\backups.

.PARAMETER SkipBootCheck
    Skip the HTTP smoke test after switching.

.PARAMETER NoStart
    Do not start the Web UI after switching.

.PARAMETER Force
    Allow an unusual transition: reinstalling the current version, or going
    BACKWARDS in version with the full upgrade path (state migration warning).

.EXAMPLE
    .\Upgrade-DshWebOffline.ps1 -DryRun
    .\Upgrade-DshWebOffline.ps1
    .\Upgrade-DshWebOffline.ps1 -Rollback
#>
[CmdletBinding()]
param(
    [string]$BundleDir = '',
    [string]$InstallRoot = 'C:\DshWeb',
    [string]$WebPort = '',            # read from the installation by default
    [switch]$DryRun,
    [switch]$Rollback,
    [string]$RollbackTo = '',
    [switch]$List,
    [switch]$SkipBackup,
    [string]$BackupRoot = '',
    [switch]$SkipBootCheck,
    [switch]$NoStart,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 compatibility: Join-Path has no -AdditionalChildPath
# before PowerShell 6.0, so it must NEVER take three or more positional
# arguments. Nest the calls. Nothing here uses ??, ?:, ::new(), -AsHashtable,
# $IsWindows, Get-Error or any other PowerShell 6/7-only surface.

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    !!  $Text" -ForegroundColor Yellow }

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$Show
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = @(& $Command @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = @($raw | ForEach-Object { "$_" })
    if ($Show) { foreach ($t in $text) { Write-Host "    $t" } }
    return [pscustomobject]@{ ExitCode = $code; Lines = $text }
}

# Measure-Object returns $null (not 0) for an empty pipeline, and under
# Set-StrictMode the follow-up .Sum is a TERMINATING error. This keeps an empty
# folder a zero-byte folder instead of a crash - npmcache mode has no app tree,
# and a failed copy has no files, so both happen in practice.
function Get-TotalBytes($Items) {
    $list = @($Items)
    if ($list.Count -eq 0) { return 0 }
    $sum = ($list | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return $sum
}

function Invoke-Robocopy([string]$Source, [string]$Destination) {
    $argString = "`"$Source`" `"$Destination`" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP"
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -Wait -PassThru -NoNewWindow
    return $proc.ExitCode
}

function Get-AppModulesDir([string]$Prefix) {
    $win = Join-Path $Prefix 'node_modules'
    if (Test-Path $win) { return $win }
    $unix = Join-Path (Join-Path $Prefix 'lib') 'node_modules'
    if (Test-Path $unix) { return $unix }
    return $win
}

# npm 11 nests a global install's dependency tree under the package, so the known
# layouts are probed first and a bounded directory-name search is the fallback.
function Test-PackageUnder([string]$Root, [string]$PackageName) {
    $parts = $PackageName.Split('/')
    $leaf = $parts[$parts.Count - 1]
    $scope = $null
    if ($parts.Count -gt 1) { $scope = $parts[0] }
    $winModules  = Join-Path $Root 'node_modules'
    $unixModules = Join-Path (Join-Path $Root 'lib') 'node_modules'
    $winNested   = Join-Path (Join-Path (Join-Path $winModules '@deepseek-ai') 'dsh') 'node_modules'
    $unixNested  = Join-Path (Join-Path (Join-Path $unixModules '@deepseek-ai') 'dsh') 'node_modules'
    foreach ($base in @($winModules, $winNested, $unixModules, $unixNested)) {
        if (-not (Test-Path $base)) { continue }
        $dir = $base
        if ($scope) { $dir = Join-Path $dir $scope }
        $dir = Join-Path $dir $leaf
        if (Test-Path (Join-Path $dir 'package.json')) { return $true }
    }
    foreach ($hit in @(Get-ChildItem -Path $Root -Recurse -Directory -Filter $leaf -ErrorAction SilentlyContinue)) {
        if ($scope -and $hit.Parent.Name -ne $scope) { continue }
        if (Test-Path (Join-Path $hit.FullName 'package.json')) { return $true }
    }
    return $false
}

function Test-PortFree([int]$Port) {
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

# 401 from the browser-trust fence means the server is up; PS 5.1 throws on any
# non-2xx, so the status has to be read off the exception.
function Test-HttpResponding([string]$HostName, [int]$Port, [int]$TimeoutSec = 5) {
    try {
        $null = Invoke-WebRequest -Uri "http://$HostName`:$Port/" -UseBasicParsing -TimeoutSec $TimeoutSec
        return $true
    } catch {
        $response = $null
        try { $response = $_.Exception.Response } catch { $response = $null }
        if ($response) {
            $code = 0
            try { $code = [int]$response.StatusCode } catch { $code = 0 }
            if ($code -eq 401 -or $code -eq 403 -or $code -eq 303 -or $code -eq 302) { return $true }
        }
        return $false
    }
}

# The activation URL (?token=...) is minted per boot and only exists in the
# running server's output, so it is read back from the console log.
function Get-ActivationUrl([string]$LogPath, [string]$HostName, [int]$Port) {
    if (-not (Test-Path $LogPath)) { return '' }
    $text = Get-Content -Path $LogPath -Raw
    $pattern = 'https?://' + [regex]::Escape($HostName) + ':' + $Port + '/\?token=[A-Za-z0-9_\-]+'
    $m = [regex]::Match($text, $pattern)
    if ($m.Success) { return $m.Value }
    return ''
}

# ---------------------------------------------------------------- locate install
Write-Step 'Inspecting the existing installation'

if ($env:OS -ne 'Windows_NT') { throw 'This script runs on the Windows target host only.' }
$procArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ("$procArch" -ne 'AMD64') { throw "This installation is Windows x64 only (detected: $procArch)." }

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$versionsDir = Join-Path $InstallRoot 'versions'
$binDir      = Join-Path $InstallRoot 'bin'
$logsDir     = Join-Path $InstallRoot 'web-logs'
$currentFile = Join-Path $InstallRoot 'current.txt'
$lastGoodFile = Join-Path $InstallRoot 'last-known-good.txt'
$consoleLog  = Join-Path $logsDir 'web-console.log'
if (-not $BackupRoot) { $BackupRoot = Join-Path $InstallRoot 'backups' }
$dshHome = [Environment]::GetEnvironmentVariable('DSH_HOME')
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }

if (-not (Test-Path $currentFile)) {
    throw "$InstallRoot does not look like a DeepSeek Harness install (no current.txt). Run Install-DshWebOffline.ps1 from a bundle first."
}
$currentVersion = (Get-Content $currentFile -Raw).Trim()

$installedVersions = @()
if (Test-Path $versionsDir) {
    $installedVersions = @(Get-ChildItem -Path $versionsDir -Directory -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name | Sort-Object)
}
if ($installedVersions.Count -eq 0) { throw "No version folders under $versionsDir - the installation is broken; reinstall." }
$lastGood = ''
if (Test-Path $lastGoodFile) { $lastGood = (Get-Content $lastGoodFile -Raw).Trim() }
Write-Ok "active: dsh $currentVersion"
Write-Ok "installed: $($installedVersions -join ', ')"

# The port is not stored in a config file of its own; bin\start-web.cmd carries it.
$startShim = Join-Path $binDir 'start-web.cmd'
$urlShim   = Join-Path $binDir 'web-url.cmd'
$resolvedPort = 0
if ($WebPort -ne '' -and "$WebPort" -match '^\d+$') {
    $resolvedPort = [int]$WebPort
} elseif (Test-Path $startShim) {
    $startText = Get-Content -Path $startShim -Raw
    if ($startText -match '--port\s+(\d+)') { $resolvedPort = [int]$Matches[1] }
}
if ($resolvedPort -eq 0) { $resolvedPort = 3080 }
Write-Ok "web port: $resolvedPort"

function Get-DshHomeSize {
    if (-not (Test-Path $dshHome)) { return 0 }
    return (Get-TotalBytes (Get-ChildItem -Path $dshHome -Recurse -File -Force -ErrorAction SilentlyContinue))
}

if ($List) {
    Write-Step 'Installed versions'
    foreach ($v in $installedVersions) {
        $marker = '     '
        if ($v -eq $currentVersion) { $marker = '  <- ' }
        Write-Host "$marker$v"
    }
    if ($lastGood) { Write-Ok "last-known-good: $lastGood" }
    Write-Step 'State backups'
    if (Test-Path $BackupRoot) {
        $backups = @(Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue)
        if ($backups.Count -eq 0) { Write-Note "no snapshots under $BackupRoot yet" }
        foreach ($b in $backups) { Write-Host "  $($b.Name)" }
    } else {
        Write-Note "no snapshot folder at $BackupRoot yet"
    }
    Write-Host "`nState folder: $dshHome ($([math]::Round((Get-DshHomeSize)/1MB,1)) MB)"
    exit 0
}

function Stop-WebUi([int]$Port) {
    Write-Step "Stopping the Web UI (port $Port)"
    $task = $null
    try { $task = Get-ScheduledTask -TaskName 'DshWeb' -ErrorAction SilentlyContinue } catch { $task = $null }
    if ($task) {
        try { Stop-ScheduledTask -TaskName 'DshWeb' -ErrorAction SilentlyContinue | Out-Null; Write-Ok 'scheduled task stopped' } catch { Write-Note "could not stop the task: $($_.Exception.Message)" }
    } else {
        Write-Note 'no DshWeb scheduled task found (started by hand?)'
    }
    # Whatever still listens on the port is the old server - the upgrade must not
    # proceed while it runs, or the new version inherits a locked install tree.
    for ($i = 0; $i -lt 10; $i++) {
        $connections = @()
        try {
            $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        } catch { $connections = @() }
        if ($connections.Count -eq 0) { break }
        foreach ($c in $connections) {
            if ($c.OwningProcess) {
                Write-Note "stopping pid $($c.OwningProcess) listening on $Port"
                Invoke-Native -Command 'taskkill.exe' -Arguments @('/PID', "$($c.OwningProcess)", '/T', '/F') | Out-Null
            }
        }
        Start-Sleep -Seconds 2
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortFree $Port) { Write-Ok "port $Port is free" ; return $true }
        Start-Sleep -Seconds 1
    }
    Write-Note "port $Port is still busy after 30s"
    return $false
}

function Start-WebUi([int]$Port, [string]$HostName) {
    Write-Step 'Starting the Web UI'
    $task = $null
    try { $task = Get-ScheduledTask -TaskName 'DshWeb' -ErrorAction SilentlyContinue } catch { $task = $null }
    if ($task) {
        Start-ScheduledTask -TaskName 'DshWeb' | Out-Null
    } elseif (Test-Path $startShim) {
        Write-Note 'no DshWeb task - starting bin\start-web.cmd detached'
        $runRedirected = "/c `"`"$startShim`" > `"$consoleLog`" 2>&1`""
        Start-Process -FilePath 'cmd.exe' -ArgumentList $runRedirected -WindowStyle Hidden | Out-Null
    } else {
        Write-Note "no start script at $startShim - start the server by hand"
        return ''
    }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-HttpResponding $HostName $Port) {
            Write-Ok "listening on http://$HostName`:$Port"
            return (Get-ActivationUrl $consoleLog $HostName $Port)
        }
    }
    Write-Note "the Web UI did not answer on http://$HostName`:$Port within 120s"
    return ''
}

function Assert-VersionTree([string]$VersionDir, [string]$ExpectedVersion, $NativePackages) {
    $pkgJson = Join-Path (Join-Path (Join-Path (Get-AppModulesDir $VersionDir) '@deepseek-ai') 'dsh') 'package.json'
    if (-not (Test-Path $pkgJson)) { throw "no @deepseek-ai/dsh package under $VersionDir" }
    $meta = Get-Content $pkgJson -Raw | ConvertFrom-Json
    if ($meta.version -ne $ExpectedVersion) { throw "version mismatch in $VersionDir`: expected $ExpectedVersion, found $($meta.version)" }
    $missing = New-Object System.Collections.Generic.List[string]
    if ($NativePackages) {
        foreach ($native in $NativePackages) {
            if (-not (Test-PackageUnder $VersionDir "$native")) { $missing.Add("$native") }
        }
    }
    if ($missing.Count -gt 0) { throw "win32-x64 native package(s) missing from $VersionDir`: $($missing -join ', ')" }
    $launcher = Get-ChildItem -Path $VersionDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq 'dsh' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
                Select-Object -First 1
    if (-not $launcher) { throw "no dsh launcher directly under $VersionDir" }
    return $launcher.FullName
}

# ---------------------------------------------------------------- rollback path
if ($Rollback) {
    Write-Step 'Rolling back'
    $target = $RollbackTo
    if (-not $target) {
        if ($lastGood -and $lastGood -ne $currentVersion -and $installedVersions -contains $lastGood) { $target = $lastGood }
        else {
            $candidates = @($installedVersions | Where-Object { $_ -ne $currentVersion })
            if ($candidates.Count -gt 0) { $target = $candidates[$candidates.Count - 1] }
        }
    }
    if (-not $target) { throw 'No other installed version to roll back to. Use -RollbackTo <version>.' }
    if ($installedVersions -notcontains $target) { throw "Version $target is not installed under $versionsDir" }
    if ($target -eq $currentVersion) { throw "Version $target is already the active one." }

    $targetDir = Join-Path $versionsDir $target
    $nativeFallback = @('@koromix/koffi-win32-x64', '@img/sharp-win32-x64', '@vscode/ripgrep-win32-x64', 'sherpa-onnx-win-x64', '@deepseek-ai/libreoffice-kit-win32-x64', 'node-addon-require-builtin-win32-x64-msvc')
    $targetLauncher = ''
    try {
        $targetLauncher = Assert-VersionTree $targetDir $target $nativeFallback
    } catch {
        # An older version may predate a native package that only newer builds
        # need, and it demonstrably ran on this host before - so warn and fall
        # back to requiring the launcher rather than refusing the rollback.
        Write-Note "target version check: $($_.Exception.Message)"
        $found = Get-ChildItem -Path $targetDir -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.BaseName -eq 'dsh' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
                 Select-Object -First 1
        if (-not $found) { throw "No dsh launcher under $targetDir - cannot roll back to $target." }
        $targetLauncher = $found.FullName
        Write-Note 'continuing: this version was working on this host before'
    }
    Write-Ok "target version verified: $target"

    if (-not $SkipBackup) {
        Write-Note 'A state backup is still recommended: the version you are leaving may have migrated %USERPROFILE%\.dsh.'
    }
    if (-not (Stop-WebUi $resolvedPort)) { throw "Could not stop the Web UI on port $resolvedPort - refusing to switch the launcher underneath a running server." }
    Set-Content -Path $currentFile -Value $target -Encoding ASCII
    Write-Ok "current.txt -> $target"
    $activation = ''
    if (-not $NoStart) { $activation = Start-WebUi $resolvedPort '127.0.0.1' }
    Write-Host ''
    Write-Host "Rolled back to dsh $target (was $currentVersion)." -ForegroundColor Green
    Write-Host "  CLI        : $targetLauncher"
    if ($activation) { Write-Host "  Activation : $activation" }
    Write-Host '  If sessions or settings broke after the upgrade, restore the pre-upgrade snapshot:'
    Write-Host "    $BackupRoot\dsh-home-<timestamp>  ->  merge back over $dshHome (server stopped)"
    exit 0
}

# ---------------------------------------------------------------- verify bundle
Write-Step 'Verifying the new bundle'

if (-not $BundleDir) {
    if ($PSScriptRoot) { $BundleDir = $PSScriptRoot } else { $BundleDir = (Get-Location).Path }
}
$BundleDir = [System.IO.Path]::GetFullPath($BundleDir)
$manifestPath = Join-Path $BundleDir 'bundle-manifest.json'
if (-not (Test-Path $manifestPath)) { throw "bundle-manifest.json not found in $BundleDir. Pass -BundleDir <folder of the new bundle>." }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$mode = Get-Prop $manifest 'mode'
if (-not $mode) { $mode = if (Test-Path (Join-Path $BundleDir 'app')) { 'app' } else { 'npmcache' } }
$newVersion = Get-Prop $manifest 'dshVersion'
if (-not $newVersion) { throw 'bundle-manifest.json has no dshVersion - this is not a dsh bundle.' }
$manifestSchema = Get-Prop $manifest 'schemaVersion'
if ($null -ne $manifestSchema -and [int]$manifestSchema -ne 1) { throw "Unsupported manifest schemaVersion $manifestSchema." }
$nodeFloor = Get-Prop $manifest 'nodeFloor'
if (-not $nodeFloor) { $nodeFloor = '22.19.0' }
$declaredNative = Get-Prop $manifest 'nativePackages'
if (-not $declaredNative) { $declaredNative = @('@koromix/koffi-win32-x64', '@img/sharp-win32-x64', '@vscode/ripgrep-win32-x64', 'sherpa-onnx-win-x64', '@deepseek-ai/libreoffice-kit-win32-x64', 'node-addon-require-builtin-win32-x64-msvc') }
$allowList = Get-Prop $manifest 'installScripts'
if (-not $allowList) { $allowList = @('koffi', 'node-pty', 'protobufjs', '@deepseek-ai/dsh-subprocess-local') }

$appStage   = Join-Path $BundleDir 'app'
$cacheStage = Join-Path $BundleDir 'npm-cache'
if ($mode -eq 'app') {
    if (-not (Test-Path $appStage)) { throw "Bundle is incomplete: missing $appStage" }
} elseif ($mode -eq 'npmcache') {
    if (-not (Test-Path $cacheStage)) { throw "Bundle is incomplete: missing $cacheStage" }
    $cacheCount = @(Get-ChildItem -Path $cacheStage -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    if ($cacheCount -lt 10) { throw "The npm cache looks empty ($cacheCount files)." }
} else {
    throw "Unsupported bundle mode: $mode"
}

$tarballName = Get-Prop $manifest 'packagedTarball'
$tarballPath = $null
if ($tarballName) {
    $candidate = Join-Path $BundleDir $tarballName
    if (Test-Path $candidate) {
        $h = (Get-FileHash -Path $candidate -Algorithm SHA256).Hash
        $expectedHash = Get-Prop $manifest 'tarballSha256'
        if ($expectedHash -and $h -ne $expectedHash) { throw "Release artifact hash mismatch for $tarballName. expected=$expectedHash actual=$h" }
        $tarballPath = $candidate
        Write-Ok "release artifact verified: $tarballName"
    } else {
        Write-Note "$tarballName is not in the bundle - the install will use the cache instead."
    }
}
Write-Ok "bundle: dsh $newVersion / mode $mode / built on $((Get-Prop $manifest 'builtOn'))"

# Node check: the new tree may need a newer Node than the old one did.
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) { throw "node is not on PATH. Run 'nvm use <version>' in this shell and retry." }
$nodeProbe = Invoke-Native -Command 'node' -Arguments @('-v')
$nodeRaw = "$($nodeProbe.Lines | Select-Object -Last 1)".Trim()
if ($nodeRaw -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "Unrecognized Node version: $nodeRaw" }
if ([version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" -lt [version]$nodeFloor) {
    throw "Node $nodeRaw is below the $nodeFloor floor this bundle needs. Fix with: nvm install 26.7.0 ; nvm use 26.7.0"
}
Write-Ok "node $nodeRaw (floor $nodeFloor)"

# Version transition decision.
if ($newVersion -eq $currentVersion -and -not $Force) {
    throw "dsh $newVersion is already the active version. Nothing to upgrade. Use -Force to reinstall the same version, or -Rollback to go back."
}
$currentParsed = $null
$newParsed = $null
try { $currentParsed = [version]($currentVersion -replace '-.*$', '') } catch { $currentParsed = $null }
try { $newParsed = [version]($newVersion -replace '-.*$', '') } catch { $newParsed = $null }
$isDowngrade = $false
if ($currentParsed -and $newParsed -and $newParsed -lt $currentParsed) { $isDowngrade = $true }
if ($isDowngrade -and -not $Force) {
    throw "This bundle carries dsh $newVersion, which is OLDER than the active $currentVersion. That is a downgrade: use -Rollback (keeps it simple) or -Force to run the full path."
}

$backupDir = Join-Path $BackupRoot ("dsh-home-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
$stateSize = Get-DshHomeSize

# ---------------------------------------------------------------- dry run
if ($DryRun) {
    Write-Step 'Dry run (nothing is changed)'
    Write-Host "  active version   : $currentVersion"
    Write-Host "  bundle version   : $newVersion ($mode)"
    Write-Host "  downgrade        : $isDowngrade"
    Write-Host "  install root     : $InstallRoot"
    Write-Host "  new version dir  : $(Join-Path $versionsDir $newVersion)"
    Write-Host "  web port         : $resolvedPort"
    Write-Host "  state folder     : $dshHome ($([math]::Round($stateSize/1MB,1)) MB)"
    Write-Host "  state backup     : $(if ($SkipBackup) { 'SKIPPED (-SkipBackup)' } else { $backupDir })"
    if ($mode -eq 'npmcache') { Write-Host '  install step     : npm install -g <artifact> --offline (from the bundle cache)' }
    else { Write-Host "  install step     : copy app\ -> versions\$newVersion (then verify file/byte counts)" }
    Write-Host '  rollback         : current.txt is switched only after the new version verifies,'
    Write-Host '                     and is restored automatically if the switch or restart fails'
    Write-Host ''
    Write-Note 'A dry run does not stop the running server and does not create the backup.'
    Write-Note 'Run again without -DryRun to apply.'
    exit 0
}

# ---------------------------------------------------------------- backup first
if ($SkipBackup) {
    Write-Step 'State backup skipped (-SkipBackup)'
    Write-Note "If dsh $newVersion migrates state, there is no way back to $currentVersion. Continuing anyway."
} else {
    Write-Step "Backing up the state folder ($([math]::Round($stateSize/1MB,1)) MB)"
    if (-not (Test-Path $dshHome)) {
        Write-Note "no state folder at $dshHome yet - nothing to back up"
    } else {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $rc = Invoke-Robocopy $dshHome $backupDir
        if ($rc -ge 8) { throw "robocopy failed to back up $dshHome (exit $rc). Refusing to upgrade without a backup." }
        $backupFiles = @(Get-ChildItem -Path $backupDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($backupFiles.Count -eq 0) { throw "The backup at $backupDir is empty. Refusing to upgrade without a backup." }
        $backupBytes = Get-TotalBytes $backupFiles
        Write-Ok "$($backupFiles.Count) files / $([math]::Round([double]$backupBytes/1MB,1)) MB at $backupDir"
        $note = @"
dsh offline upgrade state backup
================================
created    : $((Get-Date).ToUniversalTime().ToString('o'))
from       : $currentVersion
to         : $newVersion
bundle     : $BundleDir
mode       : $mode
host       : $env:COMPUTERNAME
node       : $nodeRaw

Restore (with the Web UI stopped):
  robocopy "$backupDir" "$dshHome" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1
A state migration does NOT roll back on its own, so this snapshot is the only
way to return to the pre-upgrade state.
"@
        Set-Content -Path (Join-Path $backupDir 'BACKUP-INFO.txt') -Value $note -Encoding UTF8
    }
}

# ---------------------------------------------------------------- install new version
# Everything from here can be undone by restoring current.txt, so the previous
# value is kept and every failure path restores it.
$previousVersion = $currentVersion
$newVersionDir = Join-Path $versionsDir $newVersion
$switched = $false

try {
    if (-not (Stop-WebUi $resolvedPort)) {
        throw "Could not stop the Web UI on port $resolvedPort - refusing to install underneath a running server."
    }

    Write-Step "Installing dsh $newVersion into $newVersionDir"
    if (Test-Path $newVersionDir) {
        $existingPkg = Join-Path (Join-Path (Join-Path (Get-AppModulesDir $newVersionDir) '@deepseek-ai') 'dsh') 'package.json'
        if (Test-Path $existingPkg) {
            Write-Ok "dsh $newVersion is already materialized - reusing it"
        } elseif ($mode -eq 'app') {
            Write-Note 'incomplete version folder - recopying the app tree'
            Remove-Item -Recurse -Force $newVersionDir
        }
    }
    if (-not (Test-Path $newVersionDir)) { New-Item -ItemType Directory -Force -Path $newVersionDir | Out-Null }

    $newPkg = Join-Path (Join-Path (Join-Path (Get-AppModulesDir $newVersionDir) '@deepseek-ai') 'dsh') 'package.json'
    if (-not (Test-Path $newPkg)) {
        if ($mode -eq 'app') {
            Write-Host '    Copying the application tree (this takes a minute) ...'
            $rc = Invoke-Robocopy $appStage $newVersionDir
            if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
            $expectedCount = Get-Prop $manifest 'appFileCount'
            $expectedBytes = Get-Prop $manifest 'appBytes'
            $copiedFiles = @(Get-ChildItem -Path $newVersionDir -Recurse -File -Force)
            $copiedBytes = Get-TotalBytes $copiedFiles
            if ($null -ne $expectedCount -and $copiedFiles.Count -ne [int]$expectedCount) {
                throw "App tree file count mismatch: expected $expectedCount, found $($copiedFiles.Count). The bundle or the media is damaged."
            }
            if ($null -ne $expectedBytes -and $copiedBytes -ne [long]$expectedBytes) {
                throw "App tree byte count mismatch: expected $expectedBytes, found $copiedBytes. The bundle or the media is damaged."
            }
            Write-Ok "app tree verified: $($copiedFiles.Count) files / $([math]::Round([double]$copiedBytes/1MB,1)) MB"
        } else {
            $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
            if (-not $npmCmd) { throw 'npm is not on PATH.' }
            $npmProbe = Invoke-Native -Command 'npm' -Arguments @('--version')
            $npmVerRaw = "$($npmProbe.Lines | Select-Object -Last 1)".Trim()
            if ($npmVerRaw -notmatch '^(\d+)\.(\d+)') { throw "Unrecognized npm version: $npmVerRaw" }
            $needAllowScripts = ([int]$Matches[1] -gt 11) -or ([int]$Matches[1] -eq 11 -and [int]$Matches[2] -ge 16)
            $manifestPkg = Get-Prop $manifest 'dshPackage'
            if (-not $manifestPkg) { $manifestPkg = '@deepseek-ai/dsh' }
            $pkgSpec = "$manifestPkg@$newVersion"
            if ($tarballPath) { $pkgSpec = $tarballPath }
            # --os/--cpu keep the optional-dependency choice pinned to the platform
            # the bundle was warmed for (see Install-DshWebOffline.ps1).
            $npmArgs = @('install', '-g', $pkgSpec, '--prefix', $newVersionDir, '--cache', $cacheStage,
                         '--offline', '--no-audit', '--no-fund', '--os', 'win32', '--cpu', 'x64')
            if ($needAllowScripts) { $npmArgs += "--allow-scripts=$($allowList -join ',')" }
            Write-Host "    npm $($npmArgs -join ' ')"
            $npmRun = Invoke-Native -Command 'npm' -Arguments $npmArgs -Show
            if ($npmRun.ExitCode -ne 0) { throw "Offline npm install of $newVersion failed (exit $($npmRun.ExitCode))." }
            $stillSkipped = @($npmRun.Lines | Where-Object { "$_" -match 'install-scripts\s+@?[^\s(]+\s*\(' })
            if ($stillSkipped.Count -gt 0) { throw "npm skipped install scripts for: $($stillSkipped -join '; '). The new tree would have incomplete native deps." }
            Write-Ok "dsh $newVersion installed from the bundle cache"
        }
    }

    $newLauncher = Assert-VersionTree $newVersionDir $newVersion $declaredNative
    Write-Ok "new version verified: $newVersion"

    Set-Content -Path $currentFile -Value $newVersion -Encoding ASCII
    $switched = $true
    Write-Ok "current.txt -> $newVersion (previous version $previousVersion kept for rollback)"

    $activation = ''
    if (-not $NoStart) { $activation = Start-WebUi $resolvedPort '127.0.0.1' }
    if (-not $NoStart -and $SkipBootCheck -eq $false -and $activation -eq '') {
        throw "the Web UI did not come back up on http://127.0.0.1:$resolvedPort after the switch"
    }

    $verRun = Invoke-Native -Command $newLauncher -Arguments @('--version')
    Write-Ok "dsh --version -> $(($verRun.Lines -join ' ').Trim())"

    Set-Content -Path $lastGoodFile -Value $newVersion -Encoding ASCII

    Write-Host ''
    Write-Host "Upgraded to dsh $newVersion." -ForegroundColor Green
    Write-Host "  previous version : $previousVersion  (still installed under versions\)"
    Write-Host "  rollback         : .\Upgrade-DshWebOffline.ps1 -Rollback"
    if (-not $SkipBackup) { Write-Host "  state backup     : $backupDir" }
    if ($activation) { Write-Host "  activation URL   : $activation" }
    Write-Host ''
    Write-Note "Plugin compatibility is NOT upgraded offline: plugins live in $dshHome\profiles\web"
    Write-Note 'and `dsh plugin ...` needs the npm registry. If a plugin refuses to load on the new'
    Write-Note "version, disable it in the profile patch or roll back with -Rollback."
    exit 0
} catch {
    $failure = $_.Exception.Message
    Write-Note "UPGRADE FAILED: $failure"
    if ($switched) {
        Write-Step "Restoring the previous version ($previousVersion)"
        try {
            Set-Content -Path $currentFile -Value $previousVersion -Encoding ASCII
            Write-Ok "current.txt restored to $previousVersion"
            if (-not $NoStart) {
                $restored = Start-WebUi $resolvedPort '127.0.0.1'
                if ($restored) { Write-Ok "the previous version is running again: $restored" }
                else { Write-Note "the previous version did not come back up - check $consoleLog" }
            }
        } catch {
            Write-Note "automatic rollback failed: $($_.Exception.Message)"
            Write-Note "Restore by hand:  Set-Content `"$currentFile`" `"$previousVersion`""
        }
    } else {
        Write-Note "current.txt was never switched, so the active version is still $previousVersion."
        Write-Note "Start it again with:  `"$startShim`""
    }
    if (-not $SkipBackup) {
        Write-Note "state snapshot (only needed if the new version already migrated state): $backupDir"
    }
    throw "Upgrade to dsh $newVersion failed: $failure"
}
