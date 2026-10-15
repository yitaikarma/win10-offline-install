<#
.SYNOPSIS
    Verify an openclaw offline bundle: before shipping it, and again after the USB trip.

.DESCRIPTION
    Read-only. Everything the BUILD.md checklist asks for, in one command, so nothing has to
    be pasted line by line:

      1. bundle-manifest.json exists, parses, and carries the expected schemaVersion
      2. mode / targetPlatform / openClawVersion are the ones this bundle must have
      3. schemaVersions is present (the upgrade script needs it for the migration warning)
      4. packagedTarball exists and its SHA256 matches tarballSha256
      5. app mode     : appFileCount / appBytes match the app\ tree on disk
         npmcache mode: the npm cache is populated and app\ is absent (mode stays honest)
      6. nativePackages are recorded, and in app mode each one is present under app\
      7. docs\docs_map.md exists, with a markdown page count
      8. the bundle is self-contained (installer, upgrade script, both .cmd, both docs)
      9. smoke test (app mode on win32-x64 only): the staged CLI runs and reports the
         manifest version, koffi loads, and native binaries are present

    Exit code 0 = every check passed; 1 = at least one failure.

    Run it on the build machine after Make-OpenClawOfflineBundle.ps1, and again on the
    air-gapped host right after Unblock-File: the second run proves the copy survived the
    trip before anything is installed.

.PARAMETER BundleDir
    Optional override. With no argument the script verifies the folder it sits in when that
    folder holds bundle-manifest.json (the carried copy inside a bundle), otherwise
    <script folder>\openclaw-offline-bundle (the copy in the component folder).

.PARAMETER SkipSmoke
    Skip check 9 (it starts the staged CLI, which may create a state directory on this host).

.EXAMPLE
    .\Verify-OpenClawBundle.ps1
    .\Verify-OpenClawBundle.ps1 -BundleDir ..\openclaw-offline-bundle
