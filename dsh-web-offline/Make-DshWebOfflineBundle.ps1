<#
.SYNOPSIS
    Build an offline bundle for the DeepSeek Harness web surface (the `dsh web` command).

.DESCRIPTION
    RUN THIS ON A NETWORKED WINDOWS x64 MACHINE when -Mode app (the default).

    Why Windows x64: the installed tree carries architecture-bound native
    packages and binaries - @koromix/koffi-win32-x64, @img/sharp-win32-x64,
    @vscode/ripgrep-win32-x64, sherpa-onnx-win-x64, node-pty's bundled
    prebuilds/win32-x64 and the ~190 MB @deepseek-ai/libreoffice-kit-win32-x64.
    A tree resolved anywhere else holds the wrong ones and the air-gapped host
    cannot fix that without a registry.

    -Mode npmcache is the platform-independent path (this macOS checkout can run
    it): it downloads the win32-x64 tarballs into a portable npm cache with
    `npm --os=win32 --cpu=x64`, and the target host then runs
        npm install -g @deepseek-ai/dsh@<version> --offline
    itself. npm reads no registry in that mode, so it is safe on the air-gapped
    host.

    Node is NOT bundled by default: prepare Node yourself with nvm on the target
    host (see README.txt). -IncludeNode adds a portable Node win-x64 runtime.

    Bundle contents (the produced folder is self-contained - the installer
    scripts are copied into it, so a zero-argument install works from it):
      app\                     npm global prefix holding @deepseek-ai/dsh + deps   (mode app)
      npm-cache\               warmed npm cache                                    (both modes)
      node\                    portable Node win-x64 runtime                       (with -IncludeNode)
      dsh-<version>.tgz        the release artifact, for the offline upgrade path
      docs\                    offline documentation (authored + version-matched)
      bundle-manifest.json     versions, hashes, file counts
      README.txt               copy/paste instructions for the air-gapped operator
      UPGRADE.md, UPGRADE-BRIEF.md, install.cmd, upgrade.cmd, Install-*.ps1, Upgrade-*.ps1

    No Electron desktop app is included: this bundle delivers the browser
    surface only (http://127.0.0.1:3080). The desktop profile is reserved for
    the Electron application and `dsh --profile desktop` is refused by design.

.PARAMETER Mode
    app      = prebuilt win32-x64 tree under app\ (Windows x64 build host only)
    npmcache = warmed npm cache only; the target host runs the offline install

.PARAMETER DshVersion
    Exact npm version of @deepseek-ai/dsh, or 'latest'. Default: latest (of -Channel).

.PARAMETER Channel
    npm dist-tag used when -DshVersion is 'latest': latest | next | alpha.
    Note `alpha` currently leads `latest` (0.2.1-alpha.2 vs 0.2.0-rc.2).

.PARAMETER IncludeNode
    Also carry a portable Node win-x64 runtime. Off by default (nvm is assumed).

.PARAMETER OutDir
    Bundle output folder. Default: .\dsh-web-offline-bundle

.PARAMETER KeepStaging
    Keep the _cachewarm\ staging tree in npmcache mode (diagnostics only; it
    roughly doubles the bundle size and is deleted again after a copy to USB).

.PARAMETER Force
    Delete and rebuild an existing bundle folder instead of resuming into it.

.EXAMPLE
    # build host: Windows x64, full app tree + warm cache
    .\Make-DshWebOfflineBundle.ps1 -OutDir D:\bundle

.EXAMPLE
    # build host: any platform (e.g. this macOS checkout), cache-only bundle
    .\Make-DshWebOfflineBundle.ps1 -Mode npmcache -DshVersion 0.2.0-rc.2 -OutDir ./dsh-web-offline-bundle
#>
[CmdletBinding()]
param(
    [ValidateSet('app', 'npmcache')][string]$Mode = 'app',
    [string]$DshVersion = 'latest',
    [ValidateSet('latest', 'next', 'alpha')][string]$Channel = 'latest',
    [string]$OutDir = (Join-Path (Get-Location) 'dsh-web-offline-bundle'),
    [switch]$IncludeNode,
    [string]$NodeVersion = '',
    [switch]$SkipDocs,
    [switch]$KeepStaging,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 compatibility (the build host may be the same 5.1 shell
# the target uses): Join-Path has no -AdditionalChildPath before PowerShell 6.0,
# so it must NEVER take three or more positional arguments - nest the calls:
#   Join-Path (Join-Path $root 'sub') $leaf
# Nothing here uses ??, ?:, ::new(), -AsHashtable, $IsWindows, utf8NoBOM,
# Get-Error or any other PowerShell 6/7-only surface.

# Windows PowerShell 5.1 does not reliably negotiate TLS 1.2, which makes HTTPS
# downloads fail with "Could not create SSL/TLS secure channel".
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------- contract
# These constants are the shared contract with Install-*/Upgrade-*/Test-*. The
# preflight script asserts the files still agree, because a silent drift here is
# exactly what breaks an air-gapped install months later.
$DshPackage          = '@deepseek-ai/dsh'
$BundleSchemaVersion = 1
$DefaultWebPort      = 3080
$TargetPlatform      = 'win32-x64'
# Hard floor: the dependency tree declares engines.node >=22.19.0
# (@deepseek-ai/libreoffice-kit, @earendil-works/pi-ai). Below it Node cannot
# parse/run the tree.
$NodeFloor           = '22.19.0'
# Known-good window registered for this deployment (repo README section 2.4).
$NodeKnownGood       = '>=24.16 <25 or >=26.1'
# Packages whose install script must actually run (npm >=11.16 requires them to
# be named; npm 12 denies by default). node-pty resolves its bundled
# prebuilds/win32-x64 with no network and no compiler; koffi places the prebuilt
# binary from @koromix/koffi-win32-x64; the other two are small postinstall steps.
$InstallScriptPackages = @(
    'koffi',
    'node-pty',
    'protobufjs',
    '@deepseek-ai/dsh-subprocess-local'
)
# Architecture-bound packages expected in a win32-x64 tree. The install script
# verifies these after materializing the tree; a missing one means the bundle
# was resolved for the wrong platform.
$NativePackages = @(
    '@koromix/koffi-win32-x64',
    '@img/sharp-win32-x64',
    '@vscode/ripgrep-win32-x64',
    'sherpa-onnx-win-x64',
    '@deepseek-ai/libreoffice-kit-win32-x64',
    'node-addon-require-builtin-win32-x64-msvc'
)

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
# 2>&1 (Windows PowerShell 5.1). npm prints deprecation notices to stderr on
# virtually every run, so every native call goes through here.
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

# Windows PowerShell 5.1 ignores HTTP(S)_PROXY for Invoke-WebRequest unless
# -Proxy is passed; curl.exe reads them itself. Resolve once, pass explicitly.
$ProxyUrl = $env:HTTPS_PROXY; if (-not $ProxyUrl) { $ProxyUrl = $env:https_proxy }
if (-not $ProxyUrl) { $ProxyUrl = $env:HTTP_PROXY }
if (-not $ProxyUrl) { $ProxyUrl = $env:http_proxy }
if ($ProxyUrl) { Write-Host "    proxy: $ProxyUrl" }

# Resumable, retrying download. Invoke-WebRequest cannot resume, which is fatal
# on a slow or flaky link; curl.exe supports -C -.
function Invoke-Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [long]$ExpectedBytes = 0,
        [long]$MinimumBytes = 1,
        [int]$Attempts = 10
    )
    $ErrorActionPreference = 'Continue'
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) { $curl = Get-Command 'curl' -ErrorAction SilentlyContinue }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $have = 0
        if (Test-Path $OutFile) { $have = (Get-Item $OutFile).Length }
        $sizeOk = ($have -ge $MinimumBytes) -and ($ExpectedBytes -le 0 -or $have -eq $ExpectedBytes)
        if ($attempt -eq 1 -and $sizeOk) {
            Write-Ok "already complete: $(Split-Path $OutFile -Leaf)"
            return (Get-Item $OutFile)
        }
        Write-Host "        attempt $attempt/$Attempts, from $([math]::Round($have/1MB,1)) MB"
        try {
            if ($curl) {
                $cargs = @('-fL', '-sS', '--retry', '3', '--retry-delay', '3', '--connect-timeout', '30',
                           '--speed-time', '90', '--speed-limit', '512')
                if ($have -gt 0) { $cargs += @('-C', '-') }
                if ($ProxyUrl) { $cargs += @('-x', $ProxyUrl) }
                $cargs += @('-o', $OutFile, $Url)
                & $curl.Source @cargs 2>&1 | ForEach-Object { Write-Host "        $_" }
                $code = $LASTEXITCODE
                if ($code -eq 33) {
                    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                    throw 'server refused a range request; restarting from zero'
                }
                if ($code -ne 0) { throw "curl exit $code" }
            } else {
                $request = [System.Net.HttpWebRequest]::Create($Url)
                if ($ProxyUrl) { $request.Proxy = New-Object System.Net.WebProxy($ProxyUrl) }
                $request.UserAgent = 'dsh-web-offline-bundler'
                $request.Timeout = 60000
                $request.ReadWriteTimeout = 300000
                if ($have -gt 0) { $request.AddRange([long]$have) }
                $response = $request.GetResponse()
                if ($have -gt 0 -and $response.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) {
                    $have = 0
                    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                }
                $mode = if ($have -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                $fs = New-Object System.IO.FileStream($OutFile, $mode, [System.IO.FileAccess]::Write)
                $src = $response.GetResponseStream()
                $src.CopyTo($fs)
                $fs.Dispose(); $src.Dispose(); $response.Close()
            }
        } catch {
            Write-Note "download attempt $attempt/$Attempts failed: $($_.Exception.Message)"
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds ([Math]::Min(20, 2 * $attempt)) }
            continue
        }
        $have = 0
        if (Test-Path $OutFile) { $have = (Get-Item $OutFile).Length }
        if (($have -ge $MinimumBytes) -and ($ExpectedBytes -le 0 -or $have -eq $ExpectedBytes)) {
            Write-Ok "$(Split-Path $OutFile -Leaf) - $([math]::Round($have/1MB,1)) MB"
            return (Get-Item $OutFile)
        }
        Write-Note "got $have bytes, expected $(if ($ExpectedBytes -gt 0) { $ExpectedBytes } else { ">= $MinimumBytes" }) - resuming"
        Start-Sleep -Seconds 2
    }
    throw "Download failed after $Attempts attempts: $Url"
}

