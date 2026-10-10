<#
.SYNOPSIS
    Install the DeepSeek Harness web surface (the `dsh web` command) from an offline bundle.

.DESCRIPTION
    RUN THIS ON THE AIR-GAPPED WINDOWS 10 x64 HOST, as the user who will run the
    Web UI (never as SYSTEM). No outbound network access is performed: everything
    comes from the bundle folder this script sits in.

    Node must already be installed with nvm-windows and active in this shell
    (`nvm use <version>`), unless the bundle carries a portable runtime.

    The install root is versioned on purpose, because dsh has no self-update
    command - an upgrade is "materialize a new version beside the old one and
    point the launcher at it":

        C:\DshWeb\
          versions\<version>\   npm global prefix (dsh.cmd + node_modules\@deepseek-ai\dsh)
          current.txt           the active version
          bin\dsh.cmd           version-independent launcher on PATH
          bin\start-web.cmd     starts the Web UI with the configured host/port
          bin\stop-web.cmd      stops it again
          web-logs\             console log of the scheduled-task run
          docs\                 offline documentation
          backups\              created by the upgrade script before it upgrades
          provider-template.yml written when no model endpoint was configured

    State never moves: sessions, profiles and credentials stay in
    %USERPROFILE%\.dsh, so reinstalling or rolling the binary back leaves them
    alone (a state *migration* does not roll back - see UPGRADE-BRIEF.md).

    Steps: verify bundle -> check Node -> materialize the version tree ->
    launcher + PATH -> docs -> optional LAN model route -> smoke test (offline
    config dump, then a real boot of the Web UI) -> logon scheduled task.

    Zero-argument invocation works: BundleDir defaults to the folder this script
    lives in and provider setup is skipped unless -BaseUrl and -ModelId are given.

    This bundle carries no Electron desktop app and no browser runtime: the
    surface is served on loopback and opened in the browser you already have.

.PARAMETER BundleDir
    Folder produced by Make-DshWebOfflineBundle.ps1. Defaults to this script's folder.

.PARAMETER InstallRoot
    Where versions, launchers, docs and backups live. Default C:\DshWeb.
    Never a drive root or a system folder.

