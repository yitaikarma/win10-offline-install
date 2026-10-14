<#
.SYNOPSIS
    Build an offline bundle for the OpenClaw CLI + Gateway.

.DESCRIPTION
    RUN THIS ON A NETWORKED WINDOWS x64 MACHINE.

    Node is NOT bundled: prepare Node yourself with nvm on the target host.
    This bundle carries only what nvm cannot give you offline.

    Bundle contents:
      app\                     global npm prefix with openclaw + all deps
      npm-cache\               npm cache (fallback for `npm install --offline`)
      bundle-manifest.json     versions + hashes
      README.txt               copy/paste instructions

    No Windows desktop app and no WebView2 runtime: the target host uses the
    browser-based Control UI (or another client it pairs itself).

    IMPORTANT: build on Windows x64. The app tree contains arch-specific native
    optional deps (e.g. sqlite-vec-win32-x64); a bundle built elsewhere will be
    missing them.

.PARAMETER OpenClawVersion
    npm version to bundle, or 'latest'. Default: latest.

.PARAMETER IncludeNode
    Also carry a portable Node win-x64 runtime. Off by default (nvm is assumed).

.PARAMETER Mode
    app      = prebuilt win32-x64 tree under app\ (Windows x64 build host only)
    npmcache = warmed win32-x64 npm cache + release tarball only; the target runs the
               offline install itself. Buildable on any platform (this macOS checkout
               included) because the warming pins --os win32 --cpu x64 and leaves the
               dependency install scripts to the target (--ignore-scripts).

.PARAMETER KeepStaging
    Keep the _cachewarm\ staging tree in npmcache mode (diagnostics only; delete it
    before copying the bundle to USB).

.EXAMPLE
    .\Make-OpenClawOfflineBundle.ps1 -OutDir D:\bundle
    Build host: Windows x64, full app tree + warm cache.

.EXAMPLE
    .\Make-OpenClawOfflineBundle.ps1 -Mode npmcache -OpenClawVersion 2026.9.9 -OutDir ./openclaw-offline-bundle
    Build host: any platform (e.g. this macOS checkout), cache-only bundle.
#>
[CmdletBinding()]
param(
    [ValidateSet('app', 'npmcache')][string]$Mode = 'app',
    [string]$OpenClawVersion = 'latest',
    [switch]$IncludeNode,
    [string]$NodeVersion = '',
    [string]$OutDir = (Join-Path (Get-Location) 'openclaw-offline-bundle'),
    [switch]$KeepStaging,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- contract
# These constants are the shared contract with Install-*/Upgrade-*/Test-*. The
# preflight script asserts the files still agree, because silent drift here is
# exactly what breaks an air-gapped install months later.
$OpenClawPackage     = 'openclaw'
$BundleSchemaVersion = 4
$TargetPlatform      = 'win32-x64'
# Supported Node window (openclaw's own engines field): >=24.16 <25 OR >=26.1.
$NodeFloor           = '24.16.0'
$NodeCeiling         = '25.0.0'
$NodeAltFloor        = '26.1.0'
$NodeKnownGood       = '>=24.16 <25 or >=26.1'
$DefaultGatewayPort  = 18789

# Windows exposes USERPROFILE/APPDATA and sets OS=Windows_NT; a Unix build host does not.
# npmcache mode is buildable on any platform, so resolve these once instead of reading the
# Windows-only variables directly (a null -Path makes Join-Path a terminating error).
$hostOsLabel    = if ($env:OS) { $env:OS } else { 'Unix' }
$residueHome    = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($HOME) { $HOME } else { (Get-Location).Path }
$residueAppData = if ($env:APPDATA) { $env:APPDATA } else { $residueHome }

# Windows PowerShell 5.1 does not reliably negotiate TLS 1.2, which makes HTTPS
# downloads fail with "Could not create SSL/TLS secure channel".
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# StrictMode turns a missing property into a TERMINATING error. Read optional or
# version-dependent JSON fields through this helper instead of $obj.prop.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# A native command that writes to stderr raises NativeCommandError, and with
# $ErrorActionPreference = 'Stop' that becomes a TERMINATING error - even with
# 2>&1 (PowerShell 5.1). npm prints deprecation warnings to stderr on virtually
# every run, so every native call goes through here with the preference relaxed.
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

# Windows PowerShell 5.1 ignores HTTP_PROXY/HTTPS_PROXY for Invoke-WebRequest
# unless -Proxy is passed; curl.exe reads them on its own. Resolve once and pass
# it explicitly to every HTTP call.
$ProxyUrl = $env:HTTPS_PROXY; if (-not $ProxyUrl) { $ProxyUrl = $env:https_proxy }
if (-not $ProxyUrl) { $ProxyUrl = $env:HTTP_PROXY }
if (-not $ProxyUrl) { $ProxyUrl = $env:http_proxy }
if ($ProxyUrl) { Write-Host "    proxy: $ProxyUrl" }

# Resumable, retrying download. Invoke-WebRequest cannot resume, which is fatal
# on a slow or flaky link. curl.exe ships with Windows 10 1803+ and supports
# -C - (continue); the HttpWebRequest path below is the fallback.
function Invoke-Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [long]$ExpectedBytes = 0,
        [long]$MinimumBytes = 1,
        [int]$Attempts = 10
    )
    # Native stderr must not trip the Stop preference while curl runs.
    $ErrorActionPreference = 'Continue'
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
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
                # -C - resumes at the current file size. -s keeps the progress
                # meter off stderr so the Stop preference cannot trip on it.
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
                if ($code -ne 0) { throw "curl.exe exit $code" }
            } else {
                $request = [System.Net.HttpWebRequest]::Create($Url)
                if ($ProxyUrl) { $request.Proxy = New-Object System.Net.WebProxy($ProxyUrl) }
                $request.UserAgent = 'openclaw-offline-bundler'
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

# npm's own retries are too small for a ~300 MB dependency download on a flaky or proxied
# link: a reset halfway through aborts the whole bundle build. Every install/pack step goes
# through this loop; npm's cache is content-addressed, so a retry resumes where it stopped.
function Invoke-NpmRetry {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$Attempts = 3
    )
    $run = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $run = Invoke-Native -Command 'npm' -Arguments $Arguments -Show
        if ($run.ExitCode -eq 0) { return $run }
        if ($attempt -lt $Attempts) {
            $wait = $attempt * 5
            Write-Note "npm attempt $attempt/$Attempts failed (exit $($run.ExitCode)); retrying in ${wait}s"
            Start-Sleep -Seconds $wait
        }
    }
    return $run
}