# robocopy exists only on Windows, and -Mode npmcache also runs on Unix, so the
# copy steps go through this dispatcher: robocopy when available, Copy-Item
# otherwise. It keeps robocopy's exit-code contract (>= 8 means failure) so the
# callers read the same way on both platforms.
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

function Invoke-CopyTree([string]$Source, [string]$Destination) {
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    $robocopy = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue
    if ($robocopy) {
        # Start-Process does not quote array elements, so build the argument string.
        $argString = "`"$Source`" `"$Destination`" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP"
        $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -Wait -PassThru -NoNewWindow
        return $proc.ExitCode
    }
    try {
        Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force -ErrorAction Stop
        return 0
    } catch {
        Write-Note "copy failed: $($_.Exception.Message)"
        return 16
    }
}

# npm's own retries are too small for a ~280 MB dependency download on a flaky or
# proxied link - an ECONNRESET halfway through aborts the whole bundle build
# (observed twice while validating this script). Every install/warm step therefore
# goes through this loop. npm's cache is content-addressed, so a retry resumes
# where the previous attempt stopped instead of restarting the download.
function Invoke-NpmWithRetry {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$Attempts = 5
    )
    $netArgs = @('--fetch-retries=8', '--fetch-retry-mintimeout=5000', '--fetch-retry-maxtimeout=120000',
                 '--fetch-timeout=900000', '--maxsockets=8')
    $run = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $args = @($Arguments) + $netArgs
        # From the second attempt on, take whatever the cache already holds.
        if ($attempt -gt 1) { $args += '--prefer-offline' }
        Write-Host "    npm $($args -join ' ')"
        $run = Invoke-Native -Command 'npm' -Arguments $args -Show
        if ($run.ExitCode -eq 0) { return $run }
        if ($attempt -lt $Attempts) {
            Write-Note "npm failed (exit $($run.ExitCode)); attempt $($attempt + 1)/$Attempts - the cache keeps what was already fetched"
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    return $run
}

