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

.EXAMPLE
    .\Make-OpenClawOfflineBundle.ps1 -OutDir D:\bundle
#>
[CmdletBinding()]
param(
    [string]$OpenClawVersion = 'latest',
    [switch]$IncludeNode,
    [string]$NodeVersion = '',
    [string]$OutDir = (Join-Path (Get-Location) 'openclaw-offline-bundle'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    !!  $Text" -ForegroundColor Yellow }

# Snapshot of the machine state this script must not alter. Used to prove the run
# left no file/registry-level residue outside the output folder.
function Get-ResidueSnapshot {
    $tasks = 0
    try { $tasks = @(Get-ScheduledTask -TaskName '*openclaw*' -ErrorAction SilentlyContinue).Count } catch { $tasks = -1 }
    [pscustomobject]@{
        OpenClawState = (Test-Path (Join-Path $env:USERPROFILE '.openclaw'))
        NpmGlobalDir  = (Test-Path (Join-Path $env:APPDATA 'npm'))
        OpenClawTasks = $tasks
    }
}

# ---------------------------------------------------------------- preflight
Write-Step 'Preflight'

if ($env:OS -ne 'Windows_NT') { throw 'This script must run on Windows.' }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows host is required.' }
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
if ($arch -ne 'X64') { throw "Build the bundle on Windows x64 (detected: $arch): the app tree has arch-specific native deps." }
Write-Ok "Host: Windows $arch, PowerShell $($PSVersionTable.PSVersion)"

foreach ($exe in @('node', 'npm')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        throw "'$exe' not found on PATH. Install Node 24.16+ / 26.1+ first (nvm-windows is fine)."
    }
}
$nodeProbe = Invoke-Native -Command 'node' -Arguments @('-v')
$hostNodeRaw = "$($nodeProbe.Lines | Select-Object -Last 1)".Trim()
if ($hostNodeRaw -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "Unrecognized Node version: $hostNodeRaw" }
$hostNode = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
$nodeOk = (($hostNode -ge [version]'24.16.0' -and $hostNode -lt [version]'25.0.0') -or ($hostNode -ge [version]'26.1.0'))
if (-not $nodeOk) { throw "Local Node $hostNodeRaw is unsupported (need >=24.16 <25, or >=26.1)." }
Write-Ok "Local Node $hostNodeRaw"

$npmProbe = Invoke-Native -Command 'npm' -Arguments @('--version')
$npmVerRaw = "$($npmProbe.Lines | Select-Object -Last 1)".Trim()
if ($npmVerRaw -notmatch '^(\d+)\.(\d+)') { throw "Unrecognized npm version: $npmVerRaw" }
$needAllowScripts = ([int]$Matches[1] -gt 11) -or ([int]$Matches[1] -eq 11 -and [int]$Matches[2] -ge 16)
Write-Ok "Local npm $npmVerRaw (needs --allow-scripts: $needAllowScripts)"

$residueBefore = Get-ResidueSnapshot
Write-Ok "Baseline: .openclaw=$($residueBefore.OpenClawState), `$env:APPDATA\npm=$($residueBefore.NpmGlobalDir), openclaw tasks=$($residueBefore.OpenClawTasks)"

# ---------------------------------------------------------------- resolve versions
Write-Step 'Resolving versions'

if ($OpenClawVersion -eq 'latest') {
    $viewProbe = Invoke-Native -Command 'npm' -Arguments @('view', 'openclaw', 'version')
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
            $pick = $stable | Where-Object { $_.version -match '^v24\.' -and [version]($_.version.TrimStart('v')) -ge [version]'24.16.0' } |
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

foreach ($p in @($bundleRoot, $stageApp, $stageCache, $stageNode, $dlDir)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
Write-Ok "Staging under $bundleRoot"

# ---------------------------------------------------------------- OpenClaw
Write-Step "Installing openclaw@$resolvedOpenClaw into the bundle prefix"

$pkgJsonPath = Join-Path $stageApp 'node_modules\openclaw\package.json'
$appMarker = Join-Path $bundleRoot '.app-complete'
$alreadyVersion = $null
if (Test-Path $pkgJsonPath) { $alreadyVersion = (Get-Content $pkgJsonPath -Raw | ConvertFrom-Json).version }

if (($alreadyVersion -eq $resolvedOpenClaw) -and (Test-Path $appMarker)) {
    Write-Ok "openclaw $resolvedOpenClaw is already in the bundle - skipping npm install"
} else {
    $npmArgs = @('install', '-g', "openclaw@$resolvedOpenClaw", '--prefix', $stageApp, '--cache', $stageCache, '--no-audit', '--no-fund')
    if ($needAllowScripts) { $npmArgs += '--allow-scripts=openclaw' }
    Write-Host "    npm $($npmArgs -join ' ')"
    $npmRun = Invoke-Native -Command 'npm' -Arguments $npmArgs -Show
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
        Write-Note "npm skipped install scripts for: $($skipped -join ', ')"
        $allow = (@('openclaw') + $skipped) -join ','
        $retryArgs = @('install', '-g', "openclaw@$resolvedOpenClaw", '--prefix', $stageApp, '--cache', $stageCache, '--no-audit', '--no-fund', "--allow-scripts=$allow")
        Write-Host "    npm $($retryArgs -join ' ')"
        $retryRun = Invoke-Native -Command 'npm' -Arguments $retryArgs -Show
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
    # Only a tree whose install scripts actually ran is safe to reuse on resume.
    Set-Content -Path $appMarker -Value $resolvedOpenClaw -Encoding ASCII
}

$launcher = Get-ChildItem -Path $stageApp -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq 'openclaw' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
            Select-Object -First 1
if (-not $launcher) {
    Write-Note "No openclaw launcher directly under $stageApp. Actual layout:"
    Get-ChildItem -Path $stageApp -Recurse -Depth 2 -Force | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host "        $_" }
    throw "Expected an openclaw launcher under $stageApp - check the layout printed above."
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
    $packArgs = @('pack', "openclaw@$resolvedOpenClaw", '--cache', $stageCache, '--pack-destination', $bundleRoot)
    Write-Host "    npm $($packArgs -join ' ')"
    $packRun = Invoke-Native -Command 'npm' -Arguments $packArgs -Show
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

# Ship the operator/AI-facing upgrade docs with the bundle (the target has no internet).
foreach ($docName in @('UPGRADE.md', 'UPGRADE-BRIEF.md')) {
    $docSrc = Join-Path $PSScriptRoot $docName
    if (Test-Path $docSrc) {
        Copy-Item -Path $docSrc -Destination (Join-Path $bundleRoot $docName) -Force
        Write-Ok "carried $docName"
    } else {
        Write-Note "$docName is not next to this script - the bundle will not carry it."
    }
}
Write-Ok "Launcher: $($launcher.FullName)"

# ---------------------------------------------------------------- docs
# The published package already ships docs/ (the package.json "files" list
# includes it), so the docs are version-matched to this build. Copy them to the
# bundle root as well, so nobody has to hunt through node_modules on the
# air-gapped host. `openclaw docs` searches the LIVE site, so it will not work
# there - reading these files is the offline path.
Write-Step 'Collecting the bundled documentation'
$docsSrc = Join-Path $stageApp 'node_modules\openclaw\docs'
$docsDst = Join-Path $bundleRoot 'docs'
if (Test-Path (Join-Path $docsDst 'docs_map.md')) {
    Write-Ok 'docs already collected - skipping'
} elseif (Test-Path $docsSrc) {
    $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList `
        "`"$docsSrc`" `"$docsDst`" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP"
    if ($rc.ExitCode -ge 8) { Write-Note "docs copy failed (robocopy exit $($rc.ExitCode))" }
    else {
        $mdCount = @(Get-ChildItem -Path $docsDst -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
        Write-Ok "$mdCount markdown files, $([math]::Round((Get-ChildItem -Path $docsDst -Recurse -File | Measure-Object -Property Length -Sum).Sum/1MB,1)) MB"
    }
    $map = Join-Path $docsDst 'docs_map.md'
    if (Test-Path $map) { Write-Ok 'docs_map.md present (offline index of every page)' }
} else {
    Write-Note 'No docs/ inside the openclaw package - shipping without offline documentation.'
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

$appFiles = @(Get-ChildItem -Path $stageApp -Recurse -File -Force)
$pkgJson  = Join-Path $stageApp 'node_modules\openclaw\package.json'
$pkgMeta  = if (Test-Path $pkgJson) { Get-Content $pkgJson -Raw | ConvertFrom-Json } else { $null }
$installedVersion = if ($pkgMeta) { $pkgMeta.version } else { $resolvedOpenClaw }
# Declared DB schema of this build. The target's upgrade script compares it with the
# installed build's and warns that a forward migration makes rollback backup-only.
$schemaVersions = Get-Prop (Get-Prop $pkgMeta 'openclaw') 'schemaVersions'

$manifest = [ordered]@{
    schemaVersion       = 4
    builtAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
    builtOn             = "Windows $arch"
    openClawVersion     = $installedVersion
    schemaVersions      = $schemaVersions
    nodeBundled         = [bool]$IncludeNode
    nodeVersion         = $nodePicked
    nodeZip             = $nodeZipName
    nodeZipSha256       = $nodeHash
    packagedTarball     = $tarballName
    tarballSha256       = $tarballHash
    appFileCount        = $appFiles.Count
    appBytes            = ($appFiles | Measure-Object -Property Length -Sum).Sum
    npmVersionUsed      = $npmVerRaw
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bundleRoot 'bundle-manifest.json') -Encoding UTF8
Write-Ok "openclaw $installedVersion / $($appFiles.Count) files / $([math]::Round($manifest.appBytes/1MB,1)) MB"

$readme = @"
OpenClaw offline bundle
=======================
openclaw    : $installedVersion
node        : $(if ($nodePicked) { "$nodePicked (bundled)" } else { 'not bundled - bring your own nvm Node (24.16+/26.1+)' })
built       : $($manifest.builtAtUtc)
docs        : docs\  (also inside app\node_modules\openclaw\docs)

On the air-gapped Windows 10 x64 host:

  1. Prepare Node yourself, for example:
         nvm install 26.7.0
         nvm use 26.7.0
     openclaw needs >=24.16 <25 or >=26.1.

  2. Unblock and install:
         Get-ChildItem -Recurse | Unblock-File
         powershell -ExecutionPolicy Bypass -File .\Install-OpenClawOffline.ps1 -BundleDir <this folder> -BaseUrl http://<lan-llm>:<port>/v1 -ModelId <model-id>

Do not rename app\ , docs\ , npm-cache\ or bundle-manifest.json.

No desktop app and no WebView2 runtime are included: use the browser Control UI
(http://127.0.0.1:18789) or pair another client with the setup code the installer
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
Get-ChildItem -Path $bundleRoot -Force | Where-Object { $_.Name -ne '_download' } |
    ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Name, $(if ($_.PSIsContainer) { '' } else { "$([math]::Round($_.Length/1KB,1)) KB" })) }
Write-Host ''
Write-Host 'Copy the folder (not the top-level folder itself into _download) to the air-gapped host.' -ForegroundColor Green

# ---------------------------------------------------------------- residue check
Write-Step 'Residue check'
$residueAfter = Get-ResidueSnapshot
$findings = @()
if (-not $residueBefore.OpenClawState -and $residueAfter.OpenClawState) { $findings += "$env:USERPROFILE\.openclaw was created" }
if (-not $residueBefore.NpmGlobalDir -and $residueAfter.NpmGlobalDir) { $findings += "$env:APPDATA\npm was created" }
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