# robocopy exists only on Windows, and npmcache mode also runs on Unix, so every tree
# copy goes through this dispatcher. It keeps robocopy's exit-code contract (>= 8 means
# failure) so the callers read the same way on both platforms.
function Invoke-CopyTree([string]$Source, [string]$Destination) {
    if (Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue) {
        $argString = "`"$Source`" `"$Destination`" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP"
        return (Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -Wait -PassThru -NoNewWindow).ExitCode
    }
    try {
        if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
        Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force -ErrorAction Stop
        return 0
    } catch {
        Write-Note "copy failed: $($_.Exception.Message)"
        return 16
    }
}

# Platform-suffixed package directories under a node_modules root. npm resolves only the
# target platform's optional deps, so anything that is not *-win32-x64 means the tree was
# resolved for the wrong platform - and an air-gapped host cannot fix that. Scoped
# packages (@scope/name) are inspected one level deep.
function Get-PlatformPackages([string]$NodeModulesRoot) {
    $native = New-Object System.Collections.Generic.List[string]
    $foreign = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $NodeModulesRoot)) {
        return [pscustomobject]@{ Native = @(); Foreign = @() }
    }
    # Platform naming varies: koffi-darwin-arm64 (suffix), @esbuild/darwin-arm64 (scoped,
    # no leading dash), sqlite-vec-windows-x64 (windows, not win32),
    # node-addon-require-builtin-win32-x64-msvc (msvc suffix).
    $platformPattern = '(^|[-/])(win32|windows|win|darwin|macos|mac|linux|freebsd|android|sunos)-(x64|arm64|arm|ia32|ppc64|s390x|riscv64)(-|$)'
    $win32X64Pattern = '(^|[-/])(win32|windows)-x64(-|$)'
    $candidates = New-Object System.Collections.Generic.List[string]
    # npm hoists some packages and nests others inside the package that needs them
    # (registry trap 17), so scan the root plus every nested node_modules directory.
    $nmRoots = New-Object System.Collections.Generic.List[string]
    $nmRoots.Add($NodeModulesRoot)
    foreach ($nested in @(Get-ChildItem -Path $NodeModulesRoot -Recurse -Directory -Filter 'node_modules' -Force -ErrorAction SilentlyContinue)) {
        $nmRoots.Add($nested.FullName)
    }
    foreach ($nmRoot in $nmRoots) {
        foreach ($entry in @(Get-ChildItem -Path $nmRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($entry.Name -eq 'node_modules') { continue }
            if ($entry.Name.StartsWith('@')) {
                foreach ($scoped in @(Get-ChildItem -Path $entry.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    $candidates.Add("$($entry.Name)/$($scoped.Name)")
                }
            } else {
                $candidates.Add($entry.Name)
            }
        }
    }
    foreach ($name in @($candidates | Sort-Object -Unique)) {
        if ("$name" -match $platformPattern) {
            if ("$name" -match $win32X64Pattern) { $native.Add("$name") } else { $foreign.Add("$name") }
        }
    }
    return [pscustomobject]@{ Native = @($native); Foreign = @($foreign) }
}

# npm's global layout differs by platform: <prefix>\node_modules on Windows, but
# <prefix>/lib/node_modules on Unix. Scanning the Windows path on a macOS build host finds
# nothing, which used to look like "the cross-warm pulled no platform packages".
function Get-NpmGlobalModulesRoot([string]$Prefix, [string]$PackageName) {
    $candidates = @(
        (Join-Path $Prefix 'node_modules'),
        (Join-Path (Join-Path $Prefix 'lib') 'node_modules')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate $PackageName)) { return $candidate }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $candidates[0]
}