# The bundle is read on Windows 10 in Notepad, where an LF-only file renders as a
# single line. Rewrite text payloads as CRLF. -Bom keeps UTF-8 with BOM, which
# Notepad always detects; never use it for .cmd (cmd.exe would choke on the BOM).
function ConvertTo-CrlfText([string]$Path, [switch]$Bom) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $enc = New-Object System.Text.UTF8Encoding([bool]$Bom)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

# Snapshot of machine state this script must not alter. -Mode npmcache also runs
# on Unix, where USERPROFILE/APPDATA do not exist and Join-Path would throw on a
# null Path, so every root is resolved defensively.
function Get-ResidueSnapshot {
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { $homeDir = $env:HOME }
    $appData = $env:APPDATA
    $tasks = 0
    try { $tasks = @(Get-ScheduledTask -TaskName 'DshWeb*' -ErrorAction SilentlyContinue).Count } catch { $tasks = -1 }
    $stateExists = $false
    if ($homeDir) { $stateExists = Test-Path (Join-Path $homeDir '.dsh') }
    $npmDirExists = $false
    if ($appData) { $npmDirExists = Test-Path (Join-Path $appData 'npm') }
    [pscustomobject]@{
        DshHome      = $stateExists
        NpmGlobalDir = $npmDirExists
        DshTasks     = $tasks
    }
}

# ---------------------------------------------------------------- preflight
Write-Step 'Preflight'

$isWindowsHost = ($env:OS -eq 'Windows_NT')
$hostArch = $null
# Do NOT use [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture:
# that property does not exist on Windows PowerShell 5.1, and StrictMode turns
# the miss into a terminating error.
$procArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ("$procArch") {
    'AMD64' { $hostArch = 'x64' }
    'ARM64' { $hostArch = 'arm64' }
    ''      { $hostArch = 'unknown' }
    default { $hostArch = "$procArch" }
}
$hostIsTarget = $isWindowsHost -and ($hostArch -eq 'x64')

if ($Mode -eq 'app' -and -not $hostIsTarget) {
    throw "Mode app must be built on Windows x64 (this host: Windows=$isWindowsHost, arch=$hostArch). The app tree has arch-specific native packages. Use -Mode npmcache to build a cache-only bundle on any platform."
}
if ($Mode -eq 'npmcache' -and -not $hostIsTarget) {
    Write-Note "Cross-warming for $TargetPlatform on a non-Windows-x64 host: npm will be called with --os=win32 --cpu=x64."
    Write-Note 'The target host installs from that cache itself, so this is the supported portable path.'
}
Write-Ok "Host: Windows=$isWindowsHost arch=$hostArch PowerShell $($PSVersionTable.PSVersion)"

foreach ($exe in @('node', 'npm')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        throw "'$exe' not found on PATH. Install Node $NodeFloor+ first (nvm-windows is fine)."
    }
}
$nodeProbe = Invoke-Native -Command 'node' -Arguments @('-v')
$hostNodeRaw = "$($nodeProbe.Lines | Select-Object -Last 1)".Trim()
if ($hostNodeRaw -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "Unrecognized Node version: $hostNodeRaw" }
$hostNode = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
if ($hostNode -lt [version]$NodeFloor) { throw "Local Node $hostNodeRaw is below the $NodeFloor floor this tree needs." }
Write-Ok "Local Node $hostNodeRaw (floor $NodeFloor)"

$npmProbe = Invoke-Native -Command 'npm' -Arguments @('--version')
$npmVerRaw = "$($npmProbe.Lines | Select-Object -Last 1)".Trim()
if ($npmVerRaw -notmatch '^(\d+)\.(\d+)') { throw "Unrecognized npm version: $npmVerRaw" }
$npmMajor = [int]$Matches[1]
$npmMinor = [int]$Matches[2]
# npm >=11.16 knows --allow-scripts but still runs dependency scripts (warning
# only); npm >=12 denies them by default. Passing --allow-scripts is required on
# 12 and harmless on 11.16+.
$needAllowScripts = ($npmMajor -gt 11) -or ($npmMajor -eq 11 -and $npmMinor -ge 16)
Write-Ok "Local npm $npmVerRaw (needs --allow-scripts: $needAllowScripts)"

$residueBefore = Get-ResidueSnapshot
Write-Ok "Baseline: .dsh=$($residueBefore.DshHome), `$env:APPDATA\npm=$($residueBefore.NpmGlobalDir), DshWeb tasks=$($residueBefore.DshTasks)"

# npm's global layout differs by platform: <prefix>\node_modules on Windows,
# <prefix>/lib/node_modules on Unix. Both are probed so this script behaves the
# same whether it runs on the build host (Windows) or on the portable
# npmcache path (anywhere).
function Get-ModulesDir([string]$Prefix) {
    $win = Join-Path $Prefix 'node_modules'
    if (Test-Path $win) { return $win }
    $unix = Join-Path (Join-Path $Prefix 'lib') 'node_modules'
    if (Test-Path $unix) { return $unix }
    return $win
}
$hostPlatformLabel = 'unknown'
$platProbe = Invoke-Native -Command 'node' -Arguments @('-p', 'process.platform')
if ($platProbe.ExitCode -eq 0) { $hostPlatformLabel = "$($platProbe.Lines | Select-Object -Last 1)".Trim() }

# ---------------------------------------------------------------- resolve versions
Write-Step 'Resolving versions'

if ($DshVersion -eq 'latest') {
    $viewProbe = Invoke-Native -Command 'npm' -Arguments @('view', "$DshPackage@$Channel", 'version')
    $resolvedDsh = "$($viewProbe.Lines | Select-Object -Last 1)".Trim()
} else {
    $resolvedDsh = $DshVersion
}
if (-not $resolvedDsh) { throw "Could not resolve $DshPackage version from npm." }
if ($resolvedDsh -notmatch '^\d+\.\d+\.\d+') { throw "Unexpected version string from npm: $resolvedDsh" }
Write-Ok "dsh $resolvedDsh (channel: $Channel)"