#>
[CmdletBinding()]
param(
    [string]$BundleDir,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Contract with Make/Install/Upgrade (asserted by Test-OpenClawOfflineScripts.ps1).
$OpenClawPackage     = 'openclaw'
$BundleSchemaVersion = 4
$TargetPlatform      = 'win32-x64'

$failures = New-Object System.Collections.Generic.List[string]
function Pass([string]$Message) { Write-Host "  OK    $Message" -ForegroundColor Green }
function Fail([string]$Message) { $script:failures.Add($Message) | Out-Null; Write-Host "  FAIL  $Message" -ForegroundColor Red }
function Note([string]$Message) { Write-Host "  note  $Message" -ForegroundColor Yellow }
function Section([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
# Running a native command that writes to stderr while $ErrorActionPreference is 'Stop' makes
# Windows PowerShell raise a terminating NativeCommandError (even with a 2>&1 redirect), which
# would kill this checker mid-run. Relax it for the duration and trust the exit code instead -
# the same rule the build/install scripts follow.
function Invoke-NativeCapture([string]$Command, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = ''
    $code = -1
    try {
        $text = (& $Command @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Text = $text; ExitCode = $code }
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Resolve this script's own directory WITHOUT trusting $PSScriptRoot: on some Windows
# PowerShell hosts it binds as an empty string, and Split-Path/Join-Path then refuse it.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $myCommand = $MyInvocation.MyCommand
    if ($myCommand -and $myCommand.PSObject.Properties['Path'] -and $myCommand.Path) {
        $scriptDir = Split-Path -Parent $myCommand.Path
    }
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $BundleDir) {
    if (Test-Path (Join-Path $scriptDir 'bundle-manifest.json')) {
        # Carried copy: running from inside the bundle.
        $BundleDir = $scriptDir
    } elseif (Test-Path (Join-Path (Join-Path $scriptDir 'openclaw-offline-bundle') 'bundle-manifest.json')) {
        # Component copy: the bundle built next to these scripts.
        $BundleDir = Join-Path $scriptDir 'openclaw-offline-bundle'
        Write-Host "No manifest next to this script - verifying $BundleDir"
    } else {
        Write-Host "No bundle found: expected bundle-manifest.json in" -ForegroundColor Red
        Write-Host "  $scriptDir" -ForegroundColor Red
        Write-Host "  $(Join-Path $scriptDir 'openclaw-offline-bundle')" -ForegroundColor Red
        Write-Host 'Build one first (see BUILD.md), or pass -BundleDir <folder>.' -ForegroundColor Red
        exit 1
    }
}
$BundleDir = [System.IO.Path]::GetFullPath($BundleDir)

Write-Host "Verifying bundle: $BundleDir"

# ---------------------------------------------------------------- manifest
Section 'Manifest'
$manifestPath = Join-Path $BundleDir 'bundle-manifest.json'
if (-not (Test-Path $manifestPath)) {
    Fail "bundle-manifest.json is missing (<bundle> is not a bundle)"
    Write-Host "`n1 check(s) failed:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

$schemaVersion = Get-Prop $manifest 'schemaVersion'
if ($null -eq $schemaVersion) { Fail 'manifest has no schemaVersion' }
elseif ([int]$schemaVersion -ne $BundleSchemaVersion) { Fail "manifest schemaVersion is $schemaVersion, this checker expects $BundleSchemaVersion" }
else { Pass "schemaVersion $schemaVersion" }

$mode = "$(Get-Prop $manifest 'mode')"
if ($mode -ne 'app' -and $mode -ne 'npmcache') { Fail "manifest mode is '$mode' (expected app or npmcache)" }
else { Pass "mode $mode" }

$targetPlatform = "$(Get-Prop $manifest 'targetPlatform')"
if ($targetPlatform -ne $TargetPlatform) { Fail "manifest targetPlatform is '$targetPlatform' (expected $TargetPlatform)" }
else { Pass "targetPlatform $targetPlatform" }

$version = "$(Get-Prop $manifest 'openClawVersion')"
if (-not $version) { Fail 'manifest has no openClawVersion' }
else { Pass "$OpenClawPackage $version" }

$schemaVersions = Get-Prop $manifest 'schemaVersions'
if ($null -eq $schemaVersions) {
    Fail 'manifest.schemaVersions is missing - the upgrade script cannot warn that the schema migration is one-way (rebuild so the staged package.json is read)'
} else {
    Pass "schemaVersions state=$(Get-Prop $schemaVersions 'state') agent=$(Get-Prop $schemaVersions 'agent')"
}

$nativePackages = @(Get-Prop $manifest 'nativePackages')
$nativePackages = @($nativePackages | Where-Object { $_ })
if ($nativePackages.Count -eq 0) { Fail "manifest records no $TargetPlatform native package" }
else { Pass "nativePackages ($($nativePackages.Count)): $($nativePackages -join ', ')" }

$scriptPkgs = @(Get-Prop $manifest 'installScriptPackages')
$scriptPkgs = @($scriptPkgs | Where-Object { $_ })
if ($scriptPkgs.Count -eq 0) { Note 'manifest records no installScriptPackages (informational only)' }
else { Pass "installScriptPackages: $($scriptPkgs -join ', ')" }

# ---------------------------------------------------------------- tarball
Section 'Release tarball (the upgrade target)'
$tarballName = "$(Get-Prop $manifest 'packagedTarball')"
$tarballHash = "$(Get-Prop $manifest 'tarballSha256')"
if (-not $tarballName) { Fail 'manifest has no packagedTarball' }
else {
    $tarballPath = Join-Path $BundleDir $tarballName
    if (-not (Test-Path $tarballPath)) { Fail "packaged tarball $tarballName is missing" }
    else {
        $actual = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
        $sizeMb = [math]::Round((Get-Item $tarballPath).Length / 1MB, 1)
        if (-not $tarballHash) { Fail "manifest has no tarballSha256 - cannot verify $tarballName" }
        elseif ($actual -ne $tarballHash) { Fail "tarball SHA256 mismatch: manifest $tarballHash, file $actual (copy is damaged - get it again)" }
        else { Pass "$tarballName $sizeMb MB, SHA256 matches" }
    }
}

# ---------------------------------------------------------------- payload
$appDir = Join-Path $BundleDir 'app'
$cacheDir = Join-Path $BundleDir 'npm-cache'

if ($mode -eq 'app') {
    Section 'App tree'
    if (-not (Test-Path $appDir)) { Fail 'mode is app but app\ is missing' }
    else {
        $files = @(Get-ChildItem -Path $appDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        $bytes = 0
        foreach ($f in $files) { $bytes += $f.Length }
        $expectedCount = Get-Prop $manifest 'appFileCount'
        $expectedBytes = Get-Prop $manifest 'appBytes'
        if ($null -eq $expectedCount -or $null -eq $expectedBytes) { Fail 'manifest has no appFileCount/appBytes to compare against' }
        else {
            if ($files.Count -ne [int]$expectedCount) { Fail "app tree file count mismatch: expected $expectedCount, found $($files.Count)" }
            elseif ([long]$bytes -ne [long]$expectedBytes) { Fail "app tree byte mismatch: expected $expectedBytes, found $bytes" }
            else { Pass "app tree matches the manifest: $($files.Count) files / $([math]::Round($bytes / 1MB, 1)) MB" }
        }

        $missingNative = New-Object System.Collections.Generic.List[string]
        foreach ($pkg in $nativePackages) {
            $relative = $pkg -replace '/', '\'
            $direct = Join-Path (Join-Path $appDir 'node_modules') $relative
            if (Test-Path $direct) { continue }
            $leaf = Split-Path $pkg -Leaf
            $nested = @(Get-ChildItem -Path $appDir -Recurse -Directory -Filter $leaf -ErrorAction SilentlyContinue |
                        Where-Object { (($_.FullName -replace '\\', '/').EndsWith("/$pkg")) })
            if ($nested.Count -eq 0) { $missingNative.Add("$pkg") }
        }
        if ($missingNative.Count -gt 0) { Fail "native package(s) missing under app\: $($missingNative -join ', ')" }
        else { Pass 'every recorded native package is present' }
    }
} elseif ($mode -eq 'npmcache') {
    Section 'npm cache (the payload)'
    $cacache = Join-Path $cacheDir '_cacache'
    if (-not (Test-Path $cacache)) { Fail 'mode is npmcache but npm-cache\_cacache is missing' }
    else {
        $cacheFiles = @(Get-ChildItem -Path $cacheDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        $cacheBytes = 0
        foreach ($f in $cacheFiles) { $cacheBytes += $f.Length }
        if ($cacheFiles.Count -lt 10) { Fail "npm cache looks empty ($($cacheFiles.Count) files)" }
        else { Pass "npm cache: $($cacheFiles.Count) files / $([math]::Round($cacheBytes / 1MB, 1)) MB" }
    }
    if (Test-Path $appDir) {
        Note 'app\ also exists (mode app bundles may carry both): the installer prefers the manifest mode'
    } else {
        Pass 'app\ absent, consistent with mode npmcache'
    }
}

# ---------------------------------------------------------------- docs + self-containment
Section 'Documentation and entry points'
$docsMap = Join-Path (Join-Path $BundleDir 'docs') 'docs_map.md'
if (-not (Test-Path $docsMap)) { Fail 'docs\docs_map.md is missing (offline documentation)' }
else {
    $mdCount = @(Get-ChildItem -Path (Join-Path $BundleDir 'docs') -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
    Pass "docs: $mdCount markdown page(s), docs_map.md present"
}

foreach ($name in @('Install-OpenClawOffline.ps1', 'Upgrade-OpenClawOffline.ps1', 'install.cmd',
                    'upgrade.cmd', 'UPGRADE.md', 'UPGRADE-BRIEF.md')) {
    if (Test-Path (Join-Path $BundleDir $name)) { Pass "$name present" } else { Fail "$name missing (the bundle must be self-contained)" }
}
if (Test-Path (Join-Path $BundleDir 'Verify-OpenClawBundle.ps1')) {
    Pass 'Verify-OpenClawBundle.ps1 present (the target can verify the copy with no arguments)'
} else {
    Note 'this bundle predates Verify-OpenClawBundle.ps1 so it is not carried. Install and upgrade do not need it, but the air-gapped host then cannot verify the USB copy itself - copy this script into the bundle folder, or rebuild, to enable that.'
}

# ---------------------------------------------------------------- smoke test
Section 'Smoke test'
$isWinX64 = ($env:OS -eq 'Windows_NT') -and [Environment]::Is64BitOperatingSystem
if ($SkipSmoke) {
    Note '-SkipSmoke: staged CLI not started'
} elseif ($mode -ne 'app') {
    Note 'mode npmcache: there is no staged tree to run (the target installs it)'
} elseif (-not $isWinX64) {
    Note "this host is not Windows x64, so the staged tree cannot be executed here"
} else {
    $launcher = Join-Path $appDir 'openclaw.cmd'
    if (-not (Test-Path $launcher)) { Fail 'app\openclaw.cmd is missing' }
    else {
        $cliRun = Invoke-NativeCapture -Command $launcher -Arguments @('--version')
        if ($cliRun.ExitCode -ne 0) { Fail "app\openclaw.cmd --version exited $($cliRun.ExitCode): $($cliRun.Text)" }
        elseif ($cliRun.Text -notmatch [regex]::Escape($version)) { Fail "app\openclaw.cmd --version reported '$($cliRun.Text)' instead of $version" }
        else { Pass "staged CLI runs: $($cliRun.Text)" }
    }

    $nodeCmd = Get-Command 'node' -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { Fail 'node is not on PATH - the air-gapped host needs the supported Node version' }
    else {
        # koffi is a dependency OF openclaw, and npm 11 nests those under the package, so the
        # probe has to run from a directory that can see openclaw's own node_modules.
        $probeDirs = @((Join-Path (Join-Path $appDir 'node_modules') 'openclaw'), $appDir)
        $loaded = $null
        $notFound = $null
        $loadFailed = $null
        foreach ($probeDir in $probeDirs) {
            if (-not (Test-Path $probeDir)) { continue }
            Push-Location $probeDir
            try {
                $probe = Invoke-NativeCapture -Command 'node' -Arguments @('-e', "require('koffi'); console.log('koffi ok')")
            } finally {
                Pop-Location
            }
            if ($probe.ExitCode -eq 0) { $loaded = $probe; break }
            # Keep the informative outcome: "not resolvable here" is only a note, but "found and
            # refused to load" is the real ABI/PE failure this check exists for. A later probe
            # directory must not mask it (that is exactly how a broken module hides).
            if ($probe.Text -match 'Cannot find module') { if (-not $notFound) { $notFound = $probe } }
            elseif (-not $loadFailed) { $loadFailed = $probe }
        }
        if ($loaded) { Pass "native module loads: $($loaded.Text)" }
        elseif ($loadFailed) { Fail "require('koffi') failed - the native module cannot run on this Node: $(($loadFailed.Text -split "`n" | Select-Object -First 1))" }
        elseif ($notFound) { Note "koffi is not resolvable from app\node_modules nor from the package folder (nested layout?) - the native-package and *.node checks above cover presence" }
        else { Fail 'could not probe koffi: no app\node_modules\openclaw directory' }
    }

    $binaries = @(Get-ChildItem -Path (Join-Path $appDir 'node_modules') -Recurse -Include '*.node', '*.dll' -File -ErrorAction SilentlyContinue)
    if ($binaries.Count -eq 0) { Fail 'no *.node / *.dll under app\node_modules - the install scripts probably did not run' }
    else { Pass "$($binaries.Count) native binary file(s) present" }
}

# ---------------------------------------------------------------- result
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'Bundle verified: safe to copy to USB (app mode) or to install.' -ForegroundColor Green
    exit 0
}
Write-Host "$($failures.Count) check(s) failed - DO NOT ship or install this bundle:" -ForegroundColor Red
foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
exit 1