# Measure-Object returns $null (not 0) for an empty pipeline, and under Set-StrictMode the
# follow-up .Sum is a terminating error. An empty app tree is normal in npmcache mode.
function Get-TotalBytes($Items) {
    $list = @($Items)
    if ($list.Count -eq 0) { return 0 }
    $sum = ($list | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return $sum
}

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    !!  $Text" -ForegroundColor Yellow }

# Snapshot of the machine state this script must not alter. Used to prove the run
# left no file/registry-level residue outside the output folder.
function Get-ResidueSnapshot {
    $tasks = 0
    try { $tasks = @(Get-ScheduledTask -TaskName '*openclaw*' -ErrorAction SilentlyContinue).Count } catch { $tasks = -1 }
    [pscustomobject]@{
        OpenClawState = (Test-Path (Join-Path $residueHome '.openclaw'))
        NpmGlobalDir  = (Test-Path (Join-Path $residueAppData 'npm'))
        OpenClawTasks = $tasks
    }
}

# ---------------------------------------------------------------- preflight
Write-Step 'Preflight'

if ($Mode -eq 'app' -and $env:OS -ne 'Windows_NT') {
    throw 'Mode app must run on Windows: the app tree holds arch-bound native deps. Use -Mode npmcache on this host.'
}
if ($Mode -eq 'app' -and -not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows host is required for -Mode app.' }
$arch = $null
# Do NOT use [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture:
# that property does not exist on Windows PowerShell 5.1 / older .NET Framework,
# and StrictMode turns the miss into a terminating error.
$procArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ("$procArch") {
    'AMD64' { $arch = 'X64' }
    'ARM64' { $arch = 'ARM64' }
    default { $arch = "$procArch" }
}
if (-not $arch) {
    # A Unix build host (npmcache mode) has no PROCESSOR_ARCHITECTURE. RuntimeInformation
    # exists on .NET Core, which is what pwsh is on there; a Windows PowerShell 5.1 host
    # always has the variables above, so this fallback is never reached there.
    $arch = "$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
}
$hostIsWindowsX64 = ($env:OS -eq 'Windows_NT') -and ($arch -eq 'X64')
if ($Mode -eq 'app' -and -not $hostIsWindowsX64) {
    throw "Build the app tree on Windows x64 (detected: $arch): it has arch-specific native deps. Use -Mode npmcache here instead."
}
# Cross-warming: npm resolves the win32-x64 optional deps into the shipped cache, and
# --ignore-scripts keeps the build host from running platform-bound install scripts
# (koffi falls back to a cmake build on macOS and fails - verified).
$crossWarm = ($Mode -eq 'npmcache') -and (-not $hostIsWindowsX64)
if ($crossWarm) {
    Write-Note "Cross-warming $TargetPlatform on a non-Windows-x64 host: npm gets --os win32 --cpu x64 --force --ignore-scripts."
    Write-Note 'The dependency install scripts are left to the target host, which is win32-x64.'
}
Write-Ok "Host: $hostOsLabel $arch, PowerShell $($PSVersionTable.PSVersion), mode $Mode"

foreach ($exe in @('node', 'npm')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        throw "'$exe' not found on PATH. Install Node 24.16+ / 26.1+ first (nvm-windows is fine)."
    }
}
$nodeProbe = Invoke-Native -Command 'node' -Arguments @('-v')
$hostNodeRaw = "$($nodeProbe.Lines | Select-Object -Last 1)".Trim()
if ($hostNodeRaw -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "Unrecognized Node version: $hostNodeRaw" }
$hostNode = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
$nodeOk = (($hostNode -ge [version]$NodeFloor -and $hostNode -lt [version]$NodeCeiling) -or ($hostNode -ge [version]$NodeAltFloor))
if (-not $nodeOk) { throw "Local Node $hostNodeRaw is unsupported (need >=24.16 <25, or >=26.1)." }
Write-Ok "Local Node $hostNodeRaw"

$npmProbe = Invoke-Native -Command 'npm' -Arguments @('--version')
$npmVerRaw = "$($npmProbe.Lines | Select-Object -Last 1)".Trim()
if ($npmVerRaw -notmatch '^(\d+)\.(\d+)') { throw "Unrecognized npm version: $npmVerRaw" }
$needAllowScripts = ([int]$Matches[1] -gt 11) -or ([int]$Matches[1] -eq 11 -and [int]$Matches[2] -ge 16)
Write-Ok "Local npm $npmVerRaw (needs --allow-scripts: $needAllowScripts)"

$residueBefore = Get-ResidueSnapshot
Write-Ok "Baseline: .openclaw=$($residueBefore.OpenClawState), npm-global-dir=$($residueBefore.NpmGlobalDir), openclaw tasks=$($residueBefore.OpenClawTasks)"

# ---------------------------------------------------------------- resolve versions
Write-Step 'Resolving versions'

if ($OpenClawVersion -eq 'latest') {
    $viewProbe = Invoke-NpmRetry -Arguments @('view', $OpenClawPackage, 'version')
    $resolvedOpenClaw = "$($viewProbe.Lines | Select-Object -Last 1)".Trim()
} else {
    $resolvedOpenClaw = $OpenClawVersion
}
if (-not $resolvedOpenClaw) { throw 'Could not resolve the OpenClaw version from npm.' }
Write-Ok "OpenClaw $resolvedOpenClaw"

$nodePicked = $null
if ($IncludeNode) {
    if (-not $NodeVersion) {
        Write-Host '    Querying https://nodejs.org/dist/index.json ...'
        $idxArgs = @{ Uri = 'https://nodejs.org/dist/index.json'; UseBasicParsing = $true; TimeoutSec = 60 }
        if ($ProxyUrl) { $idxArgs['Proxy'] = $ProxyUrl }
        $index = Invoke-RestMethod @idxArgs
        $stable = $index | Where-Object { $_.version -match '^v\d+\.\d+\.\d+$' }
        $pick = $stable | Where-Object { $_.version -match '^v26\.' } |
                Sort-Object { [version]($_.version.TrimStart('v')) } -Descending |
                Select-Object -First 1
        if (-not $pick) {
            $pick = $stable | Where-Object { $_.version -match '^v24\.' -and [version]($_.version.TrimStart('v')) -ge [version]$NodeFloor } |
                    Sort-Object { [version]($_.version.TrimStart('v')) } -Descending |
                    Select-Object -First 1
        }
        if (-not $pick) { throw 'No supported Node release found on nodejs.org.' }
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
if ($bundleRoot.TrimEnd('\') -eq $driveRoot.TrimEnd('\')) {
    throw "Refusing to use a drive root as -OutDir: $bundleRoot"
}
$stageApp   = Join-Path $bundleRoot 'app'
$stageCache = Join-Path $bundleRoot 'npm-cache'
$stageNode  = Join-Path $bundleRoot 'node'
$warmStage  = Join-Path $bundleRoot '_cachewarm'
$dlDir      = Join-Path $bundleRoot '_download'

if (Test-Path $bundleRoot) {
    $existing = @(Get-ChildItem -Path $bundleRoot -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        # Recognise our own leftovers so an interrupted run continues instead of
        # throwing away everything already downloaded.
        $recognizable = (Test-Path (Join-Path $bundleRoot 'bundle-manifest.json')) -or
                        (Test-Path (Join-Path $stageApp 'node_modules\openclaw\package.json')) -or
                        (Test-Path (Join-Path $stageCache '_cacache')) -or
                        (Test-Path (Join-Path $bundleRoot 'docs\docs_map.md'))
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

# npmcache mode must NOT contain app\: when the manifest is silent the installer infers
# the mode from app\ existing, and an empty app\ would look like a broken app bundle.
$stagingDirs = @($bundleRoot, $stageCache, $dlDir)
if ($Mode -eq 'app') { $stagingDirs += $stageApp }
if ($Mode -eq 'npmcache') { $stagingDirs += $warmStage }
foreach ($p in $stagingDirs) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
Write-Ok "Staging under $bundleRoot ($Mode mode)"

# ---------------------------------------------------------------- OpenClaw
# app      : install the win32-x64 tree into app\ - this is what the target copies
# npmcache : warm the shipped cache from a throwaway prefix; the target installs the
#            tarball itself, so no build-host executable is needed here
$stagedPrefix = $stageApp
if ($Mode -eq 'npmcache') { $stagedPrefix = $warmStage }
Write-Step "Preparing openclaw@$resolvedOpenClaw ($Mode mode)"

$pkgJsonPath = Join-Path (Join-Path (Get-NpmGlobalModulesRoot $stagedPrefix $OpenClawPackage) $OpenClawPackage) 'package.json'
$appMarker = Join-Path $bundleRoot '.app-complete'
$alreadyVersion = $null
if (Test-Path $pkgJsonPath) { $alreadyVersion = (Get-Content $pkgJsonPath -Raw | ConvertFrom-Json).version }

# Packages whose install scripts npm reported as unreviewed. Recorded in the manifest so
# the target can name them in --allow-scripts (npm 12 denies dependency scripts by default).
$installScriptPackages = New-Object System.Collections.Generic.List[string]
if (-not $installScriptPackages.Contains($OpenClawPackage)) { $installScriptPackages.Add($OpenClawPackage) }

if (($alreadyVersion -eq $resolvedOpenClaw) -and (Test-Path $appMarker)) {
    Write-Ok "openclaw $resolvedOpenClaw is already staged - skipping npm install"
} else {
    $npmArgs = @('install', '-g', "$OpenClawPackage@$resolvedOpenClaw", '--prefix', $stagedPrefix, '--cache', $stageCache, '--no-audit', '--no-fund')
    if ($crossWarm) { $npmArgs += @('--os', 'win32', '--cpu', 'x64', '--force') }
    if ($Mode -eq 'npmcache') {
        # Download only: the dependency install scripts belong to the target platform.
        $npmArgs += '--ignore-scripts'
    } elseif ($needAllowScripts) {
        $npmArgs += "--allow-scripts=$OpenClawPackage"
    }
    Write-Host "    npm $($npmArgs -join ' ')"
    $npmRun = Invoke-NpmRetry -Arguments $npmArgs
    $npmLines = $npmRun.Lines
    $npmExit = $npmRun.ExitCode
    if ($npmExit -ne 0) { throw "npm install failed with exit code $npmExit" }

    # npm 11.16+/12 runs install scripts ONLY for packages named in
    # --allow-scripts, and lists the ones it skipped. Native deps such as koffi
    # and tree-sitter-bash need their script, so re-run once with the full list
    # npm itself suggested.
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
        foreach ($pkg in $skipped) { if (-not $installScriptPackages.Contains($pkg)) { $installScriptPackages.Add($pkg) } }
        Write-Note "npm reported install scripts for: $($skipped -join ', ')"
    }
    if ($Mode -eq 'app' -and $skipped.Count -gt 0) {
        $allow = (@($OpenClawPackage) + $skipped) -join ','
        $retryArgs = @('install', '-g', "$OpenClawPackage@$resolvedOpenClaw", '--prefix', $stageApp, '--cache', $stageCache, '--no-audit', '--no-fund', "--allow-scripts=$allow")
        Write-Host "    npm $($retryArgs -join ' ')"
        $retryRun = Invoke-NpmRetry -Arguments $retryArgs
        $retryOut = $retryRun.Lines
        $retryExit = $retryRun.ExitCode
        if ($retryExit -ne 0) {
            Write-Note "re-run with the full --allow-scripts list failed (exit $retryExit). Native deps may be incomplete."
        } else {
            $stillSkipped = @($retryOut | Where-Object { "$_" -match 'install-scripts\s+@?[^\s(]+\s*\(' })
            if ($stillSkipped.Count -gt 0) {
                Write-Note 'npm still reports skipped install scripts - review the log above before shipping this bundle.'
            } else {
                Write-Ok "install scripts covered: $allow"
            }
        }
    }
    if ($Mode -eq 'npmcache') {
        Write-Ok 'cache warmed for win32-x64 (dependency install scripts are left to the target host)'
    } else {
        # Only a persistent app tree is worth a resume marker; npmcache deletes its staging
        # tree right after the platform check, so a marker there would only confuse.
        Set-Content -Path $appMarker -Value "$Mode/$resolvedOpenClaw" -Encoding ASCII
    }
}

# The staged package.json must be read HERE: npmcache mode deletes _cachewarm after the
# platform check, and the manifest (which carries the schema contract) is written later.
# A missing or mismatched package.json means the install did not land what we asked for.
$stagedPkgJson = Join-Path (Join-Path (Get-NpmGlobalModulesRoot $stagedPrefix $OpenClawPackage) $OpenClawPackage) 'package.json'
if (-not (Test-Path $stagedPkgJson)) {
    throw "Cannot read the staged package metadata at $stagedPkgJson - the staging tree is incomplete."
}
$stagedPkgMeta = Get-Content $stagedPkgJson -Raw | ConvertFrom-Json
if ("$($stagedPkgMeta.version)" -ne "$resolvedOpenClaw") {
    throw "Staged tree drifted: requested $resolvedOpenClaw but the installed package reports version $($stagedPkgMeta.version)."
}

if ($Mode -eq 'app') {
    $launcher = Get-ChildItem -Path $stageApp -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq 'openclaw' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
                Select-Object -First 1
    if (-not $launcher) {
        Write-Note "No openclaw launcher directly under $stageApp. Actual layout:"
        Get-ChildItem -Path $stageApp -Recurse -Depth 2 -Force | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host "        $_" }
        throw "Expected an openclaw launcher under $stageApp - check the layout printed above."
    }
    Write-Ok "Launcher: $($launcher.FullName)"
} else {
    Write-Ok 'npmcache mode: no app tree is staged; the target installs the tarball itself'
}

# ---------------------------------------------------------------- upgrade artifact
# The air-gapped upgrade path is `openclaw update --tag <tarball>` (officially supported
# target shape), so the bundle must carry the release artifact itself. `npm pack` also
# warms the same cache the target uses offline for the package's transitive deps.
Write-Step "Packaging the upgrade artifact (openclaw-$resolvedOpenClaw.tgz)"

$tarballName = "openclaw-$resolvedOpenClaw.tgz"
$tarballPath = Join-Path $bundleRoot $tarballName
if (Test-Path $tarballPath) {
    Write-Ok "already present: $tarballName (re-using)"
} else {
    $packArgs = @('pack', "$OpenClawPackage@$resolvedOpenClaw", '--cache', $stageCache, '--pack-destination', $bundleRoot)
    Write-Host "    npm $($packArgs -join ' ')"
    $packRun = Invoke-NpmRetry -Arguments $packArgs
    if ($packRun.ExitCode -ne 0) { throw "npm pack failed with exit code $($packRun.ExitCode)" }
}
if (-not (Test-Path $tarballPath)) {
    $packed = Get-ChildItem -Path $bundleRoot -Filter 'openclaw-*.tgz' -File | Select-Object -First 1
    if (-not $packed) { throw "npm pack did not produce openclaw-$resolvedOpenClaw.tgz in $bundleRoot" }
    $tarballPath = $packed.FullName
    $tarballName = $packed.Name
    Write-Note "npm wrote $tarballName instead of the expected name; using it."
}
$tarballHash = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
Write-Ok "$tarballName $([math]::Round((Get-Item $tarballPath).Length/1MB,1)) MB"
# npm 12 rejects local .tgz installs whose archive name or parent path contains a comma.
if ("$bundleRoot$tarballName" -match ',') {
    Write-Note 'The bundle path or tarball name contains a comma - npm 12 rejects local .tgz installs in that case. Choose another -OutDir.'
}

# Ship the operator/AI-facing docs AND the entry points with the bundle, so the produced
# folder is self-contained: open the bundle folder, double-click install.cmd (or
# upgrade.cmd), and the zero-argument path works because BundleDir defaults to the
# script's own folder. The scripts stay authoritative in the component folder; they are
# copied at build time, so there is never a hand-maintained second copy.
foreach ($name in @('UPGRADE.md', 'UPGRADE-BRIEF.md',
                    'Install-OpenClawOffline.ps1', 'Upgrade-OpenClawOffline.ps1',
                    'install.cmd', 'upgrade.cmd')) {
    $docSrc = Join-Path $PSScriptRoot $name
    if (Test-Path $docSrc) {
        Copy-Item -Path $docSrc -Destination (Join-Path $bundleRoot $name) -Force
        Write-Ok "carried $name"
    } else {
        Write-Note "$name is not next to this script - the bundle will not carry it."
    }
}
Write-Ok 'bundle now carries its own installer and upgrade entry points'

# ---------------------------------------------------------------- docs
# The published package already ships docs/ (the package.json "files" list
# includes it), so the docs are version-matched to this build. Copy them to the
# bundle root as well, so nobody has to hunt through node_modules on the
# air-gapped host. `openclaw docs` searches the LIVE site, so it will not work
# there - reading these files is the offline path.
Write-Step 'Collecting the bundled documentation'
$docsSrc = Join-Path (Join-Path (Get-NpmGlobalModulesRoot $stagedPrefix $OpenClawPackage) $OpenClawPackage) 'docs'
$docsDst = Join-Path $bundleRoot 'docs'
if (-not (Test-Path $docsDst)) { New-Item -ItemType Directory -Force -Path $docsDst | Out-Null }

# Authored capability notes: the air-gapped host can read neither the repo nor the website.
$authoredSrc = Join-Path $PSScriptRoot 'docs'
if (Test-Path $authoredSrc) {
    $authoredRc = Invoke-CopyTree $authoredSrc $docsDst
    if ($authoredRc -ge 8) { Write-Note "authored docs copy failed (exit $authoredRc)" }
    else {
        $authoredCount = @(Get-ChildItem -Path $authoredSrc -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
        Write-Ok "$authoredCount authored page(s) under docs\"
    }
} else {
    Write-Note 'no docs\ next to this script - shipping without the authored capability notes'
}

if (Test-Path (Join-Path $docsDst 'docs_map.md')) {
    Write-Ok 'package docs already collected - skipping'
} elseif (Test-Path $docsSrc) {
    $rc = Invoke-CopyTree $docsSrc $docsDst
    if ($rc -ge 8) { Write-Note "docs copy failed (exit $rc)" }
    else {
        $mdCount = @(Get-ChildItem -Path $docsDst -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
        Write-Ok "$mdCount markdown files, $([math]::Round((Get-ChildItem -Path $docsDst -Recurse -File | Measure-Object -Property Length -Sum).Sum/1MB,1)) MB"
    }
    if (Test-Path (Join-Path $docsDst 'docs_map.md')) { Write-Ok 'docs_map.md present (offline index of every page)' }
} elseif ($Mode -eq 'npmcache' -and $tarballPath) {
    # npmcache mode has no app tree to read from. The published package ships its docs/,
    # so unpack just that folder out of the release tarball (bsdtar ships with Windows 10
    # 1803+ and with macOS) - the docs stay version-matched to the artifact.
    $tarCmd = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if (-not $tarCmd) { $tarCmd = Get-Command 'tar' -ErrorAction SilentlyContinue }
    if (-not $tarCmd) {
        Write-Note 'tar is not available - the bundle ships without the package docs.'
    } else {
        $extractDir = Join-Path $dlDir 'docs-extract'
        if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        $tarRun = Invoke-Native -Command $tarCmd.Source -Arguments @('-xzf', $tarballPath, '-C', $extractDir, 'package/docs')
        if ($tarRun.ExitCode -ne 0) {
            Write-Note "extracting docs from the tarball failed (tar exit $($tarRun.ExitCode)) - shipping without the package docs."
        } else {
            $extracted = Join-Path $extractDir 'package\docs'
            if (Test-Path $extracted) {
                $rc = Invoke-CopyTree $extracted $docsDst
                if ($rc -ge 8) { Write-Note "docs copy failed (exit $rc)" }
                else {
                    $mdCount = @(Get-ChildItem -Path $docsDst -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
                    Write-Ok "$mdCount markdown files extracted from the release tarball"
                    if (Test-Path (Join-Path $docsDst 'docs_map.md')) { Write-Ok 'docs_map.md present (offline index of every page)' }
                }
            } else {
                Write-Note 'The tarball carries no package/docs - shipping without the package docs.'
            }
        }
        Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    }
} else {
    Write-Note 'No package docs available - shipping with the authored notes only.'
}

# ---------------------------------------------------------------- platform check
# A tree resolved for another platform (e.g. darwin-arm64 packages warmed on this Mac)
# is useless on the target and cannot be repaired there. Fail the build instead.
$platformScanRoot = Get-NpmGlobalModulesRoot $stagedPrefix $OpenClawPackage
$platformScan = Get-PlatformPackages $platformScanRoot
$nativePackages = @($platformScan.Native)
if ($platformScan.Foreign.Count -gt 0) {
    throw "The staged tree resolved packages for the wrong platform: $($platformScan.Foreign -join ', '). Rebuild for $TargetPlatform (mode app on Windows x64, or mode npmcache with the --os/--cpu pinning)."
}
Write-Ok "platform check: $($nativePackages.Count) $TargetPlatform package(s), no foreign platform packages (scanned $platformScanRoot)"
if ($nativePackages.Count -gt 0) { Write-Host "        $($nativePackages -join ', ')" }
if ($nativePackages.Count -eq 0 -and ($Mode -eq 'npmcache' -or -not (Test-Path $platformScanRoot))) {
    Write-Note "No $TargetPlatform platform package was found under $platformScanRoot. Either the cross-warm did not pull the win32-x64 optional deps (partial or offline cache), or the prefix layout is unexpected - both mean the target would install an incomplete tree. Verify against a real build before shipping."
}

if ($Mode -eq 'npmcache') {
    if ($KeepStaging) {
        Write-Note "-KeepStaging: $warmStage is still on disk; delete it before copying the bundle to USB."
    } else {
        Remove-Item -Recurse -Force $warmStage -ErrorAction SilentlyContinue
        Write-Ok '_cachewarm staging removed (the warmed cache is what ships)'
    }
}

# ---------------------------------------------------------------- Node (optional)
$nodeZipName = $null; $nodeHash = $null
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
        # Remove the bad file so the next run downloads cleanly instead of
        # resuming on top of corrupt bytes.
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
if (Test-Path $stageApp) { $appFiles = @(Get-ChildItem -Path $stageApp -Recurse -File -Force) }
$pkgMeta  = $stagedPkgMeta
$installedVersion = $stagedPkgMeta.version
# Declared DB schema of this build. The target's upgrade script compares it with the
# installed build's and warns that a forward migration makes rollback backup-only.
$schemaVersions = Get-Prop (Get-Prop $pkgMeta 'openclaw') 'schemaVersions'
if (-not $schemaVersions) {
    Write-Note 'The package declares no openclaw.schemaVersions - the upgrade script cannot warn about a forward schema migration.'
}
$appBytes = Get-TotalBytes $appFiles

$manifest = [ordered]@{
    schemaVersion         = $BundleSchemaVersion
    builtAtUtc            = (Get-Date).ToUniversalTime().ToString('o')
    builtOn               = "$hostOsLabel $arch"
    mode                  = $Mode
    targetPlatform        = $TargetPlatform
    openClawVersion       = $installedVersion
    schemaVersions        = $schemaVersions
    installScriptPackages = @($installScriptPackages)
    nativePackages        = @($nativePackages)
    nodeBundled           = [bool]$IncludeNode
    nodeVersion           = $nodePicked
    nodeZip               = $nodeZipName
    nodeZipSha256         = $nodeHash
    packagedTarball       = $tarballName
    tarballSha256         = $tarballHash
    appFileCount          = $appFiles.Count
    appBytes              = $appBytes
    npmVersionUsed        = $npmVerRaw
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bundleRoot 'bundle-manifest.json') -Encoding UTF8
Write-Ok "openclaw $installedVersion / mode $Mode / $($appFiles.Count) app files / $([math]::Round($appBytes/1MB,1)) MB"

$readme = @"
OpenClaw offline bundle
=======================
openclaw    : $installedVersion
mode        : $Mode   (app = prebuilt tree, npmcache = target installs the tarball offline)
node        : $(if ($nodePicked) { "$nodePicked (bundled)" } else { 'not bundled - bring your own nvm Node (24.16+/26.1+)' })
built       : $($manifest.builtAtUtc)
docs        : docs\
$(if ($Mode -eq 'app') { 'app         : app\  (copied to the install root)' } else { "artifact    : $tarballName + npm-cache\ (the target runs npm install --offline)" })

This folder is self-contained: install.cmd / upgrade.cmd and their scripts are inside it,
so a zero-argument install works from here.

On the air-gapped Windows 10 x64 host:

  1. Prepare Node yourself, for example:
         nvm install 26.7.0
         nvm use 26.7.0
     openclaw needs >=24.16 <25 or >=26.1.

  2. Unblock and install (double-click install.cmd, or):
         Get-ChildItem -Recurse | Unblock-File
         powershell -ExecutionPolicy Bypass -File .\Install-OpenClawOffline.ps1 -BundleDir <this folder> -BaseUrl http://<lan-llm>:<port>/v1 -ModelId <model-id>

Do not rename app\ , docs\ , npm-cache\ or bundle-manifest.json.

No desktop app and no WebView2 runtime are included: use the browser Control UI
(http://127.0.0.1:$DefaultGatewayPort) or pair another client with the setup code the installer
prints.

Upgrading this installation later (see UPGRADE-BRIEF.md for the full procedure):

  1. Build a new bundle on a networked Windows x64 machine with the same
     Make-OpenClawOfflineBundle.ps1. It carries openclaw-<version>.tgz plus a
     warm npm-cache\ - that is what makes the offline upgrade possible.
  2. On this host run upgrade.cmd (double-click) or:
         powershell -ExecutionPolicy Bypass -File .\Upgrade-OpenClawOffline.ps1
     It backs up state first, stops the Gateway, runs the official
         openclaw update --tag <bundle>\openclaw-<version>.tgz --dry-run
     preflight, then applies the update and reinstalls the service.
  3. Rollback is BACKUP-ONLY. Upgrading migrates the state database forward and
     older builds then refuse to open it, so restoring an old package does not
     work: restore the pre-upgrade archive instead
         openclaw backup restore <archive> --target <empty dir>

Reading the docs on the air-gapped host: open docs\docs_map.md for the page
index. Note that the 'openclaw docs' command searches the live website and will
not work offline - read the markdown files directly.
"@
Set-Content -Path (Join-Path $bundleRoot 'README.txt') -Value $readme -Encoding UTF8

Write-Host ''
Write-Host 'Bundle ready:' -ForegroundColor Green
Get-ChildItem -Path $bundleRoot -Force | Where-Object { $_.Name -notin @('_download', '_cachewarm') } |
    ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Name, $(if ($_.PSIsContainer) { '' } else { "$([math]::Round($_.Length/1KB,1)) KB" })) }
Write-Host ''
Write-Host 'Copy the folder (not the top-level folder itself into _download) to the air-gapped host.' -ForegroundColor Green

# ---------------------------------------------------------------- residue check
Write-Step 'Residue check'
$residueAfter = Get-ResidueSnapshot
$findings = @()
if (-not $residueBefore.OpenClawState -and $residueAfter.OpenClawState) { $findings += "$residueHome\.openclaw was created" }
if (-not $residueBefore.NpmGlobalDir -and $residueAfter.NpmGlobalDir) { $findings += "$residueAppData\npm was created" }
if ($residueAfter.OpenClawTasks -ge 0 -and $residueBefore.OpenClawTasks -ge 0 -and $residueAfter.OpenClawTasks -gt $residueBefore.OpenClawTasks) {
    $findings += 'an openclaw scheduled task was created'
}
if ($residueAfter.OpenClawTasks -lt 0) { Write-Note 'scheduled-task check unavailable on this host (module missing)' }

if ($findings.Count -eq 0) {
    Write-Ok 'no state dir, no global npm prefix dir, no scheduled task'
    Write-Ok 'this script uses no registry-write cmdlet and no installer'
    Write-Ok "the only files created are under $bundleRoot"
} else {
    foreach ($f in $findings) { Write-Note $f }
}
Write-Note "to leave nothing behind: Remove-Item -Recurse -Force `"$bundleRoot`"  (do this AFTER copying to USB)"
Write-Note 'deleted files do not go to the Recycle Bin. Execution traces (Prefetch, USN, PSReadLine history) are not removable by design.'