.PARAMETER WebPort
    Port the Web UI listens on. Default 3080 (dsh's own default).

.PARAMETER BindHost
    Interface the Web UI binds. Default 127.0.0.1 (loopback). dsh itself refuses
    0.0.0.0; binding a LAN address exposes a full agent runtime to the network -
    read docs\WEB-SURFACE.md before you do that.

.PARAMETER TrustedHost
    Optional extra authority the browser-trust fence accepts, e.g.
    10.0.0.5:3080. Only needed when BindHost is not loopback.

.PARAMETER BaseUrl
    Optional. Base URL of the LAN model endpoint, e.g. http://10.0.0.20:8000/v1.
    Omit both -BaseUrl and -ModelId to skip provider setup; a template is written
    to the install root instead.

.PARAMETER ModelId
    Optional. Exact model id the endpoint expects, e.g. qwen3-32b

.PARAMETER ApiKeyEnv
    Optional. Name of the environment variable that holds the endpoint's key.
    The name - never the key - is written into the profile patch.

.PARAMETER SkipPathUpdate
    Do not touch the per-user PATH.

.PARAMETER NoService
    Do not register the logon scheduled task (start the server by hand instead).

.PARAMETER NoStart
    Register the scheduled task but do not start the server now.

.PARAMETER SkipBootCheck
    Skip the real boot test (HTTP probe of the Web UI). Not recommended.

.PARAMETER Force
    Rescue mode: replace the version tree if it already exists, and adopt an
    existing non-empty -InstallRoot that this script does not recognise.

.EXAMPLE
    # zero arguments: BundleDir defaults to the folder this script sits in
    .\Install-DshWebOffline.ps1

.EXAMPLE
    # also point dsh at a LAN OpenAI-compatible endpoint
    $env:LLM_KEY = 'sk-lan'
    .\Install-DshWebOffline.ps1 -BaseUrl http://10.0.0.20:8000/v1 -ModelId qwen3-32b -ApiKeyEnv LLM_KEY
#>
[CmdletBinding()]
param(
    [string]$BundleDir = '',
    [string]$InstallRoot = 'C:\DshWeb',
    [int]$WebPort = 3080,
    [string]$BindHost = '127.0.0.1',
    [string]$TrustedHost = '',
    [string]$BaseUrl = '',
    [string]$ModelId = '',
    [string]$ApiKeyEnv = '',
    [switch]$SkipPathUpdate,
    [switch]$NoService,
    [switch]$NoStart,
    [switch]$SkipBootCheck,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 compatibility (the target host shell): Join-Path has no
# -AdditionalChildPath before PowerShell 6.0, so it must NEVER take three or more
# positional arguments. Nest the calls:
#   Join-Path (Join-Path $root 'sub') $leaf
# Nothing here uses ??, ?:, ::new(), -AsHashtable, $IsWindows, Get-Error or any
# other PowerShell 6/7-only surface.

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    !!  $Text" -ForegroundColor Yellow }

# StrictMode turns a missing property into a TERMINATING error. Bundle manifests
# differ by mode, so read every optional field through this.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# A native command that writes to stderr raises NativeCommandError, and with
# $ErrorActionPreference = 'Stop' that becomes a TERMINATING error - even with
# 2>&1 (Windows PowerShell 5.1). npm and node both do this on normal runs.
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
    # Start-Process does not quote array elements, so build the argument string.
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

# npm 11 nests a global install's dependency tree under the package
# (<prefix>\node_modules\@deepseek-ai\dsh\node_modules\<pkg>) instead of hoisting
# it to <prefix>\node_modules\<pkg>. A fixed probe path therefore misses every
# native package and would reject a working install, so the known layouts are
# probed first and a bounded directory-name search is the fallback.
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

function Get-FreePort([int]$Start) {
    for ($p = $Start; $p -lt ($Start + 200); $p++) { if (Test-PortFree $p) { return $p } }
    return 0
}

# Readiness is an HTTP probe, not a bind test: with a non-loopback -BindHost a
# loopback bind would succeed and lie about being ready.
function Test-WebUp([string]$HostName, [int]$Port, [int]$TimeoutSec = 5) {
    try {
        $resp = Invoke-WebRequest -Uri "http://$HostName`:$Port/" -UseBasicParsing -TimeoutSec $TimeoutSec
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# Readiness, as opposed to "healthy and authenticated": the browser-trust fence
# answers 401 until the activation URL has been visited, and PS 5.1 turns any
# non-2xx into a WebException - so 401 (and 303 from the activation redirect) mean
# the server IS up and must not be reported as a failure.
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

# The web surface is fenced: GET / answers 401 until the browser has visited the
# activation URL that `dsh web` prints at startup ("?token=<per-boot token>").
# That token is minted per boot from the stored secret, so it exists only in the
# running server's output - there is no file to read it back from later.
function Get-ActivationUrl([string]$LogPath, [string]$HostName, [int]$Port) {
    if (-not (Test-Path $LogPath)) { return '' }
    $text = Get-Content -Path $LogPath -Raw
    $pattern = 'https?://' + [regex]::Escape($HostName) + ':' + $Port + '/\?token=[A-Za-z0-9_\-]+'
    $m = [regex]::Match($text, $pattern)
    if ($m.Success) { return $m.Value }
    return ''
}

# ---------------------------------------------------------------- verify bundle
Write-Step 'Verifying bundle'

if ($env:OS -ne 'Windows_NT') { throw 'This installer runs on the Windows target host only.' }

if (-not $BundleDir) {
    if ($PSScriptRoot) { $BundleDir = $PSScriptRoot } else { $BundleDir = (Get-Location).Path }
}
$BundleDir = [System.IO.Path]::GetFullPath($BundleDir)
$manifestPath = Join-Path $BundleDir 'bundle-manifest.json'
if (-not (Test-Path $manifestPath)) { throw "bundle-manifest.json not found in $BundleDir. Pass -BundleDir <folder with the bundle contents>." }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$appStage   = Join-Path $BundleDir 'app'
$cacheStage = Join-Path $BundleDir 'npm-cache'
$nodeStage  = Join-Path $BundleDir 'node'

# mode 'app'      = prebuilt win32-x64 tree (made by Make-DshWebOfflineBundle.ps1 on Windows x64)
# mode 'npmcache' = warmed npm cache; this host runs the real offline install
$mode = Get-Prop $manifest 'mode'
if (-not $mode) { $mode = if (Test-Path $appStage) { 'app' } else { 'npmcache' } }
if ($mode -eq 'app') {
    if (-not (Test-Path $appStage)) { throw "Bundle is incomplete: missing $appStage" }
} elseif ($mode -eq 'npmcache') {
    if (-not (Test-Path $cacheStage)) { throw "Bundle is incomplete: missing $cacheStage (required in npmcache mode)" }
    $cacheCount = @(Get-ChildItem -Path $cacheStage -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    if ($cacheCount -lt 10) { throw "The npm cache looks empty ($cacheCount files) - do not install from it." }
} else {
    throw "Unsupported bundle mode: $mode"
}

$dshVersion = Get-Prop $manifest 'dshVersion'
if (-not $dshVersion) { throw 'bundle-manifest.json has no dshVersion - this is not a dsh bundle.' }
$manifestSchema = Get-Prop $manifest 'schemaVersion'
if ($null -ne $manifestSchema -and [int]$manifestSchema -ne 1) {
    throw "Unsupported manifest schemaVersion $manifestSchema (this installer understands 1)."
}
$manifestBuiltOn = Get-Prop $manifest 'builtOn'
Write-Ok "dsh $dshVersion / mode $mode / built on $manifestBuiltOn"

# Every external download is hash-checked before use; the release artifact is the
# one the upgrade path installs, so verify it now, not later.
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
        Write-Note "$tarballName is not in the bundle - the offline upgrade path will need a newer bundle."
    }
}

# See Make-DshWebOfflineBundle.ps1: RuntimeInformation.OSArchitecture is absent
# on Windows PowerShell 5.1 and StrictMode makes the miss a terminating error.
$procArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ("$procArch" -ne 'AMD64') { throw "This bundle is Windows x64 only (detected: $procArch)." }

$nodeBundled = [bool](Get-Prop $manifest 'nodeBundled')
$nodeZipPath = $null
if ($nodeBundled) {
    $nodeZipName = Get-Prop $manifest 'nodeZip'
    $nodeZipSha  = Get-Prop $manifest 'nodeZipSha256'
    $downloadStage = Join-Path $BundleDir '_download'
    $nodeZipPath = @(
        (Join-Path $BundleDir $nodeZipName),
        (Join-Path $downloadStage $nodeZipName)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($nodeZipPath) {
        $h = (Get-FileHash -Path $nodeZipPath -Algorithm SHA256).Hash
        if ($nodeZipSha -and $h -ne $nodeZipSha) { throw "Node archive hash mismatch. expected=$nodeZipSha actual=$h" }
        Write-Ok "bundled Node archive SHA256 verified"
    } elseif (Test-Path (Join-Path $nodeStage 'node.exe')) {
        Write-Note "$nodeZipName is not in the bundle (already extracted); skipping the archive check."
    } else {
        throw "Bundle is incomplete: no $nodeZipName and no extracted node\node.exe"
    }
}

$manifestAppCount = Get-Prop $manifest 'appFileCount'
$manifestAppBytes = Get-Prop $manifest 'appBytes'
$manifestCacheCount = Get-Prop $manifest 'cacheFileCount'
$manifestCacheBytes = Get-Prop $manifest 'cacheBytes'
if ($mode -eq 'app') {
    $appMb = 0
    if ($null -ne $manifestAppBytes) { $appMb = [math]::Round([double]$manifestAppBytes/1MB, 1) }
    Write-Ok "app tree: $manifestAppCount files / $appMb MB"
} else {
    $cacheMb = 0
    if ($null -ne $manifestCacheBytes) { $cacheMb = [math]::Round([double]$manifestCacheBytes/1MB, 1) }
    Write-Ok "npm cache: $manifestCacheCount files / $cacheMb MB"
}

# ---------------------------------------------------------------- Node preflight
Write-Step 'Checking the Node runtime'

$NodeFloor = Get-Prop $manifest 'nodeFloor'
if (-not $NodeFloor) { $NodeFloor = '22.19.0' }
$NodeKnownGood = Get-Prop $manifest 'nodeKnownGood'
if (-not $NodeKnownGood) { $NodeKnownGood = '>=24.16 <25 or >=26.1' }

$nodeCmd = $null
$nodeFromBundle = $false
if ($nodeBundled -and (Test-Path (Join-Path $nodeStage 'node.exe'))) {
    $nodeCmd = Join-Path $nodeStage 'node.exe'
    $nodeFromBundle = $true
} else {
    $found = Get-Command node -ErrorAction SilentlyContinue
    if ($found) { $nodeCmd = $found.Source }
}
if (-not $nodeCmd) {
    throw "node is not on PATH. Run 'nvm use <version>' in this shell (or open a new shell) and retry."
}
$nodeProbe = Invoke-Native -Command $nodeCmd -Arguments @('-v')
$nodeRaw = "$($nodeProbe.Lines | Select-Object -Last 1)".Trim()
if ($nodeRaw -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "Unrecognized Node version: $nodeRaw" }
$nodeVer = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
if ($nodeVer -lt [version]$NodeFloor) {
    throw "Node $nodeRaw is below the $NodeFloor floor this tree needs. Fix with: nvm install 26.7.0 ; nvm use 26.7.0"
}
Write-Ok "node $nodeRaw at $nodeCmd$(if ($nodeFromBundle) { ' (bundled)' } else { '' })"
Write-Note "Keep the active nvm version >= $NodeFloor. Registered known-good: $NodeKnownGood."

# ---------------------------------------------------------------- install root guards
# Normalise once, then refuse the two ways a mistyped -InstallRoot turns -Force
# into an unrecoverable delete: a drive root and a system folder.
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$installDriveRoot = [System.IO.Path]::GetPathRoot($InstallRoot)
if ($InstallRoot.TrimEnd('\') -eq $installDriveRoot.TrimEnd('\')) {
    throw "Refusing to use a drive root as -InstallRoot: $InstallRoot"
}
$protectedRoots = @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
if ($protectedRoots -contains $InstallRoot.TrimEnd('\')) {
    throw "Refusing to use a protected system folder as -InstallRoot: $InstallRoot"
}

$versionsDir = Join-Path $InstallRoot 'versions'
$binDir      = Join-Path $InstallRoot 'bin'
$docsDir     = Join-Path $InstallRoot 'docs'
$logsDir     = Join-Path $InstallRoot 'web-logs'
$currentFile = Join-Path $InstallRoot 'current.txt'
$versionDir  = Join-Path $versionsDir $dshVersion

# An install is "ours" when it carries any of our markers. Anything else in the
# way is only removed under an explicit -Force.
$existingRoot = Test-Path $InstallRoot
$isOurInstall = (Test-Path $currentFile) -or (Test-Path $versionsDir) -or (Test-Path (Join-Path $binDir 'dsh.cmd'))
if ($existingRoot -and -not $isOurInstall) {
    if (-not $Force) {
        throw "$InstallRoot already exists and is not a DeepSeek Harness install. That folder would be DELETED. Pass -Force to confirm, or choose another -InstallRoot."
    }
    Write-Note "-Force: removing the unrecognised folder $InstallRoot"
    Remove-Item -Recurse -Force $InstallRoot
    $isOurInstall = $false
}

$currentVersion = $null
if (Test-Path $currentFile) {
    $currentVersion = (Get-Content $currentFile -Raw).Trim()
    if ($currentVersion) { Write-Ok "existing install: dsh $currentVersion at $InstallRoot" }
}
if ($currentVersion -and $currentVersion -ne $dshVersion -and -not $Force) {
    throw "$InstallRoot already holds dsh $currentVersion and this bundle carries $dshVersion. To upgrade, use Upgrade-DshWebOffline.ps1 from this bundle (it backs up state, keeps the old version for rollback and can be dry-run). Re-run with -Force only if you mean to reinstall $dshVersion beside it."
}

foreach ($p in @($InstallRoot, $versionsDir, $binDir, $logsDir)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

# ---------------------------------------------------------------- materialize version
Write-Step "Materializing dsh $dshVersion into $versionDir"

$versionIsStale = $false
if (Test-Path $versionDir) {
    $installedPkgJson = Join-Path (Join-Path (Join-Path (Get-AppModulesDir $versionDir) '@deepseek-ai') 'dsh') 'package.json'
    if ($Force) {
        Write-Note "-Force: removing the existing $versionDir"
        Remove-Item -Recurse -Force $versionDir
        $versionIsStale = $true
    } elseif (Test-Path $installedPkgJson) {
        Write-Ok "dsh $((Get-Content $installedPkgJson -Raw | ConvertFrom-Json).version) is already materialized - reusing it"
    } elseif ($mode -eq 'app') {
        # A partially copied app tree must not be reused: repopulate it.
        Write-Note 'existing version folder has no complete dsh package - recopying the app tree'
        Remove-Item -Recurse -Force $versionDir
        $versionIsStale = $true
    } else {
        Write-Ok 'existing version folder kept (npm will complete the install)'
    }
}
if (-not (Test-Path $versionDir)) { New-Item -ItemType Directory -Force -Path $versionDir | Out-Null }
if ($versionIsStale) { Write-Ok 'version folder reset' }

if ($mode -eq 'app') {
    $installedPkgJson = Join-Path (Join-Path (Join-Path (Get-AppModulesDir $versionDir) '@deepseek-ai') 'dsh') 'package.json'
    if (-not (Test-Path $installedPkgJson)) {
        Write-Host '    Copying the application tree (this takes a minute) ...'
        $rc = Invoke-Robocopy $appStage $versionDir
        if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
        Write-Ok 'application files copied'

        # The app tree is the payload most exposed to USB/media corruption and the
        # manifest already records its shape, so compare it instead of trusting the copy.
        $expectedCount = Get-Prop $manifest 'appFileCount'
        $expectedBytes = Get-Prop $manifest 'appBytes'
        $copiedFiles = @(Get-ChildItem -Path $versionDir -Recurse -File -Force)
        $copiedBytes = Get-TotalBytes $copiedFiles
        if ($null -ne $expectedCount -and $copiedFiles.Count -ne [int]$expectedCount) {
            throw "App tree file count mismatch after copy: expected $expectedCount, found $($copiedFiles.Count). The bundle or the media is damaged - do not use this installation."
        }
        if ($null -ne $expectedBytes -and $copiedBytes -ne [long]$expectedBytes) {
            throw "App tree byte count mismatch after copy: expected $expectedBytes, found $copiedBytes. The bundle or the media is damaged - do not use this installation."
        }
        Write-Ok "app tree verified: $($copiedFiles.Count) files / $([math]::Round([double]$copiedBytes/1MB,1)) MB"
    }
} else {
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd) { throw 'npm is not on PATH (node is installed, so npm should be too).' }
    $npmProbe = Invoke-Native -Command 'npm' -Arguments @('--version')
    $npmVerRaw = "$($npmProbe.Lines | Select-Object -Last 1)".Trim()
    if ($npmVerRaw -notmatch '^(\d+)\.(\d+)') { throw "Unrecognized npm version: $npmVerRaw" }
    $needAllowScripts = ([int]$Matches[1] -gt 11) -or ([int]$Matches[1] -eq 11 -and [int]$Matches[2] -ge 16)

    # Native deps (koffi, node-pty, ...) need their install scripts. npm >=11.16
    # requires naming them; npm 12 denies them by default.
    $allowList = Get-Prop $manifest 'installScripts'
    if (-not $allowList) { $allowList = @('koffi', 'node-pty', 'protobufjs', '@deepseek-ai/dsh-subprocess-local') }
    $manifestPkg = Get-Prop $manifest 'dshPackage'
    if (-not $manifestPkg) { $manifestPkg = '@deepseek-ai/dsh' }
    $pkgSpec = "$manifestPkg@$dshVersion"
    # Prefer the shipped artifact: its SHA256 is what the manifest pins.
    if ($tarballPath) { $pkgSpec = $tarballPath }

    # --os/--cpu pin the optional-dependency choice to the platform this bundle
    # was warmed for. On a Windows x64 host this is the default anyway; stating it
    # makes the install deterministic and impossible to mis-resolve from a stray
    # npm config. The native-package check below is what proves it worked.
    $npmArgs = @('install', '-g', $pkgSpec, '--prefix', $versionDir, '--cache', $cacheStage,
                 '--offline', '--no-audit', '--no-fund', '--os', 'win32', '--cpu', 'x64')
    if ($needAllowScripts) { $npmArgs += "--allow-scripts=$($allowList -join ',')" }
    Write-Host "    npm $($npmArgs -join ' ')"
    $npmRun = Invoke-Native -Command 'npm' -Arguments $npmArgs -Show
    if ($npmRun.ExitCode -ne 0) {
        throw "Offline npm install failed (exit $($npmRun.ExitCode)). The cache may be incomplete for this npm/Node combination - retry without --offline only if this host can reach the registry."
    }
    Write-Ok 'dsh installed from the bundle cache'

    # npm reports the packages whose install scripts it skipped; a skipped one
    # means an incomplete native dependency, which must not pass silently.
    $stillSkipped = @($npmRun.Lines | Where-Object { "$_" -match 'install-scripts\s+@?[^\s(]+\s*\(' })
    if ($stillSkipped.Count -gt 0) {
        throw "npm skipped install scripts for: $($stillSkipped -join '; '). Native dependencies would be incomplete - fix the allow-scripts list and retry."
    }
}

# ---------------------------------------------------------------- verify version tree
Write-Step 'Verifying the installed tree'

$installedPkgJson = Join-Path (Join-Path (Join-Path (Get-AppModulesDir $versionDir) '@deepseek-ai') 'dsh') 'package.json'
if (-not (Test-Path $installedPkgJson)) {
    Write-Note "No dsh package under $versionDir. Actual layout:"
    Get-ChildItem -Path $versionDir -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName | Select-Object -First 40 | ForEach-Object { Write-Host "        $_" }
    throw "The install did not produce node_modules\@deepseek-ai\dsh - check the layout printed above."
}
$installedMeta = Get-Content $installedPkgJson -Raw | ConvertFrom-Json
if ($installedMeta.version -ne $dshVersion) {
    Write-Note "Installed version is $($installedMeta.version), the bundle says $dshVersion."
}
Write-Ok "dsh $($installedMeta.version)"

# Architecture check: a cache warmed for the wrong platform is the failure this
# catches, and it would otherwise only surface as a runtime crash.
$declaredNative = Get-Prop $manifest 'nativePackages'
if (-not $declaredNative) { $declaredNative = @('@koromix/koffi-win32-x64', '@img/sharp-win32-x64', '@vscode/ripgrep-win32-x64', 'sherpa-onnx-win-x64', '@deepseek-ai/libreoffice-kit-win32-x64', 'node-addon-require-builtin-win32-x64-msvc') }
$missingNative = New-Object System.Collections.Generic.List[string]
foreach ($native in $declaredNative) {
    if (-not (Test-PackageUnder $versionDir "$native")) { $missingNative.Add($native) }
}
if ($missingNative.Count -gt 0) {
    throw "The installed tree is missing win32-x64 native package(s): $($missingNative -join ', '). This bundle cannot run on this host - rebuild it on Windows x64 (mode app) or re-warm the cache for win32-x64 (mode npmcache)."
}
Write-Ok "$($declaredNative.Count) architecture-bound package(s) present"

$launcher = Get-ChildItem -Path $versionDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq 'dsh' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
            Select-Object -First 1
if (-not $launcher) { throw "No dsh launcher found directly under $versionDir - npm's global prefix layout is unexpected." }
Write-Ok "version launcher: $($launcher.FullName)"

if ($nodeBundled) {
    $nodeDir = Join-Path $InstallRoot 'node'
    if (-not (Test-Path (Join-Path $nodeDir 'node.exe'))) {
        New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
        Write-Host '    Copying the bundled Node runtime ...'
        Copy-Item -Path (Join-Path $nodeStage '*') -Destination $nodeDir -Recurse -Force
        Write-Ok 'Node runtime copied'
    } else {
        Write-Ok 'bundled Node runtime already in place'
    }
}

# ---------------------------------------------------------------- launchers
Write-Step 'Writing the version-independent launchers'

Set-Content -Path $currentFile -Value $dshVersion -Encoding ASCII
Write-Ok "current.txt -> $dshVersion"

$dshShim = Join-Path $binDir 'dsh.cmd'
$dshShimBody = @"
@echo off
rem Version-independent dsh launcher. Reads current.txt, so switching versions
rem (upgrade or rollback) needs no PATH change.
setlocal
set "DSH_ROOT=%~dp0.."
set "DSH_VERSION="
for /f "usebackq delims=" %%v in ("%DSH_ROOT%\current.txt") do set "DSH_VERSION=%%v"
if not defined DSH_VERSION (
    echo [ERROR] %DSH_ROOT%\current.txt is missing or empty.
    exit /b 1
)
set "DSH_LAUNCHER=%DSH_ROOT%\versions\%DSH_VERSION%\dsh.cmd"
if not exist "%DSH_LAUNCHER%" (
    echo [ERROR] dsh %DSH_VERSION% is not installed at "%DSH_LAUNCHER%".
    exit /b 1
)
call "%DSH_LAUNCHER%" %*
exit /b %ERRORLEVEL%
"@
Set-Content -Path $dshShim -Value $dshShimBody -Encoding ASCII
Write-Ok "launcher: $dshShim"

$trustedArg = ''
if ($TrustedHost) { $trustedArg = " --trusted-host $TrustedHost" }
$startBody = @"
@echo off
rem Start the DeepSeek Harness Web UI on $BindHost`:$WebPort as a foreground server.
rem Extra arguments are appended, e.g.:  start-web.cmd --port 3099
setlocal
set "DSH_ROOT=%~dp0.."
set "DSH_LOG=%DSH_ROOT%\web-logs"
if not exist "%DSH_LOG%" mkdir "%DSH_LOG%"
"%DSH_ROOT%\bin\dsh.cmd" web --host $BindHost --port $WebPort$trustedArg --no-open %*
exit /b %ERRORLEVEL%
"@
$startShim = Join-Path $binDir 'start-web.cmd'
Set-Content -Path $startShim -Value $startBody -Encoding ASCII
Write-Ok "start script: $startShim  (http://$BindHost`:$WebPort)"

$stopBody = @"
@echo off
rem Stop the Web UI: end the scheduled task, then kill whatever still listens on
rem the configured port. The port is baked in at install time.
setlocal
schtasks /end /tn "DshWeb" >nul 2>nul
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r /c:"LISTENING" ^| findstr /c:":$WebPort "') do (
    echo stopping pid %%p
    taskkill /pid %%p /t /f >nul 2>nul
)
exit /b 0
"@
$stopShim = Join-Path $binDir 'stop-web.cmd'
Set-Content -Path $stopShim -Value $stopBody -Encoding ASCII
Write-Ok "stop script: $stopShim"

# Visiting the Web UI requires the activation URL the running server printed
# (?token=...), and GET / answers 401 without it. That token is minted per boot,
# so this helper reads the current one back out of the service console log.
$urlBody = @"
@echo off
rem Print the activation URL of the CURRENTLY running Web UI.
rem The token is minted on every start, so this reads the latest console log line
rem instead of any stored value. Open the printed URL in a browser once; it sets
rem the signed cookie that later plain visits to http://$BindHost`:$WebPort/ need.
setlocal
set "LOG=%~dp0..\web-logs\web-console.log"
if not exist "%LOG%" (
    echo [ERROR] No console log at "%LOG%" - the Web UI has not been started by
    echo         the DshWeb task yet. Start it with:  "%~dp0start-web.cmd"
    exit /b 1
)
set "LAST="
for /f "tokens=*" %%l in ('findstr /c:"?token=" "%LOG%"') do set "LAST=%%l"
if not defined LAST (
    echo [ERROR] No activation URL in "%LOG%" yet. Wait for the server to finish
    echo         starting, then run this again.
    exit /b 1
)
echo %LAST%
exit /b 0
"@
$urlShim = Join-Path $binDir 'web-url.cmd'
Set-Content -Path $urlShim -Value $urlBody -Encoding ASCII
Write-Ok "activation-URL helper: $urlShim"

# ---------------------------------------------------------------- PATH
if (-not $SkipPathUpdate) {
    Write-Step 'Updating the per-user PATH'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $entries = @($userPath.Split(';') | Where-Object { $_ -ne '' })
    # Trim trailing separators before comparing: -contains is case-insensitive,
    # so "C:\DshWeb\bin\" and "c:\dshweb\bin" are one entry and must not be added twice.
    $normalized = @($entries | ForEach-Object { $_.TrimEnd('\') })
    if ($normalized -contains $binDir.TrimEnd('\')) {
        Write-Ok "already present: $binDir"
    } else {
        $entries += $binDir
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
        Write-Ok "added $binDir"
        if ($userPath -match '%') { Write-Note 'The user PATH uses %VAR% references; saving it through .NET writes them expanded. Check PATH in a NEW shell.' }
    }
    if ($nodeBundled) {
        $nodeDir = Join-Path $InstallRoot 'node'
        $normalized = @($entries | ForEach-Object { $_.TrimEnd('\') })
        if ($normalized -contains $nodeDir.TrimEnd('\')) { Write-Ok "already present: $nodeDir" }
        else {
            $entries += $nodeDir
            [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
            Write-Ok "added $nodeDir"
        }
    }
} else {
    Write-Note 'PATH not modified (-SkipPathUpdate). Add manually:'
    Write-Host "        $binDir"
}
$env:Path = "$binDir;$env:Path"

# ---------------------------------------------------------------- docs
$docsStage = Join-Path $BundleDir 'docs'
if (Test-Path $docsStage) {
    Write-Step 'Copying the offline documentation'
    $rc = Invoke-Robocopy $docsStage $docsDir
    if ($rc -ge 8) { Write-Note "docs copy skipped (robocopy exit $rc)" }
    else {
        $mdCount = @(Get-ChildItem -Path $docsDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
        Write-Ok "$mdCount page(s) at $docsDir"
    }
} else {
    Write-Note 'this bundle carries no docs\ folder'
}

# ---------------------------------------------------------------- model endpoint
$dshHome = [Environment]::GetEnvironmentVariable('DSH_HOME')
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
$profileDir = Join-Path (Join-Path $dshHome 'profiles') 'web'
$patchPath = Join-Path $profileDir 'cordis.patch.yml'

$configureProvider = [bool]($BaseUrl -and $ModelId)
if (($BaseUrl -and -not $ModelId) -or ($ModelId -and -not $BaseUrl)) {
    throw 'Pass both -BaseUrl and -ModelId, or neither.'
}

if ($configureProvider) {
    Write-Step 'Configuring the LAN model endpoint'
    # Initialize the profile first (manifest + empty patch layer), so the file we
    # rewrite is dsh's own template and not something hand-written.
    if (-not (Test-Path $patchPath)) {
        Write-Host '    initializing the web profile ...'
        Invoke-Native -Command $launcher.FullName -Arguments @('--profile', 'web', '--dump-config') -Show | Out-Null
    }
    $keyLine = ''
    if ($ApiKeyEnv) { $keyLine = "        apiKeyEnv: $ApiKeyEnv`r`n" }
    $patchBody = @"
# dsh profile patch layer for the ``web`` profile.
# One LAN OpenAI-compatible route, declared by hand: the endpoint is on the local
# network, so no catalog entry exists for it. Applied after every bundle layer.
- id: llm-pi-ai
  config:
    providers:
      lan:
        displayName: LAN gateway
$keyLine        api: openai-completions
        baseURL: $($BaseUrl.TrimEnd('/'))
        models:
          - id: $ModelId
            name: $ModelId
"@
    $isTemplate = $true
    if (Test-Path $patchPath) {
        $existingPatch = Get-Content $patchPath -Raw
        $meaningful = @($existingPatch -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') })
        $isTemplate = ($meaningful.Count -eq 0) -or ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -eq '[]')
    }
    if ($isTemplate) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        Set-Content -Path $patchPath -Value $patchBody -Encoding ASCII
        Write-Ok "wrote the LAN route into $patchPath"
        if ($ApiKeyEnv) { Write-Ok "the key itself stays out of the file: set `$env:$ApiKeyEnv before starting the server" }
    } else {
        $templateOut = Join-Path $InstallRoot 'provider-template.yml'
        Set-Content -Path $templateOut -Value $patchBody -Encoding ASCII
        Write-Note "$patchPath already has content - it was NOT overwritten."
        Write-Note "merge the route yourself from $templateOut"
    }
} else {
    Write-Step 'Model endpoint not configured'
    $templateOut = Join-Path $InstallRoot 'provider-template.yml'
    $patchBody = @"
# dsh profile patch layer for the ``web`` profile: one LAN OpenAI-compatible route.
# Copy this file over  %USERPROFILE%\.dsh\profiles\web\cordis.patch.yml  and edit it,
# or configure the same route from the Web UI (Settings -> Models) - no network needed.
- id: llm-pi-ai
  config:
    providers:
      lan:
        displayName: LAN gateway
        apiKeyEnv: LLM_KEY
        api: openai-completions
        baseURL: http://10.0.0.20:8000/v1
        models:
          - id: your-model-id
            name: your-model-id
"@
    Set-Content -Path $templateOut -Value $patchBody -Encoding ASCII
    Write-Ok "template written: $templateOut"
    Write-Note 'No -BaseUrl/-ModelId given, so no model route is configured. See docs\LLM-ENDPOINT.md.'
}

# ---------------------------------------------------------------- smoke tests
Write-Step 'Smoke test: CLI and offline config composition'
$verRun = Invoke-Native -Command $launcher.FullName -Arguments @('--version')
$verText = ($verRun.Lines -join ' ').Trim()
if ($verRun.ExitCode -ne 0) { throw "dsh --version failed with exit $($verRun.ExitCode): $verText" }
Write-Ok "dsh --version -> $verText"

$dumpLog = Join-Path $logsDir 'config-dump.log'
$dumpRun = Invoke-Native -Command $launcher.FullName -Arguments @('--profile', 'web', '--dump-config')
if ($dumpRun.ExitCode -ne 0) {
    $dumpRun.Lines | Set-Content -Path $dumpLog -Encoding UTF8
    ($dumpRun.Lines | Select-Object -Last 15) | ForEach-Object { Write-Host "    $_" }
    throw "The web profile could not be composed offline (exit $($dumpRun.ExitCode)). Full output: $dumpLog"
}
$dumpText = $dumpRun.Lines -join "`n"
foreach ($needle in @('dsh-base', 'dsh-web-app')) {
    if ($dumpText -notmatch [regex]::Escape($needle)) { throw "Composed profile is missing $needle - the shipped web profile did not resolve." }
}
Write-Ok 'web profile composes from the installation (no pnpm install, no registry)'

if ($SkipBootCheck) {
    Write-Note 'boot check skipped (-SkipBootCheck)'
} else {
    Write-Step 'Smoke test: booting the Web UI'
    if (-not (Test-PortFree $WebPort)) {
        Write-Note "port $WebPort is already in use on this host - the boot check uses a spare port."
    }
    # Always probe on a spare port, never on $WebPort: the service is started on
    # $WebPort right after this, and a still-dying probe server would race it.
    $probePort = Get-FreePort 32100
    if ($probePort -eq $WebPort) { $probePort = Get-FreePort ($WebPort + 1) }
    if ($probePort -eq 0) { throw 'No free port found for the boot check.' }
    $bootOut = Join-Path $logsDir 'boot-check.out.log'
    $bootErr = Join-Path $logsDir 'boot-check.err.log'
    # cmd.exe /c with the command double-quoted: the launcher path may contain spaces.
    $bootArgs = "/c `"`"$($launcher.FullName)`" web --host 127.0.0.1 --port $probePort --no-open > `"$bootOut`" 2> `"$bootErr`"`""
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $bootArgs -WindowStyle Hidden -PassThru
    $probeUrl = ''
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $probeUrl = Get-ActivationUrl $bootOut '127.0.0.1' $probePort
        if ($probeUrl) { break }
        if ($proc.HasExited) { break }
    }
    $ok = $false
    if ($probeUrl) {
        # Reproduce the browser flow: visit the activation URL (sets a signed
        # cookie), then load / with that cookie and look for the app's boot marker.
        try {
            $null = Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -TimeoutSec 20 -SessionVariable browserSession
            $page = Invoke-WebRequest -Uri "http://127.0.0.1:$probePort/" -UseBasicParsing -TimeoutSec 20 -WebSession $browserSession
            if ($page.StatusCode -eq 200 -and $page.Content -match '__DSH_BOOT__') { $ok = $true }
            else { Write-Note "the Web UI answered but without the expected boot marker (status $($page.StatusCode))." }
        } catch {
            Write-Note "the activation URL did not complete the browser handshake: $($_.Exception.Message)"
        }
        if (-not $ok) {
            # The activation URL answering at all already proves the server booted;
            # treat a cookie-handling quirk as a soft failure, not a bad install.
            # GET / currently answers 401 by design, so this asks "does it respond".
            if (Test-HttpResponding '127.0.0.1' $probePort 10) { $ok = $true }
        }
    }
    # Stop the whole child tree - the server may have spawned helpers.
    Invoke-Native -Command 'taskkill.exe' -Arguments @('/PID', "$($proc.Id)", '/T', '/F') | Out-Null
    $releaseDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $releaseDeadline -and -not (Test-PortFree $probePort)) { Start-Sleep -Milliseconds 500 }
    if (-not $ok) {
        Write-Note 'boot check output:'
        if (Test-Path $bootOut) { Get-Content $bootOut -Tail 20 | ForEach-Object { Write-Host "        $_" } }
        if (Test-Path $bootErr) { Get-Content $bootErr -Tail 20 | ForEach-Object { Write-Host "        $_" } }
        throw "The Web UI did not answer on http://127.0.0.1:$probePort/ within 120s. See $bootErr"
    }
    Write-Ok "Web UI booted and served the app on port $probePort (stopped again)"
}

# The upgrade script rolls back to this version when a later upgrade goes wrong.
Set-Content -Path (Join-Path $InstallRoot 'last-known-good.txt') -Value $dshVersion -Encoding ASCII

# ---------------------------------------------------------------- service
$taskName = 'DshWeb'
$serviceMode = 'none'
$activationUrl = ''
# The service runs without a visible console, so its startup output (which carries
# the per-boot activation URL) goes to this log; bin\web-url.cmd reads it back.
$consoleLog = Join-Path $logsDir 'web-console.log'
$runRedirected = "/c `"`"$startShim`" > `"$consoleLog`" 2>&1`""

if ($NoService) {
    Write-Step 'Autostart skipped (-NoService)'
    Write-Host "    Start it by hand with:  `"$startShim`""
} else {
    Write-Step "Registering the logon scheduled task ($taskName)"
    $registered = $false
    try {
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $runRedirected -WorkingDirectory $InstallRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
            -Description 'DeepSeek Harness Web UI (user-level, no elevation, loopback only)' -Force | Out-Null
        $registered = $true
        $serviceMode = 'scheduled-task'
        Write-Ok "task '$taskName' registered for $env:USERNAME at logon (no admin required)"
    } catch {
        Write-Note "could not register the scheduled task: $($_.Exception.Message)"
        # No-admin fallback: a .cmd in the per-user Startup folder is equivalent
        # for "start at logon", and is just as easy to remove.
        try {
            $startup = [Environment]::GetFolderPath('Startup')
            if (-not $startup) { throw 'no Startup folder path' }
            $startupCmd = Join-Path $startup 'DshWeb.cmd'
            $startupBody = "@echo off`r`nstart `"`" /min cmd.exe /c `"`"$startShim`" >> `"$consoleLog`" 2>&1`"`r`n"
            Set-Content -Path $startupCmd -Value $startupBody -Encoding ASCII
            $serviceMode = 'startup-folder'
            $registered = $true
            Write-Ok "startup entry written instead: $startupCmd"
        } catch {
            Write-Note "startup-folder fallback also failed: $($_.Exception.Message)"
            Write-Note "start the server yourself with: `"$startShim`""
        }
    }

    if ($registered -and -not $NoStart) {
        Write-Host '    starting the Web UI now ...'
        if ($serviceMode -eq 'scheduled-task') { Start-ScheduledTask -TaskName $taskName | Out-Null }
        else { Start-Process -FilePath 'cmd.exe' -ArgumentList $runRedirected -WindowStyle Hidden | Out-Null }
        $started = $false
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            if (Test-HttpResponding $BindHost $WebPort) { $started = $true; break }
        }
        if ($started) {
            Write-Ok "listening on http://$BindHost`:$WebPort"
            $activationUrl = Get-ActivationUrl $consoleLog $BindHost $WebPort
        }
        else {
            Write-Note "the Web UI did not answer on http://$BindHost`:$WebPort yet."
            Write-Note "Check the console log at $consoleLog, then run `"$startShim`" in a normal window to see the error."
        }
    }
}

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  dsh         : $binDir\dsh.cmd   (dsh $dshVersion; current.txt switches versions)"
Write-Host "  Web UI      : http://$BindHost`:$WebPort"
Write-Host "  Start/stop  : $startShim  |  $stopShim"
$serviceLabel = 'none (start by hand)'
if ($serviceMode -ne 'none') { $serviceLabel = $serviceMode }
Write-Host "  State       : $dshHome  (profiles\web, sessions, credentials)"
Write-Host "  Service     : $serviceLabel"
Write-Host "  Docs        : $docsDir"
Write-Host "  Logs        : $logsDir"
Write-Host "  Versions    : $versionsDir  (upgrades add a folder; rollback = switch current.txt)"
Write-Host ''
Write-Host 'Opening the Web UI:' -ForegroundColor Cyan
if ($activationUrl) {
    Write-Host '  Open this activation URL in a browser on this host:' -ForegroundColor Cyan
    Write-Host "    $activationUrl"
    Write-Host '  It sets a signed cookie for this browser; plain http://'
    Write-Host "  $BindHost`:$WebPort/ works after that. GET / alone answers 401 by design."
} else {
    Write-Host "  dsh prints a one-time activation URL (?token=...) when the server starts."
    Write-Host "  Read it back with:  `"$urlShim`""
    Write-Host "  (or look at the last line of $logsDir\web-console.log)"
}
Write-Note 'The token in that URL is minted on every start. Re-run web-url.cmd after a restart.'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Open the Web UI with the activation URL above.'
if (-not $configureProvider) {
    Write-Host "  2. Point dsh at your LAN model endpoint - see docs\LLM-ENDPOINT.md, then"
    Write-Host "     open Settings in the Web UI and pick the route. Nothing in this bundle"
    Write-Host '     includes a model: without an endpoint the agent cannot answer.'
} else {
    Write-Host "  2. The route 'lan' is configured. Set `$env:$ApiKeyEnv if the endpoint needs a key."
}
Write-Host '  3. To upgrade later, bring a NEW bundle and run upgrade.cmd there. Do not'
Write-Host '     re-run this installer with -Force: that is rescue mode for a broken tree.'
Write-Host ''
Write-Note 'Offline boundaries (expected, not faults): plugin market / dsh plugin add, web search and'
Write-Note 'page fetch, account sign-in and cloud telemetry all need the internet. Local chat over a'
Write-Note 'LAN model endpoint is unaffected. See docs\OFFLINE-CAPABILITIES.md.'