$nodePicked = $null
if ($IncludeNode) {
    if (-not $NodeVersion) {
        Write-Host '    Querying https://nodejs.org/dist/index.json ...'
        $idxArgs = @{ Uri = 'https://nodejs.org/dist/index.json'; UseBasicParsing = $true; TimeoutSec = 60 }
        if ($ProxyUrl) { $idxArgs['Proxy'] = $ProxyUrl }
        $index = Invoke-RestMethod @idxArgs
        $stable = @($index | Where-Object { $_.version -match '^v\d+\.\d+\.\d+$' })
        # Prefer the registered known-good window, then anything above the floor.
        $pick = $stable | Where-Object { $_.version -match '^v26\.' } |
                Sort-Object { [version]($_.version.TrimStart('v')) } -Descending |
                Select-Object -First 1
        if (-not $pick) {
            $pick = $stable | Where-Object { $_.version -match '^v24\.' -and [version]($_.version.TrimStart('v')) -ge [version]'24.16.0' } |
                    Sort-Object { [version]($_.version.TrimStart('v')) } -Descending |
                    Select-Object -First 1
        }
        if (-not $pick) {
            $pick = $stable | Where-Object { [version]($_.version.TrimStart('v')) -ge [version]$NodeFloor } |
                    Sort-Object { [version]($_.version.TrimStart('v')) } -Descending |
                    Select-Object -First 1
        }
        if (-not $pick) { throw "No Node release >= $NodeFloor found on nodejs.org." }
        $NodeVersion = $pick.version.TrimStart('v')
    }
    $nodePicked = $NodeVersion
    Write-Ok "Node $nodePicked (portable runtime included)"
} else {
    Write-Ok 'Node runtime not bundled (nvm is assumed on the target host)'
}

