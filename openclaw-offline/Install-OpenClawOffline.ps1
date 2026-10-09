<#
.SYNOPSIS
    Install OpenClaw (CLI + Gateway) from an offline bundle.

.DESCRIPTION
    RUN THIS ON THE AIR-GAPPED WINDOWS 10 x64 HOST, as the user who will own the
    Gateway (not as SYSTEM). No outbound network access is performed.

    Assumes Node is already installed with nvm-windows and active.

    Steps: verify bundle -> check Node -> unpack OpenClaw -> PATH -> verify CLI ->
    collect docs -> create the base config (model provider optional) -> install and
    start the Gateway -> print pairing details and a provider template.

    Zero-argument invocation works: BundleDir defaults to the folder this script
    lives in, and provider setup is skipped unless -BaseUrl and -ModelId are given.

    This bundle carries no Windows desktop app (OpenClaw Companion) and no WebView2
    runtime. Use the Control UI in a browser, or pair another client with the setup
    code printed at the end.

.PARAMETER BundleDir
    Folder produced by Make-OpenClawOfflineBundle.ps1. Defaults to this script's folder.

.PARAMETER BaseUrl
    Optional. Base URL of the LAN model endpoint. For an OpenAI-compatible server
    this normally includes the version segment, e.g. http://10.0.0.20:8000/v1.
    Omit both -BaseUrl and -ModelId to skip provider setup entirely; a template is
    then written to the install root for you to fill in and apply yourself.

.PARAMETER ModelId
    Optional. Exact model id the endpoint expects, e.g. qwen3-32b

.EXAMPLE
    # zero arguments: BundleDir defaults to the folder this script sits in
    .\Install-OpenClawOffline.ps1

    # or let the script configure the LAN provider for you
    $env:LLM_KEY = 'sk-lan'
    .\Install-OpenClawOffline.ps1 -BaseUrl http://10.0.0.20:8000/v1 -ModelId qwen3-32b -ApiKeyEnv LLM_KEY
#>
[CmdletBinding()]
param(
    [string]$BundleDir = '',
    [string]$BaseUrl = '',
    [string]$ModelId = '',
    [string]$InstallRoot = 'C:\OpenClaw',
    [string]$ProviderId = 'lan',
    [string]$AgentName = 'main',
    [ValidateSet('openai', 'openai-responses', 'anthropic')][string]$Compatibility = 'openai',
    [string]$ApiKey = '',
    [string]$ApiKeyEnv = '',
    [ValidateSet('plaintext', 'ref')][string]$SecretInputMode = 'plaintext',
    [int]$GatewayPort = 18789,
    [string]$Workspace = '',
    [switch]$SkipPathUpdate,
    [switch]$NoGatewayInstall,
    [switch]$CheckEndpoint,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 compatibility (the target host shell): Join-Path has no
# -AdditionalChildPath there - that parameter is PowerShell 6.0+ - so it must
# NEVER be called with more than two positional arguments. Nest the calls:
#   Join-Path (Join-Path $root 'sub') $leaf
# Everything else in this script stays inside the 5.1 surface on purpose (no ??,
# ?:, -AsHashtable, Get-Error or $IsWindows).

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    !!  $Text" -ForegroundColor Yellow }

# StrictMode turns a missing property into a TERMINATING error. Bundle manifests
# differ by mode (app vs npmcache), so read every optional field through this.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# A native command that writes to stderr raises NativeCommandError, and with
# $ErrorActionPreference = 'Stop' that becomes a TERMINATING error - even with
# 2>&1 (PowerShell 5.1). The openclaw CLI prints warnings to stderr on a normal
# run, so every native call goes through here with the preference relaxed.
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

function Invoke-Robocopy([string]$Source, [string]$Destination) {
    # Start-Process does not quote array elements, so build the argument string.
    $argString = "`"$Source`" `"$Destination`" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP"
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -Wait -PassThru -NoNewWindow
    return $proc.ExitCode
}

# ---------------------------------------------------------------- verify bundle
Write-Step 'Verifying bundle'

if (-not $BundleDir) {
    if ($PSScriptRoot) { $BundleDir = $PSScriptRoot } else { $BundleDir = (Get-Location).Path }
}
$BundleDir = [System.IO.Path]::GetFullPath($BundleDir)
$manifestPath = Join-Path $BundleDir 'bundle-manifest.json'
if (-not (Test-Path $manifestPath)) { throw "bundle-manifest.json not found in $BundleDir" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$appStage   = Join-Path $BundleDir 'app'
$cacheStage = Join-Path $BundleDir 'npm-cache'
$nodeStage  = Join-Path $BundleDir 'node'

# mode 'app'      = prebuilt Windows app tree (made by Make-OpenClawOfflineBundle.ps1)
# mode 'npmcache' = npm cache prepared on macOS; this host runs the real install
$mode = Get-Prop $manifest 'mode'
if (-not $mode) { $mode = if (Test-Path $appStage) { 'app' } else { 'npmcache' } }
if ($mode -eq 'app') {
    if (-not (Test-Path $appStage)) { throw "Bundle is incomplete: missing $appStage" }
    Write-Ok "openclaw $($manifest.openClawVersion) / mode app / built on $($manifest.builtOn)"
} elseif ($mode -eq 'npmcache') {
    if (-not (Test-Path $cacheStage)) { throw "Bundle is incomplete: missing $cacheStage (required in npmcache mode)" }
    $cacheFiles = @(Get-ChildItem -Path $cacheStage -Recurse -File -Force).Count
    if ($cacheFiles -lt 10) { throw "npm cache looks empty ($cacheFiles files) - do not install from it" }
    Write-Ok "openclaw $($manifest.openClawVersion) / mode npmcache / built on $($manifest.builtOn)"
} else {
    throw "Unsupported bundle mode: $mode"
}

# See Make-OpenClawOfflineBundle.ps1: RuntimeInformation.OSArchitecture is absent
# on Windows PowerShell 5.1, and StrictMode makes that a terminating error.
$procArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ("$procArch" -ne 'AMD64') { throw "This bundle is Windows x64 only (detected: $procArch)." }

$nodeBundled = [bool](Get-Prop $manifest 'nodeBundled')
if ($nodeBundled) {
    # Make-OpenClawOfflineBundle.ps1 downloads the archive into the staging folder
    # <bundle>\_download and records only its file name in the manifest, while the
    # extracted runtime lives in <bundle>\node. Look in both places so a bundle
    # built by either layout still verifies.
    $downloadStage = Join-Path $BundleDir '_download'
    $nodeZip = @(
        (Join-Path $BundleDir $manifest.nodeZip),
        (Join-Path $downloadStage $manifest.nodeZip)
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($nodeZip) {
        $h = (Get-FileHash -Path $nodeZip -Algorithm SHA256).Hash
        if ($h -ne $manifest.nodeZipSha256) { throw "Node archive hash mismatch. expected=$($manifest.nodeZipSha256) actual=$h" }
        Write-Ok "Bundled Node archive SHA256 verified ($nodeZip)"
    } elseif (Test-Path (Join-Path $nodeStage 'node.exe')) {
        # The _download staging folder is documented as safe to delete before
        # copying the bundle (it also carries the archive through the USB step), and
        # what actually gets installed is the extracted tree - so continue, but say
        # so plainly.
        Write-Note "$($manifest.nodeZip) is not in the bundle (already extracted); skipping the archive SHA256 check."
        Write-Note "Using the extracted runtime at $nodeStage\node.exe"
    } else {
        throw "Bundle is incomplete: no $($manifest.nodeZip) in $BundleDir or $downloadStage, and no extracted node\node.exe"
    }
}
if ($mode -eq 'app') {
    Write-Ok "OpenClaw tree: $($manifest.appFileCount) files / $([math]::Round($manifest.appBytes/1MB,1)) MB"
}

# ---------------------------------------------------------------- Node preflight
Write-Step 'Checking the Node runtime (nvm-managed)'

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    throw "node is not on PATH. Run 'nvm use <version>' in this shell (or open a new shell) and retry."
}
$nodeProbe = Invoke-Native -Command 'node' -Arguments @('-v')
$nodeRaw = "$($nodeProbe.Lines | Select-Object -Last 1)".Trim()
if ($nodeRaw -notmatch '^v(\d+)\.(\d+)\.(\d+)') { throw "Unrecognized Node version: $nodeRaw" }
$nodeVer = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
$nodeOk = (($nodeVer -ge [version]'24.16.0' -and $nodeVer -lt [version]'25.0.0') -or ($nodeVer -ge [version]'26.1.0'))
if (-not $nodeOk) {
    throw "Node $nodeRaw is outside the supported range (need >=24.16 <25, or >=26.1). Fix with: nvm install 26.7.0 ; nvm use 26.7.0"
}
Write-Ok "node $nodeRaw at $($nodeCmd.Source)"
Write-Note 'nvm: keep the active version inside the supported range. openclaw resolves node from PATH, so switching to an unsupported version breaks the CLI.'

# ---------------------------------------------------------------- install app
# Normalise the install root once, then refuse the two ways a mistyped -InstallRoot
# turns -Force into an unrecoverable delete: a drive root and a system folder.
# (Make-OpenClawOfflineBundle.ps1 has the same guard for -OutDir.)
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

Write-Step "Installing OpenClaw into $InstallRoot"

if (Test-Path $InstallRoot) {
    if (-not $Force) {
        throw "$InstallRoot already exists. To UPGRADE an existing install use Upgrade-OpenClawOffline.ps1 from a newer bundle (it keeps state and can be rolled back); to wipe and reinstall from scratch, re-run with -Force (rescue mode)."
    }
    Write-Note "-Force (rescue mode): removing the existing tree at $InstallRoot"
    Remove-Item -Recurse -Force $InstallRoot
}
$appDir = Join-Path $InstallRoot 'app'
$cacheDir = Join-Path $InstallRoot 'npm-cache'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null

if ($mode -eq 'app') {
    Write-Host '    Copying OpenClaw and dependencies (this takes a minute) ...'
    $rc = Invoke-Robocopy $appStage $appDir
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
    Write-Ok 'Application files copied'

    # The app tree is the payload most exposed to USB/media corruption and the manifest
    # already records its shape, so compare it instead of trusting the copy.
    $expectedCount = Get-Prop $manifest 'appFileCount'
    $expectedBytes = Get-Prop $manifest 'appBytes'
    $copiedFiles = @(Get-ChildItem -Path $appDir -Recurse -File -Force)
    $copiedBytes = ($copiedFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $copiedBytes) { $copiedBytes = 0 }
    if ($null -ne $expectedCount -and $copiedFiles.Count -ne [int]$expectedCount) {
        throw "App tree file count mismatch after copy: expected $expectedCount, found $($copiedFiles.Count). The bundle or the media is damaged - do not use this installation."
    }
    if ($null -ne $expectedBytes -and $copiedBytes -ne [long]$expectedBytes) {
        throw "App tree byte count mismatch after copy: expected $expectedBytes, found $copiedBytes. The bundle or the media is damaged - do not use this installation."
    }
    Write-Ok "app tree verified: $($copiedFiles.Count) files / $([math]::Round($copiedBytes/1MB,1)) MB"
} else {
    Write-Host '    Copying the npm cache ...'
    $rc = Invoke-Robocopy $cacheStage $cacheDir
    if ($rc -ge 8) { throw "robocopy failed copying the npm cache (exit $rc)" }
    Write-Ok 'npm cache copied'

    Write-Host "    Running the offline install: npm install -g openclaw@$($manifest.openClawVersion) --offline"
    $npmProbe = Invoke-Native -Command 'npm' -Arguments @('--version')
    $npmRaw = "$($npmProbe.Lines | Select-Object -Last 1)".Trim()
    if ($npmRaw -notmatch '^(\d+)\.(\d+)') { throw "Unrecognized npm version: $npmRaw" }
    $needAllow = ([int]$Matches[1] -gt 11) -or ([int]$Matches[1] -eq 11 -and [int]$Matches[2] -ge 16)
    $npmArgs = @('install', '-g', "openclaw@$($manifest.openClawVersion)", '--prefix', $appDir,
                 '--cache', $cacheDir, '--offline', '--no-audit', '--no-fund')
    if ($needAllow) { $npmArgs += '--allow-scripts=openclaw' }
    Write-Host "    npm $($npmArgs -join ' ')"
    $npmRun = Invoke-Native -Command 'npm' -Arguments $npmArgs -Show
    if ($npmRun.ExitCode -ne 0) {
        throw "Offline npm install failed (exit $($npmRun.ExitCode)). The cache may be incomplete for this npm/Node combination - retry without --offline only if this host can reach the registry."
    }
    Write-Ok 'openclaw installed from cache'
}

if ($nodeBundled) {
    $nodeDir = Join-Path $InstallRoot 'node'
    New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
    Write-Host '    Copying the bundled Node runtime ...'
    Copy-Item -Path (Join-Path $nodeStage '*') -Destination $nodeDir -Recurse -Force
    Write-Ok 'Node runtime copied'
}

if ($mode -eq 'app' -and (Test-Path $cacheStage)) {
    Write-Host '    Copying npm cache (optional offline reinstall source) ...'
    $rc = Invoke-Robocopy $cacheStage $cacheDir
    if ($rc -ge 8) { Write-Note "npm cache copy skipped (robocopy exit $rc)" } else { Write-Ok 'npm cache copied' }
}

# ---------------------------------------------------------------- docs
$docsStage = Join-Path $BundleDir 'docs'
$docsDir   = Join-Path $InstallRoot 'docs'
if (Test-Path $docsStage) {
    Write-Step 'Copying the offline documentation'
    $rc = Invoke-Robocopy $docsStage $docsDir
    if ($rc -ge 8) { Write-Note "docs copy skipped (robocopy exit $rc)" }
    else {
        $mdCount = @(Get-ChildItem -Path $docsDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
        Write-Ok "$mdCount pages at $docsDir"
        Write-Note 'openclaw docs searches the LIVE site and will not work offline. Read these files instead.'
    }
}

# ---------------------------------------------------------------- PATH
$pathWanted = @($appDir)
if ($nodeBundled) { $pathWanted = @((Join-Path $InstallRoot 'node')) + $pathWanted }

if (-not $SkipPathUpdate) {
    Write-Step 'Updating the per-user PATH'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $entries = @($userPath.Split(';') | Where-Object { $_ -ne '' })
    # Match on the entry with trailing separators trimmed; -contains is
    # case-insensitive, so "C:\OpenClaw\app\" and "c:\openclaw\app" are one entry
    # and must not be appended a second time.
    $normalized = @($entries | ForEach-Object { $_.TrimEnd('\') })
    $changed = $false
    foreach ($want in $pathWanted) {
        if ($normalized -contains $want.TrimEnd('\')) {
            Write-Ok "Already present: $want"
        } else {
            $entries += $want
            $normalized += $want.TrimEnd('\')
            $changed = $true
            Write-Ok "Added $want"
        }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    } else {
        Write-Ok 'User PATH already lists every entry; left untouched'
    }
    if ($userPath -match '%') {
        Write-Note 'The user PATH uses %VAR% references; saving it through .NET writes them expanded. Check PATH in a NEW shell.'
    }
} else {
    Write-Note 'PATH not modified (-SkipPathUpdate). Add manually:'
    $pathWanted | ForEach-Object { Write-Host "        $_" }
}
$env:Path = (($pathWanted + $env:Path) -join ';')

# ---------------------------------------------------------------- verify CLI
Write-Step 'Verifying the CLI'

$launcher = Get-ChildItem -Path $appDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq 'openclaw' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
            Select-Object -First 1
if (-not $launcher) { throw "No openclaw launcher found under $appDir" }
$openclawCmd = $launcher.FullName

$verRun = Invoke-Native -Command $openclawCmd -Arguments @('--version')
$ver = ($verRun.Lines -join ' ').Trim()
Write-Ok $ver
if ($ver -notmatch [regex]::Escape($manifest.openClawVersion)) {
    Write-Note "Reported version differs from the bundle manifest ($($manifest.openClawVersion))."
}
Invoke-Native -Command $openclawCmd -Arguments @('doctor', '--lint') -Show | Out-Null

# ---------------------------------------------------------------- endpoint check
if ($CheckEndpoint) {
    Write-Step 'Checking the LAN model endpoint'
    try {
        $headers = @{}
        if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
        elseif ($ApiKeyEnv) { $headers['Authorization'] = "Bearer $([Environment]::GetEnvironmentVariable($ApiKeyEnv))" }
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) 'openclaw-probe.txt'
        Invoke-WebRequest -Uri ($BaseUrl.TrimEnd('/') + '/models') -Headers $headers -UseBasicParsing -TimeoutSec 20 -OutFile $probe | Out-Null
        Remove-Item $probe -ErrorAction SilentlyContinue
        Write-Ok "$($BaseUrl.TrimEnd('/') + '/models') reachable"
    } catch {
        Write-Note "Endpoint probe failed: $($_.Exception.Message)"
        Write-Note 'Not every server exposes /models. If it does, fix -BaseUrl before using the agent.'
    }
}

# ---------------------------------------------------------------- onboard
$configureProvider = [bool]($BaseUrl -and $ModelId)

$commonOnboard = @(
    'onboard', '--non-interactive', '--accept-risk', '--skip-health',
    '--gateway-port', "$GatewayPort",
    '--gateway-bind', 'loopback',
    '--agent-name', $AgentName,
    '--no-install-daemon',
    '--skip-channels',
    '--skip-search',
    '--skip-ui'
)
if ($Workspace) { $commonOnboard += @('--workspace', $Workspace) }

if ($configureProvider) {
    Write-Step 'Configuring the custom LAN model provider'
    $onboardArgs = $commonOnboard + @(
        '--auth-choice', 'custom-api-key',
        '--custom-provider-id', $ProviderId,
        '--custom-base-url', $BaseUrl,
        '--custom-model-id', $ModelId,
        '--custom-compatibility', $Compatibility,
        '--secret-input-mode', $SecretInputMode
    )
    if ($ApiKey) { $onboardArgs += @('--custom-api-key', $ApiKey) }
    if ($ApiKeyEnv -and -not $ApiKey) {
        if (-not (Test-Path "Env:$ApiKeyEnv")) { throw "-ApiKeyEnv $ApiKeyEnv is not set in this session. Set it first, or pass -ApiKey." }
        Write-Ok "API key will reference `$env:$ApiKeyEnv"
    }
} else {
    Write-Step 'Creating the base configuration (model provider not set)'
    Write-Note 'No -BaseUrl/-ModelId given, so provider setup is skipped. A template is written at the end.'
    $onboardArgs = $commonOnboard + @('--auth-choice', 'skip')
}

Write-Host "    $($onboardArgs -join ' ')"
$onboardRun = Invoke-Native -Command $openclawCmd -Arguments $onboardArgs -Show
if ($onboardRun.ExitCode -ne 0) { throw "openclaw onboard failed with exit code $($onboardRun.ExitCode)" }

if ($configureProvider -and $ApiKeyEnv -and -not $ApiKey) {
    Write-Host "    Binding models.providers.$ProviderId.apiKey to env:$ApiKeyEnv ..."
    $setRun = Invoke-Native -Command $openclawCmd -Arguments @('config', 'set', "models.providers.$ProviderId.apiKey", '--ref-provider', 'default', '--ref-source', 'env', '--ref-id', $ApiKeyEnv) -Show
    if ($setRun.ExitCode -ne 0) { throw "openclaw config set failed with exit code $($setRun.ExitCode)" }
    Write-Ok 'SecretRef written (the key stays out of openclaw.json)'
}

Write-Step 'Verifying the configuration'
Invoke-Native -Command $openclawCmd -Arguments @('config', 'validate') -Show | Out-Null
if ($configureProvider) {
    foreach ($path in @('agents.defaults.model', "models.providers.$ProviderId.baseUrl", "models.providers.$ProviderId.models")) {
        $getRun = Invoke-Native -Command $openclawCmd -Arguments @('config', 'get', $path)
        Write-Host "    $path = $($getRun.Lines -join ' ')"
    }
}

# The Gateway checks https://telemetry.openclaw.ai on start and at most once every 24h
# by default. This host has no internet, so switch that off (official opt-out).
$checkRun = Invoke-Native -Command $openclawCmd -Arguments @('config', 'set', 'update.checkOnStart', 'false')
if ($checkRun.ExitCode -ne 0) {
    Write-Note 'Could not set update.checkOnStart=false; set OPENCLAW_NO_AUTO_UPDATE=1 in the Gateway environment instead.'
} else {
    Write-Ok 'update.checkOnStart=false (no outbound update checks on this air-gapped host)'
}

Write-Host ''
Write-Note 'Offline note: onboarding may warn about channels, skills, search, plugins and updates. Those need internet and are expected to fail here; local chat is unaffected.'

# ---------------------------------------------------------------- gateway
if ($NoGatewayInstall) {
    Write-Step 'Gateway service skipped (-NoGatewayInstall)'
    Write-Host "    Start manually with:  `"$openclawCmd`" gateway run"
} else {
    Write-Step 'Installing the Gateway service (Windows Scheduled Task)'
    $installRun = Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'install', '--port', "$GatewayPort") -Show
    if ($installRun.ExitCode -ne 0) {
        Write-Note 'gateway install failed; retrying with --allow-unconfigured'
        Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'install', '--port', "$GatewayPort", '--allow-unconfigured') -Show | Out-Null
    }
    Start-Sleep -Seconds 3
    Write-Step 'Gateway status'
    Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'status', '--json') -Show | Out-Null
}

# ---------------------------------------------------------------- pairing
Write-Step 'Gateway pairing details'

$gwUrl = "ws://127.0.0.1:$GatewayPort"
$tokenRun = Invoke-Native -Command $openclawCmd -Arguments @('config', 'get', 'gateway.auth.token')
$token = ($tokenRun.Lines -join ' ').Trim()
Write-Host "    Gateway URL : $gwUrl"
if ($token -and $token -notmatch 'Error|error') { Write-Host "    Gateway token: $token" }

$setupCode = $null
try {
    $qrRun = Invoke-Native -Command $openclawCmd -Arguments @('qr', '--setup-code-only', '--url', $gwUrl)
    $setupCode = ($qrRun.Lines -join ' ').Trim()
} catch {
    Write-Note "Setup code generation failed: $($_.Exception.Message)"
}
if ($setupCode -and $setupCode.Length -lt 4096 -and $setupCode -notmatch 'Error|error|not found') {
    Write-Host ''
    Write-Host '    Setup code (paste into the client you are pairing):' -ForegroundColor Cyan
    Write-Host "    $setupCode"
}

# ---------------------------------------------------------------- provider template
if (-not $configureProvider) {
    Write-Step 'Model provider template'
    $providerTemplate = Join-Path $InstallRoot 'provider-template.json5'
    $templateBody = @'
{
  // OpenClaw config patch (JSON5). Replace the placeholders, then run:
  //   openclaw config patch --file provider-template.json5 --dry-run
  //   openclaw config patch --file provider-template.json5
  models: {
    providers: {
      lan: {
        baseUrl: "http://10.0.0.20:8000/v1",
        api: "openai-completions",
        // SecretRef: read from this environment variable at runtime.
        // Delete this line if your endpoint needs no key.
        apiKey: { source: "env", provider: "default", id: "LLM_KEY" },
        models: [ { id: "your-model-id", name: "your-model-id" } ]
      }
    }
  },
  agents: { defaults: { model: { primary: "lan/your-model-id" } } }
}
'@
    Set-Content -Path $providerTemplate -Value $templateBody -Encoding ASCII
    Write-Ok "template written: $providerTemplate"
    Write-Host ''
    Write-Host 'Add your LAN model provider yourself:' -ForegroundColor Cyan
    Write-Host "  1. edit    $providerTemplate"
    Write-Host "  2. check   `"$openclawCmd`" config patch --file `"$providerTemplate`" --dry-run"
    Write-Host "  3. apply   `"$openclawCmd`" config patch --file `"$providerTemplate`""
    Write-Host '  4. set the env var named in the apiKey "id" before starting the Gateway,'
    Write-Host '     or delete that line if your endpoint needs no key.'
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  CLI         : $openclawCmd"
Write-Host "  Config      : $env:USERPROFILE\.openclaw\openclaw.json"
Write-Host "  Gateway log : $env:USERPROFILE\.openclaw\logs"
Write-Host "  Docs        : $docsDir"
Write-Host "  Docs (pkg)  : $appDir\node_modules\openclaw\docs"
Write-Host "  Control UI  : http://127.0.0.1:$GatewayPort     (or run: openclaw dashboard)"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Open the Control UI above in a browser. This bundle installs no desktop app.'
Write-Host '  2. To pair another client, use the gateway URL/token or the setup code printed above.'
Write-Host '  3. If you enable node mode on a client, approve it on this host:'
Write-Host '       openclaw devices list ; openclaw devices approve <id>'
Write-Host '       openclaw nodes pending ; openclaw nodes approve <id>'
Write-Host '  4. To upgrade later, bring a NEW bundle and double-click upgrade.cmd there.'
Write-Host '     Do not re-run this installer with -Force to upgrade: that wipes the tree'
Write-Host '     (rescue mode) and cannot roll back a migrated state database.'