# ---------------------------------------------------------------- staging
$bundleRoot = [System.IO.Path]::GetFullPath($OutDir)
# This section wipes $bundleRoot, so refuse anything that is not clearly ours.
$driveRoot = [System.IO.Path]::GetPathRoot($bundleRoot)
if ($bundleRoot.TrimEnd('\', '/') -eq $driveRoot.TrimEnd('\', '/')) {
    throw "Refusing to use a drive root as -OutDir: $bundleRoot"
}
$stageApp   = Join-Path $bundleRoot 'app'
$stageCache = Join-Path $bundleRoot 'npm-cache'
$stageNode  = Join-Path $bundleRoot 'node'
$dlDir      = Join-Path $bundleRoot '_download'

if (Test-Path $bundleRoot) {
    $existing = @(Get-ChildItem -Path $bundleRoot -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $recognizable = (Test-Path (Join-Path $bundleRoot 'bundle-manifest.json')) -or
                        (Test-Path (Join-Path $stageApp 'node_modules\@deepseek-ai\dsh\package.json')) -or
                        (Test-Path (Join-Path $stageCache '_cacache')) -or
                        (Test-Path (Join-Path $bundleRoot 'dsh-web-offline-bundle.marker'))
        if (-not $recognizable) {
            throw "$bundleRoot already exists ($($existing.Count) entries) and is not a previous bundle. That folder would be DELETED. Pass -Force to confirm, or choose another -OutDir."
        }
        if ($Force) {
            Write-Note '-Force: removing the existing bundle and starting over'
            Remove-Item -Recurse -Force $bundleRoot
        } else {
            Write-Ok 'Partial bundle detected - resuming; finished parts are reused (-Force starts over)'
        }
    }
}

foreach ($p in @($bundleRoot, $stageCache, $dlDir)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
if ($Mode -eq 'app' -and -not (Test-Path $stageApp)) { New-Item -ItemType Directory -Force -Path $stageApp | Out-Null }
if ($IncludeNode -and -not (Test-Path $stageNode)) { New-Item -ItemType Directory -Force -Path $stageNode | Out-Null }
Set-Content -Path (Join-Path $bundleRoot 'dsh-web-offline-bundle.marker') -Value 'dsh-web-offline-bundle' -Encoding ASCII
Write-Ok "Staging under $bundleRoot"

# ---------------------------------------------------------------- install tree
# Built by nesting Join-Path twice: a literal 'node_modules\@deepseek-ai\dsh'
# would not resolve on Unix, where the global layout is <prefix>/lib/node_modules.
$pkgJsonPath = Join-Path (Join-Path (Join-Path (Get-ModulesDir $stageApp) '@deepseek-ai') 'dsh') 'package.json'
$appMarker   = Join-Path $bundleRoot '.app-complete'
$crossWarm   = (-not $hostIsTarget)

$installArgs = @('install', '-g', "$DshPackage@$resolvedDsh", '--cache', $stageCache,
                 '--no-audit', '--no-fund')
if ($Mode -eq 'app') { $installArgs += @('--prefix', $stageApp) }
else { $installArgs += @('--prefix', (Join-Path $bundleRoot '_cachewarm')) }
if ($crossWarm) { $installArgs += @('--os', 'win32', '--cpu', 'x64', '--force') }
if ($Mode -eq 'app') {
    if ($needAllowScripts) { $installArgs += "--allow-scripts=$($InstallScriptPackages -join ',')" }
} else {
    # npmcache mode is a DOWNLOAD-only step. Dependency install scripts must NOT
    # run here: they execute against the build host's platform, and a native
    # package such as koffi then cannot find its prebuilt binary, falls back to a
    # source build and fails the whole install (verified: cmake build of koffi
    # fails on macOS). The win32-x64 packages are still resolved and cached; the
    # target host runs the scripts itself, where the prebuilt binaries do match.
    $installArgs += '--ignore-scripts'
}

if ($Mode -eq 'app') {
    Write-Step "Installing $DshPackage@$resolvedDsh into the bundle prefix"
    $alreadyVersion = $null
    if (Test-Path $pkgJsonPath) { $alreadyVersion = (Get-Content $pkgJsonPath -Raw | ConvertFrom-Json).version }
    if (($alreadyVersion -eq $resolvedDsh) -and (Test-Path $appMarker)) {
        Write-Ok "dsh $resolvedDsh is already in the bundle - skipping npm install"
    } else {
        $npmRun = Invoke-NpmWithRetry -Arguments $installArgs
        $npmLines = $npmRun.Lines
        if ($npmRun.ExitCode -ne 0) { throw "npm install failed with exit code $($npmRun.ExitCode) after all retries" }

        # npm 11.16+/12 runs install scripts ONLY for packages named in
        # --allow-scripts and lists the ones it skipped. Re-run once with
        # everything npm itself reported, then check that nothing is left.
        $skipped = New-Object System.Collections.Generic.List[string]
        foreach ($line in $npmLines) {
            if ("$line" -match 'install-scripts\s+(@?[^\s(]+)\s*\(') {
                $pkg = $Matches[1]
                $at = $pkg.LastIndexOf('@')
                if ($at -gt 0) { $pkg = $pkg.Substring(0, $at) }
                if ($pkg -and -not $skipped.Contains($pkg)) { $skipped.Add($pkg) }
            }
        }
        if ($skipped.Count -gt 0) {
            Write-Note "npm skipped install scripts for: $($skipped -join ', ')"
            $allow = (@($InstallScriptPackages) + $skipped | Select-Object -Unique) -join ','
            $retryArgs = @('install', '-g', "$DshPackage@$resolvedDsh", '--cache', $stageCache,
                           '--no-audit', '--no-fund', '--prefix', $stageApp, "--allow-scripts=$allow")
            if ($crossWarm) { $retryArgs += @('--os', 'win32', '--cpu', 'x64', '--force') }
            $retryRun = Invoke-NpmWithRetry -Arguments $retryArgs
            if ($retryRun.ExitCode -ne 0) {
                Write-Note "re-run with the full --allow-scripts list failed (exit $($retryRun.ExitCode)). Native deps may be incomplete."
            } else {
                $stillSkipped = @($retryRun.Lines | Where-Object { "$_" -match 'install-scripts\s+@?[^\s(]+\s*\(' })
                if ($stillSkipped.Count -gt 0) {
                    throw 'npm still reports skipped install scripts - the app tree would ship with unbuilt native deps. Review the log above.'
                }
                Write-Ok "install scripts covered: $allow"
            }
        }
        # Only a tree whose install scripts actually ran is safe to reuse on resume.
        Set-Content -Path $appMarker -Value $resolvedDsh -Encoding ASCII
    }

    $launcher = Get-ChildItem -Path $stageApp -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq 'dsh' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
                Select-Object -First 1
    if (-not $launcher) {
        Write-Note "No dsh launcher directly under $stageApp. Actual layout:"
        Get-ChildItem -Path $stageApp -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host "        $_" }
        throw "Expected a dsh launcher under $stageApp - check the layout printed above."
    }
    Write-Ok "Launcher: $($launcher.FullName)"
} else {
    Write-Step "Warming the npm cache for $DshPackage@$resolvedDsh (no app tree in this mode)"
    $npmRun = Invoke-NpmWithRetry -Arguments $installArgs
    if ($npmRun.ExitCode -ne 0) { throw "npm install (cache warm) failed with exit code $($npmRun.ExitCode) after all retries" }
    $skipped = @($npmRun.Lines | Where-Object { "$_" -match 'install-scripts\s+@?[^\s(]+\s*\(' })
    if ($skipped.Count -gt 0) {
        Write-Note 'npm reported skipped install scripts while warming. The target host must list them explicitly; the install script does so from the manifest.'
    }
    Write-Ok 'cache warmed'
}

# npm 11 nests a global install's dependency tree under the package
# (<prefix>\node_modules\@deepseek-ai\dsh\node_modules\<pkg>) instead of hoisting
# it to <prefix>\node_modules\<pkg>, so a fixed probe path misses every native
# package and would reject a perfectly good bundle. Probe the known layouts and
# fall back to a bounded search by directory name.
function Test-PackageUnder([string]$Root, [string]$PackageName) {
    $parts = $PackageName.Split('/')
    $leaf = $parts[$parts.Count - 1]
    $scope = $null
    if ($parts.Count -gt 1) { $scope = $parts[0] }
    $winModules   = Join-Path $Root 'node_modules'
    $unixModules  = Join-Path (Join-Path $Root 'lib') 'node_modules'
    $winNested    = Join-Path (Join-Path (Join-Path $winModules '@deepseek-ai') 'dsh') 'node_modules'
    $unixNested   = Join-Path (Join-Path (Join-Path $unixModules '@deepseek-ai') 'dsh') 'node_modules'
    $bases = @($winModules, $winNested, $unixModules, $unixNested)
    foreach ($base in $bases) {
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

# ---------------------------------------------------------------- native package check
# An app tree resolved for the wrong platform is the failure this catches: the
# native packages would be darwin-arm64 (or whatever built it) and the target
# host cannot replace them without a registry.
Write-Step 'Checking architecture-bound packages'
$appModules  = Get-ModulesDir $stageApp
$warmModules = Get-ModulesDir (Join-Path $bundleRoot '_cachewarm')
$nativeFound   = New-Object System.Collections.Generic.List[string]
$nativeMissing = New-Object System.Collections.Generic.List[string]
foreach ($native in $NativePackages) {
    $found = $false
    foreach ($root in @($stageApp, (Join-Path $bundleRoot '_cachewarm'))) {
        if (Test-PackageUnder $root $native) { $found = $true; break }
    }
    if ($found) { $nativeFound.Add($native) } else { $nativeMissing.Add($native) }
}
if ($nativeFound.Count -gt 0) { Write-Ok "present: $($nativeFound -join ', ')" }
if ($nativeMissing.Count -gt 0) {
    if ($Mode -eq 'app') {
        throw "The app tree is missing win32-x64 native package(s): $($nativeMissing -join ', '). This bundle would not run on the target host - rebuild it on Windows x64."
    }
    throw "The warmed tree is missing win32-x64 native package(s): $($nativeMissing -join ', '). The cache would not satisfy the target's offline install - rebuild with -Mode npmcache on a host that can reach the registry."
}

# ---------------------------------------------------------------- upgrade artifact
Write-Step "Packaging the upgrade artifact"
# npm pack names a scoped tarball <scope>-<name>-<version>.tgz, i.e.
# deepseek-ai-dsh-<version>.tgz for @deepseek-ai/dsh.
$expectedTarball = "deepseek-ai-dsh-$resolvedDsh.tgz"
$tarballPath = Join-Path $bundleRoot $expectedTarball
if (Test-Path $tarballPath) {
    Write-Ok "already present: $expectedTarball (re-using)"
} else {
    # Drop tarballs of other versions so a resume run cannot pick the wrong one.
    Get-ChildItem -Path $bundleRoot -Filter '*.tgz' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $expectedTarball } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    $packArgs = @('pack', "$DshPackage@$resolvedDsh", '--cache', $stageCache, '--pack-destination', $bundleRoot)
    Write-Host "    npm $($packArgs -join ' ')"
    $packRun = Invoke-Native -Command 'npm' -Arguments $packArgs -Show
    if ($packRun.ExitCode -ne 0) { throw "npm pack failed with exit code $($packRun.ExitCode)" }
}
if (-not (Test-Path $tarballPath)) {
    $packed = Get-ChildItem -Path $bundleRoot -Filter '*.tgz' -File | Select-Object -First 1
    if (-not $packed) { throw "npm pack did not produce a .tgz in $bundleRoot" }
    $tarballPath = $packed.FullName
    Write-Note "npm wrote $($packed.Name) instead of $expectedTarball; using it."
}
$tarballName = Split-Path $tarballPath -Leaf
$tarballHash = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
Write-Ok "$tarballName $([math]::Round((Get-Item $tarballPath).Length/1KB,1)) KB"
# npm 12 rejects local .tgz installs whose archive name or parent path contains a comma.
if ("$bundleRoot$tarballName" -match ',') {
    Write-Note 'The bundle path or tarball name contains a comma - npm 12 rejects local .tgz installs in that case. Choose another -OutDir.'
}

# ---------------------------------------------------------------- docs
if ($SkipDocs) {
    Write-Step 'Documentation collection skipped (-SkipDocs)'
} else {
    Write-Step 'Collecting the offline documentation'
    $docsDst = Join-Path $bundleRoot 'docs'
    if (-not (Test-Path $docsDst)) { New-Item -ItemType Directory -Force -Path $docsDst | Out-Null }

    # Authored docs: the air-gapped host cannot read the repo or the website.
    $authoredSrc = Join-Path $PSScriptRoot 'docs'
    if (Test-Path $authoredSrc) {
        $rc = Invoke-CopyTree $authoredSrc $docsDst
        if ($rc -ge 8) { Write-Note "authored docs copy failed (robocopy exit $rc)" }
        else {
            $n = @(Get-ChildItem -Path $docsDst -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
            Write-Ok "$n authored page(s)"
        }
    } else {
        Write-Note 'no docs\ next to this script - shipping without the authored capability notes'
    }

    # Version-matched official docs: the @deepseek-ai packages ship README.md /
    # README.zh.md, and they are the only package reference the air-gapped host can
    # read. npm nests a global install's whole dependency tree under the package
    # (@deepseek-ai/dsh/node_modules/@deepseek-ai/<pkg>), so the scope folders are
    # found by walking the tree rather than by assuming one layout.
    $treeRoot = $null
    if ($Mode -eq 'app') { $treeRoot = $stageApp }
    else { $treeRoot = Join-Path $bundleRoot '_cachewarm' }
    if ($treeRoot -and (Test-Path $treeRoot)) {
        $pkgDst = Join-Path $docsDst 'packages'
        if (-not (Test-Path $pkgDst)) { New-Item -ItemType Directory -Force -Path $pkgDst | Out-Null }
        $copied = 0
        $seen = New-Object System.Collections.Generic.HashSet[string]
        $scopeDirs = @(Get-ChildItem -Path $treeRoot -Recurse -Directory -Filter '@deepseek-ai' -ErrorAction SilentlyContinue)
        foreach ($scope in $scopeDirs) {
            foreach ($dir in @(Get-ChildItem -Path $scope.FullName -Directory -ErrorAction SilentlyContinue)) {
                # The same package can appear at several depths; take the first.
                if (-not $seen.Add($dir.Name)) { continue }
                $mds = @(Get-ChildItem -Path $dir.FullName -File -Filter 'README*.md' -ErrorAction SilentlyContinue)
                if ($mds.Count -eq 0) { continue }
                $target = Join-Path $pkgDst $dir.Name
                if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
                foreach ($md in $mds) {
                    Copy-Item -Path $md.FullName -Destination $target -Force
                    $copied++
                }
            }
        }
        Write-Ok "$copied official package README page(s) under docs\packages ($($scopeDirs.Count) scope folder(s) scanned)"
    } else {
        Write-Note 'no installed tree available to collect package READMEs from'
    }
}

# Ship the operator/AI-facing upgrade docs and the installer scripts with the
# bundle, so the produced folder is self-contained and a zero-argument install
# from it works.
foreach ($name in @('UPGRADE.md', 'UPGRADE-BRIEF.md',
                    'Install-DshWebOffline.ps1', 'Upgrade-DshWebOffline.ps1',
                    'install.cmd', 'upgrade.cmd')) {
    $src = Join-Path $PSScriptRoot $name
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $bundleRoot $name) -Force
    } else {
        Write-Note "$name is not next to this script - the bundle will not carry it."
    }
}
Write-Ok 'bundle now carries its own installer and upgrade entry points'

# ---------------------------------------------------------------- Node (optional)
$nodeZipName = $null
$nodeHash = $null
if ($IncludeNode) {
    Write-Step "Downloading Node $nodePicked (win-x64)"
    $nodeZipName = "node-v$nodePicked-win-x64.zip"
    $nodeZipUrl  = "https://nodejs.org/dist/v$nodePicked/$nodeZipName"
    $nodeZipPath = Join-Path $dlDir $nodeZipName
    Write-Host "    $nodeZipUrl"
    Invoke-Download -Url $nodeZipUrl -OutFile $nodeZipPath -MinimumBytes 1048576 | Out-Null

    $shaArgs = @{ Uri = "https://nodejs.org/dist/v$nodePicked/SHASUMS256.txt"; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($ProxyUrl) { $shaArgs['Proxy'] = $ProxyUrl }
    $shasums = (Invoke-WebRequest @shaArgs).Content
    $expected = @(
        $shasums -split "`n" | ForEach-Object {
            $fields = $_ -split '\s+' | Where-Object { $_ -ne '' }
            if ($fields.Count -ge 2 -and $fields[1] -eq $nodeZipName) { $fields[0] }
        }
    ) | Select-Object -First 1
    if (-not $expected) { throw "Could not find $nodeZipName in SHASUMS256.txt" }
    $nodeHash = (Get-FileHash -Path $nodeZipPath -Algorithm SHA256).Hash
    if ($nodeHash -ne $expected.ToUpper()) {
        Remove-Item $nodeZipPath -Force -ErrorAction SilentlyContinue
        throw "Node zip SHA256 mismatch (bad file removed, re-run to retry). expected=$expected actual=$nodeHash"
    }
    Write-Ok "SHA256 verified: $nodeHash"

    if (Test-Path (Join-Path $stageNode 'node.exe')) {
        Write-Ok 'Node already extracted - skipping'
    } else {
        Expand-Archive -Path $nodeZipPath -DestinationPath $stageNode -Force
        $inner = Get-ChildItem -Path $stageNode -Directory | Select-Object -First 1
        if ($inner) {
            Get-ChildItem -Path $inner.FullName -Force | Move-Item -Destination $stageNode -Force
            Remove-Item -Recurse -Force $inner.FullName
        }
        if (-not (Test-Path (Join-Path $stageNode 'node.exe'))) { throw 'Node extraction failed: node.exe missing.' }
    }
}

# ---------------------------------------------------------------- manifest
Write-Step 'Writing manifest'

$appFiles = @()
if ($Mode -eq 'app') { $appFiles = @(Get-ChildItem -Path $stageApp -Recurse -File -Force -ErrorAction SilentlyContinue) }
$cacheFiles = @(Get-ChildItem -Path $stageCache -Recurse -File -Force -ErrorAction SilentlyContinue)
$pkgMeta = if (Test-Path $pkgJsonPath) { Get-Content $pkgJsonPath -Raw | ConvertFrom-Json } else { $null }
$installedVersion = if ($pkgMeta) { $pkgMeta.version } else { $resolvedDsh }
$docsFiles = @(Get-ChildItem -Path (Join-Path $bundleRoot 'docs') -Recurse -File -Force -ErrorAction SilentlyContinue)

# StrictMode + Measure-Object: an empty set returns a $null Sum, and a null in
# the manifest makes the installer's [long] cast blow up. Normalise here.
$appBytes = Get-TotalBytes $appFiles
$cacheBytes = Get-TotalBytes $cacheFiles
$builtOnLabel = if ($isWindowsHost) { "Windows $hostArch" } else { "$hostPlatformLabel ($hostArch)" }
$warmedForLabel = if ($Mode -eq 'npmcache' -and $crossWarm) { $TargetPlatform } else { "$hostPlatformLabel-$hostArch" }

$manifest = [ordered]@{
    schemaVersion        = $BundleSchemaVersion
    mode                 = $Mode
    builtAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
    builtOn              = $builtOnLabel
    targetPlatform       = $TargetPlatform
    cacheWarmedFor       = $warmedForLabel
    dshPackage           = $DshPackage
    dshVersion           = $installedVersion
    channel              = $Channel
    nodeFloor            = $NodeFloor
    nodeKnownGood        = $NodeKnownGood
    nodeBundled          = [bool]$IncludeNode
    nodeVersion          = $nodePicked
    nodeZip              = $nodeZipName
    nodeZipSha256        = $nodeHash
    packagedTarball      = $tarballName
    tarballSha256        = $tarballHash
    defaultWebPort       = $DefaultWebPort
    installScripts        = $InstallScriptPackages
    nativePackages       = $NativePackages
    appFileCount         = $appFiles.Count
    appBytes             = $appBytes
    cacheFileCount       = $cacheFiles.Count
    cacheBytes           = $cacheBytes
    docsFileCount        = $docsFiles.Count
    npmVersionUsed       = $npmVerRaw
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bundleRoot 'bundle-manifest.json') -Encoding UTF8
Write-Ok "dsh $installedVersion / mode $Mode / $($appFiles.Count) app file(s) / $([math]::Round([double]$appBytes/1MB,1)) MB"
Write-Ok "npm cache: $($cacheFiles.Count) files / $([math]::Round([double]$cacheBytes/1MB,1)) MB"

# ---------------------------------------------------------------- README.txt
$nodeLine = if ($nodePicked) { "$nodePicked (bundled in node\)" } else { "not bundled - prepare Node with nvm (needs >= $NodeFloor; registered known-good: $NodeKnownGood)" }
$modeLine = if ($Mode -eq 'app') { 'app (the tree is prebuilt under app\)' } else { 'npmcache (this host runs the offline install from npm-cache\)' }
$readme = @"
DeepSeek Harness (web surface) offline bundle
=============================================
package   : $DshPackage
version   : $installedVersion
mode      : $modeLine
node      : $nodeLine
built     : $($manifest.builtAtUtc)
built on  : $($manifest.builtOn)
docs      : docs\  (authored notes + version-matched package READMEs)
web URL   : http://127.0.0.1:$DefaultWebPort   (loopback only)

On the air-gapped Windows 10 x64 host:

  1. Prepare Node (nvm-windows), for example in a PowerShell window:
         nvm install 26.7.0
         nvm use 26.7.0
     The tree needs Node >= $NodeFloor. Registered known-good: $NodeKnownGood.

  2. Unblock the files that came off the USB stick, then install:
         Get-ChildItem -Recurse | Unblock-File
         powershell -ExecutionPolicy Bypass -File .\Install-DshWebOffline.ps1
     (or just double-click install.cmd)

  3. Open the ACTIVATION URL the installer prints, not the bare one. dsh fences
     its web surface: http://127.0.0.1:$DefaultWebPort/ answers 401 until a
     browser has visited  http://127.0.0.1:$DefaultWebPort/?token=...
     That token is minted on every start, so after a restart read it back with:
         C:\DshWeb\bin\web-url.cmd
     (or the last line of C:\DshWeb\web-logs\web-console.log)

  4. A model endpoint is NOT part of this bundle. Point dsh at your LAN
     OpenAI-compatible endpoint - see docs\LLM-ENDPOINT.md. The web Settings page
     works offline, or patch the provider into:
         %USERPROFILE%\.dsh\profiles\web\cordis.patch.yml

Do not rename app\ , npm-cache\ , node\ , docs\ or bundle-manifest.json.

What does NOT work on an air-gapped host (expected, not a fault):
  - the plugin market / `dsh plugin add` (needs the npm registry)
  - web search and page fetch tools
  - account sign-in and cloud telemetry
  - any provider whose endpoint is on the public internet

Upgrading later (full procedure in UPGRADE-BRIEF.md):

  1. Build a NEW bundle on a networked Windows x64 machine with
     Make-DshWebOfflineBundle.ps1. It carries dsh-<version>.tgz plus a warmed
     npm-cache\ - that is what makes an offline upgrade possible.
  2. On this host, double-click upgrade.cmd (or run
     powershell -ExecutionPolicy Bypass -File .\Upgrade-DshWebOffline.ps1).
     It backs up %USERPROFILE%\.dsh first, stops the web server, installs the new
     version side by side, switches the launcher and restarts.
  3. Rollback: the previous version stays installed, so pointing the launcher
     back is a one-liner (upgrade.cmd -Rollback). State is NOT rolled back:
     a state migration stays migrated, so restore the pre-upgrade backup of
     %USERPROFILE%\.dsh if a session/profile incompatibility shows up.

Never re-run Install-DshWebOffline.ps1 -Force to upgrade: that wipes the
installed version tree (rescue mode). Use upgrade.cmd.
"@
Set-Content -Path (Join-Path $bundleRoot 'README.txt') -Value $readme -Encoding UTF8

# ---------------------------------------------------------------- CRLF + encoding pass
# The bundle is read on Windows 10: Notepad renders an LF-only file as a single
# line, and a .cmd with a UTF-8 BOM makes cmd.exe fail on line 1. Normalise both
# kinds here so the bundle is correct no matter which host built it.
Write-Step 'Normalising text payloads for Windows'
$textFiles = @(Get-ChildItem -Path $bundleRoot -Recurse -File -Force -Include '*.md', '*.txt' -ErrorAction SilentlyContinue)
foreach ($f in $textFiles) { ConvertTo-CrlfText -Path $f.FullName -Bom }
Write-Ok "$($textFiles.Count) .md/.txt file(s) rewritten as UTF-8 (BOM) + CRLF"
$scriptFiles = @(Get-ChildItem -Path $bundleRoot -Recurse -File -Force -Include '*.cmd', '*.ps1' -ErrorAction SilentlyContinue)
foreach ($f in $scriptFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    ConvertTo-CrlfText -Path $f.FullName
    if ($hadBom) { Write-Note "$($f.Name) carried a UTF-8 BOM; rewritten without it (cmd.exe would misread it)" }
}
Write-Ok "$($scriptFiles.Count) .cmd/.ps1 file(s) rewritten as ASCII-safe UTF-8 (no BOM) + CRLF"

# ---------------------------------------------------------------- staging cleanup
# _cachewarm exists only so a cache-only build can prove what it resolved; the
# npm cache already holds those bytes. Leaving it would double the bundle size.
$warmStage = Join-Path $bundleRoot '_cachewarm'
if ((Test-Path $warmStage) -and -not $KeepStaging) {
    Remove-Item -Recurse -Force $warmStage -ErrorAction SilentlyContinue
    Write-Ok '_cachewarm staging removed (the npm cache keeps the same bytes)'
}

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host 'Bundle ready:' -ForegroundColor Green
Get-ChildItem -Path $bundleRoot -Force | Where-Object { $_.Name -ne '_download' -and $_.Name -ne '_cachewarm' } |
    ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_.Name, $(if ($_.PSIsContainer) { '' } else { "$([math]::Round($_.Length/1KB,1)) KB" })) }
Write-Host ''
Write-Host 'Copy this whole folder to the air-gapped host, then run install.cmd inside it.' -ForegroundColor Green
Write-Host 'The _download\ and _cachewarm\ staging folders can be deleted first (they are not needed on the target).'

# ---------------------------------------------------------------- residue check
Write-Step 'Residue check'
$residueAfter = Get-ResidueSnapshot
$findings = @()
if (-not $residueBefore.DshHome -and $residueAfter.DshHome) { $findings += "$env:USERPROFILE\.dsh was created" }
if (-not $residueBefore.NpmGlobalDir -and $residueAfter.NpmGlobalDir) { $findings += "$env:APPDATA\npm was created" }
if ($residueAfter.DshTasks -ge 0 -and $residueBefore.DshTasks -ge 0 -and $residueAfter.DshTasks -gt $residueBefore.DshTasks) {
    $findings += 'a DshWeb scheduled task was created'
}
if ($residueAfter.DshTasks -lt 0) { Write-Note 'scheduled-task check unavailable on this host (module missing)' }

if ($findings.Count -eq 0) {
    Write-Ok 'no state dir, no global npm prefix dir, no scheduled task'
    Write-Ok 'this script uses no registry-write cmdlet and no installer'
    Write-Ok "the only files created are under $bundleRoot"
} else {
    foreach ($f in $findings) { Write-Note $f }
}
Write-Note "to leave nothing behind: Remove-Item -Recurse -Force `"$bundleRoot`"  (do this AFTER copying to USB)"
Write-Note 'deleted files do not go to the Recycle Bin. Execution traces (Prefetch, USN, PSReadLine history) are not removable by design.'
