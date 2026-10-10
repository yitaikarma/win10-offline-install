<#
.SYNOPSIS
    Upgrade an existing OpenClaw installation from an offline bundle.

.DESCRIPTION
    RUN THIS ON THE AIR-GAPPED WINDOWS 10 x64 HOST, as the user who owns the Gateway
    (not as SYSTEM). No outbound network access is performed.

    This drives the OFFICIAL updater with the release artifact the bundle carries:

        openclaw update --tag <bundle>\openclaw-<version>.tgz

    OpenClaw documents an explicit artifact (a tarball path) as a valid update target,
    but it has no offline mode: the package tarball does not contain its transitive
    dependencies. The bundle therefore also carries a warm npm cache and this script
    points npm at it with npm_config_cache + npm_config_offline. OpenClaw's own
    documentation for this path lives in the bundle's UPGRADE.md / UPGRADE-BRIEF.md.

    Order of operations (official mechanisms wherever they exist):

        verify bundle -> locate installed CLI -> schema-migration warning ->
        backup (openclaw backup create --verify) -> stop the Gateway, wait for exit ->
        dry-run preflight (owner check + cache-backed dependency resolution) ->
        apply update -> gateway install --force -> gateway restart -> verify -> report

    ROLLBACK IS BACKUP-ONLY. Upgrading migrates the state database forward (2026.9.5
    declares state 17, 2026.9.9 declares state 19). An older build then refuses to open
    that database, so reinstalling the old package does NOT roll back. Restore the
    pre-upgrade archive instead: openclaw backup restore <archive> --target <empty dir>.

    The 2026.9.5 Gateway has no installation-replacement watcher, so the first upgrade
    must stop the Gateway and let it exit before the package is replaced.

    -RescueTree is a FALLBACK for the case where the official updater refuses (for
    example an owner/prefix mismatch): it robocopies the bundle's prebuilt app tree over
    the installed one and reinstalls the service. It is a reinstall, not a rollback.

.PARAMETER BundleDir
    Folder produced by Make-OpenClawOfflineBundle.ps1. Defaults to this script's folder.

.PARAMETER InstallRoot
    Existing installation root. Default: C:\OpenClaw

.PARAMETER BackupDir
    Directory that receives the pre-upgrade backup archive. Must exist (this script
    creates it) and must NOT be inside the OpenClaw state directory.
    Default: C:\Backups\openclaw

.PARAMETER GatewayPort
    Gateway port used when reinstalling the service. Default: 18789

.PARAMETER SkipBackup
    Do not take the pre-upgrade backup. NOT recommended: the backup is the only way back.

.PARAMETER DryRun
    Verify the bundle, compare versions, and ask the updater for its plan - WITHOUT
    changing anything. No backup archive is written, the Gateway keeps serving, and no
    package is touched. Run this first on a production host.

.PARAMETER RescueTree
    Skip the official updater and replace the app tree from the bundle instead.

.PARAMETER Force
    Continue past the non-fatal guards (same version, downgrade target).

.EXAMPLE
    .\Upgrade-OpenClawOffline.ps1 -DryRun
    Zero side effects: verify the bundle, compare versions, print the updater plan.

.EXAMPLE
    .\Upgrade-OpenClawOffline.ps1
    Full upgrade using the official updater.
#>
[CmdletBinding()]
param(
    [string]$BundleDir = '',
    [string]$InstallRoot = 'C:\OpenClaw',
    [string]$BackupDir = 'C:\Backups\openclaw',
    [int]$GatewayPort = 18789,
    [switch]$SkipBackup,
    [switch]$DryRun,
    [switch]$RescueTree,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 compatibility (the target host shell): Join-Path has no
# -AdditionalChildPath there - that parameter is PowerShell 6.0+ - so it must NEVER be
# called with more than two positional arguments. Nest the calls instead:
#   Join-Path (Join-Path $root 'sub') $leaf
# Everything else stays inside the 5.1 surface on purpose (no ??, ?:, -AsHashtable,
# Get-Error or $IsWindows).

# ---------------------------------------------------------------- contract
# Shared contract with Make-*/Install-*/Test-*. Test-OpenClawOfflineScripts.ps1 asserts
# the files still agree; silent drift here is what breaks an air-gapped upgrade.
$OpenClawPackage     = 'openclaw'
$BundleSchemaVersion = 4

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    !!  $Text" -ForegroundColor Yellow }

# StrictMode turns a missing property into a TERMINATING error; read every optional
# manifest field through this.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# A native command that writes to stderr raises NativeCommandError, which becomes a
# terminating error under $ErrorActionPreference = 'Stop' - even with 2>&1 (PS 5.1).
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

# Map the updater's documented failure signatures to an actionable hint.
function Get-FailureHint([string[]]$Lines) {
    $text = ($Lines -join "`n")
    if ($text -match 'foreign-destination|foreign destination|package-manager owner|no detected .*owner') {
        return 'The updater does not recognise this installation as its own (npm global prefix mismatch). Re-run with -RescueTree, or align npm: set NPM_CONFIG_PREFIX to the install tree and retry.'
    }
    if ($text -match 'ENOTCACHED') {
        return 'A dependency is missing from the bundled npm cache. Rebuild the bundle so its npm-cache covers this version, then retry. Do NOT point npm at another registry - changing the registry changes the cache keys.'
    }
    if ($text -match 'node-runtime-preflight') {
        return 'The target release cannot run on the Node on PATH. Keep Node inside >=24.16 <25 or >=26.1 (nvm use) and retry.'
    }
    if ($text -match 'newer schema version|schema version') {
        return 'The on-disk database is newer than this build supports. Restore the pre-upgrade backup.'
    }
    if ($text -match 'EPERM|EBUSY|EACCES') {
        return 'A file was still locked. Make sure the Gateway is fully stopped (no node process under the install root) and retry.'
    }
    return $null
}

function Get-InstalledVersion([string]$Launcher) {
    $run = Invoke-Native -Command $Launcher -Arguments @('--version')
    $text = ($run.Lines -join ' ').Trim()
    if ($text -match '(\d{4}\.\d+\.\d+)') { return [pscustomobject]@{ Raw = $text; Version = [version]$Matches[1] } }
    if ($text -match '(\d+\.\d+\.\d+)')   { return [pscustomobject]@{ Raw = $text; Version = [version]$Matches[1] } }
    return [pscustomobject]@{ Raw = $text; Version = $null }
}

# ---------------------------------------------------------------- verify bundle
Write-Step 'Verifying the upgrade bundle'

if (-not $BundleDir) {
    if ($PSScriptRoot) { $BundleDir = $PSScriptRoot } else { $BundleDir = (Get-Location).Path }
}
$BundleDir = [System.IO.Path]::GetFullPath($BundleDir)
$manifestPath = Join-Path $BundleDir 'bundle-manifest.json'
if (-not (Test-Path $manifestPath)) { throw "bundle-manifest.json not found in $BundleDir" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Refuse a bundle this upgrader does not understand instead of half-upgrading it.
$manifestSchema = Get-Prop $manifest 'schemaVersion'
if ($null -ne $manifestSchema) {
    if ([int]$manifestSchema -gt $BundleSchemaVersion) {
        throw "Unsupported manifest schemaVersion $manifestSchema (this upgrader understands $BundleSchemaVersion). Use the upgrade script from that bundle."
    }
    if ([int]$manifestSchema -lt 4) {
        Write-Note "Bundle schemaVersion $manifestSchema predates the upgrade fields (4): no packagedTarball/SHA256. Only -RescueTree is likely to work."
    }
} else {
    Write-Note 'The manifest has no schemaVersion; treating it as a legacy bundle.'
}

$targetVersion  = Get-Prop $manifest 'openClawVersion'
$tarballLeaf    = Get-Prop $manifest 'packagedTarball'
$tarballSha256  = Get-Prop $manifest 'tarballSha256'
$targetSchema   = Get-Prop $manifest 'schemaVersions'
if (-not $targetVersion) { throw 'The bundle manifest has no openClawVersion; rebuild the bundle.' }

$tarballPath = $null
if ($tarballLeaf) {
    $downloadStage = Join-Path $BundleDir '_download'
    $tarballPath = @(
        (Join-Path $BundleDir $tarballLeaf),
        (Join-Path $downloadStage $tarballLeaf)
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if ($tarballPath) {
    $actual = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
    if ($tarballSha256 -and $actual -ne $tarballSha256) {
        throw "Upgrade artifact hash mismatch (media corruption?). expected=$tarballSha256 actual=$actual"
    }
    Write-Ok "artifact: $tarballPath ($([math]::Round((Get-Item $tarballPath).Length/1MB,1)) MB)"
    # npm 12 rejects local .tgz installs whose archive name or parent path contains a comma.
    if ("$BundleDir$tarballLeaf" -match ',') {
        throw 'The bundle path or tarball name contains a comma. npm 12 rejects local .tgz installs in that case - move the bundle to a comma-free path.'
    }
} elseif (-not $RescueTree) {
    throw "No upgrade artifact found in $BundleDir (manifest field packagedTarball='$tarballLeaf'). Use -RescueTree to install from the bundle's app tree instead."
}
Write-Ok "target: openclaw $targetVersion"

$appStage = Join-Path $BundleDir 'app'
$cacheStage = Join-Path $BundleDir 'npm-cache'
Write-Ok "mode: $(if ($RescueTree) { 'rescue app-tree replacement' } else { 'official updater + local artifact' })"

# ---------------------------------------------------------------- installed CLI
Write-Step "Locating the installed OpenClaw in $InstallRoot"

$appDir = Join-Path $InstallRoot 'app'
$launcher = $null
if (Test-Path $appDir) {
    $launcher = Get-ChildItem -Path $appDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq 'openclaw' -and $_.Extension -in '.cmd', '.ps1', '.exe' } |
                Select-Object -First 1
}
if (-not $launcher) { throw "No openclaw launcher found under $appDir. Is the installation in $InstallRoot?" }
$openclawCmd = $launcher.FullName

$current = Get-InstalledVersion $openclawCmd
if (-not $current.Version) { throw "Could not read the installed version ($($current.Raw)) from $openclawCmd" }
Write-Ok "installed: $($current.Raw)"

$isSameVersion = ("$($current.Version)" -eq "$targetVersion")
$isDowngrade = $false
if ("$targetVersion" -match '^\d+\.\d+\.\d+$') {
    $isDowngrade = ([version]$targetVersion -lt $current.Version)
} else {
    Write-Note "Target '$targetVersion' is not a plain x.y.z version; skipping the downgrade comparison."
}
if ($isSameVersion -and -not $Force) {
    Write-Note "The installed version already matches $targetVersion. The updater still validates an explicit artifact, but re-run with -Force if this is intentional."
}
if ($isDowngrade -and -not $Force) {
    throw "Downgrade refused: installed $($current.Version) is newer than bundle $targetVersion. Re-run with -Force only if you have a matching pre-upgrade backup (the state database may already be migrated)."
}

# ---------------------------------------------------------------- schema warning
$installedPkgJson = Join-Path $appDir 'node_modules\openclaw\package.json'
$installedSchema = $null
if (Test-Path $installedPkgJson) {
    $installedMeta = Get-Prop ((Get-Content $installedPkgJson -Raw | ConvertFrom-Json)) 'openclaw'
    $installedSchema = Get-Prop $installedMeta 'schemaVersions'
}
$schemaOld = "$(Get-Prop $installedSchema 'state')/$(Get-Prop $installedSchema 'agent')"
$schemaNew = "$(Get-Prop $targetSchema 'state')/$(Get-Prop $targetSchema 'agent')"
Write-Ok "declared schema (state/agent): installed $schemaOld -> target $schemaNew"
if ($installedSchema -and $targetSchema -and $schemaOld -ne $schemaNew) {
    Write-Note 'This upgrade crosses a database schema migration. It is ONE-WAY: the older build will refuse the migrated state, so rollback means restoring the pre-upgrade backup below - not reinstalling the old package.'
}

# ---------------------------------------------------------------- dry run (no side effects)
# -DryRun must NOT touch the machine: no backup archive, no service stop, no package
# change. It verifies the bundle and asks the updater for its plan while the Gateway
# keeps serving. Only the real run below backs up and stops anything.
if ($DryRun) {
    Write-Step 'Dry-run: verifying the bundle and the updater plan (nothing is changed)'
    if ($RescueTree) {
        Write-Note 'Rescue mode replaces the app tree; a dry-run cannot preview it. Nothing was changed.'
    } else {
        $savedPrefix = $env:NPM_CONFIG_PREFIX
        $savedCache = $env:npm_config_cache
        $savedOffline = $env:npm_config_offline
        $env:NPM_CONFIG_PREFIX = $appDir
        if (Test-Path $cacheStage) {
            $env:npm_config_cache = $cacheStage
            $env:npm_config_offline = 'true'
        }
        $planRun = Invoke-Native -Command $openclawCmd -Arguments @('update', '--dry-run', '--yes', '--no-restart', '--tag', $tarballPath) -Show
        $env:NPM_CONFIG_PREFIX = $savedPrefix
        $env:npm_config_cache = $savedCache
        $env:npm_config_offline = $savedOffline
        if ($planRun.ExitCode -ne 0) {
            $hint = Get-FailureHint $planRun.Lines
            if ($hint) { Write-Note $hint }
            throw "The update preflight failed (exit $($planRun.ExitCode)). Nothing was changed: no backup, no service stop, no package change."
        }
        Write-Ok 'preflight passed: the updater accepted the artifact and the install ownership'
    }
    Write-Host ''
    Write-Ok 'dry-run complete - nothing was backed up, stopped or changed'
    Write-Note 'Re-run without -DryRun to apply the update; that run backs up state and stops the Gateway first.'
    exit 0
}

# ---------------------------------------------------------------- backup
$archivePath = $null
if ($SkipBackup) {
    Write-Step 'Backup skipped (-SkipBackup)'
    Write-Note 'The state database migration is one-way. Without a backup there is no way back.'
} else {
    Write-Step "Backing up state to $BackupDir"
    $BackupDir = [System.IO.Path]::GetFullPath($BackupDir)
    $stateDir = Join-Path $env:USERPROFILE '.openclaw'
    if ($BackupDir.TrimEnd('\').StartsWith($stateDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write the backup inside the state directory ($stateDir): the CLI rejects output inside the source tree. Choose another -BackupDir."
    }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    # --output must point at an EXISTING directory, otherwise the path is treated as the
    # archive file itself (verified: it then writes a file with no extension).
    $backupRun = Invoke-Native -Command $openclawCmd -Arguments @('backup', 'create', '--output', $BackupDir, '--verify') -Show
    if ($backupRun.ExitCode -ne 0) { throw "openclaw backup create failed with exit code $($backupRun.ExitCode). Do not continue without a backup." }
    $archives = @(Get-ChildItem -Path $BackupDir -Filter '*-openclaw-backup.tar.gz' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($archives.Count -eq 0) { throw "No backup archive found in $BackupDir after a successful run; refusing to continue." }
    $archivePath = $archives[0].FullName
    Write-Ok "archive: $archivePath ($([math]::Round($archives[0].Length/1MB,2)) MB)"
    Write-Note 'Copy this archive off the machine (USB) before relying on it.'
}

# ---------------------------------------------------------------- stop the gateway
Write-Step 'Stopping the Gateway'

if ($current.Version -lt [version]'2026.9.6') {
    Write-Note "Installed $($current.Version) predates the installation-replacement watcher, so the Gateway must be stopped and fully exited before the package is replaced."
}
$stopRun = Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'stop') -Show
if ($stopRun.ExitCode -ne 0) {
    Write-Note 'gateway stop failed; retrying with --force'
    Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'stop', '--force') -Show | Out-Null
}

$deadline = (Get-Date).AddSeconds(90)
$leftover = @()
while ((Get-Date) -lt $deadline) {
    $leftover = @()
    foreach ($proc in @(Get-Process node -ErrorAction SilentlyContinue)) {
        $procPath = $null
        try { $procPath = $proc.Path } catch { $procPath = $null }
        if ($procPath -and $procPath.StartsWith($InstallRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { $leftover += $proc }
    }
    if ($leftover.Count -eq 0) { break }
    Start-Sleep -Seconds 3
}
if ($leftover.Count -gt 0) {
    Write-Note "Still running: $($leftover.Count) node process(es) under $InstallRoot -> $($leftover.Id -join ', ')"
    Write-Note 'Replacing package files while they are locked will fail. Stop them, then re-run this script.'
} else {
    Write-Ok 'no node process is left under the install root'
}

# ---------------------------------------------------------------- apply
$savedPrefix = $env:NPM_CONFIG_PREFIX
$savedCache  = $env:npm_config_cache
$savedOffline = $env:npm_config_offline

if ($RescueTree) {
    Write-Step 'Replacing the app tree from the bundle (rescue mode)'
    if (-not (Test-Path $appStage)) { throw "Bundle is incomplete: missing $appStage (required for -RescueTree)" }
    Write-Note 'Mirroring the bundle app tree over the installed one (/MIR removes files the new version does not ship).'
    # /MIR = /E + /PURGE: a reinstall must not leave files from the previous version behind.
    $argString = "`"$appStage`" `"$appDir`" /MIR /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP"
    $rc = (Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -Wait -PassThru -NoNewWindow).ExitCode
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc. The app tree may be incomplete - re-run, and use the bundle's app tree again." }
    Write-Ok 'app tree replaced (this is a reinstall, not a rollback)'
} else {
    # Owner alignment: the updater infers ownership from npm's global prefix plus the
    # installed launcher, and this tree was copied into place rather than npm-installed
    # at this prefix.
    $env:NPM_CONFIG_PREFIX = $appDir
    if (Test-Path $cacheStage) {
        $env:npm_config_cache = $cacheStage
        $env:npm_config_offline = 'true'
        Write-Ok "offline npm cache: $cacheStage"
    } else {
        Write-Note 'No npm-cache in the bundle; the updater may try to reach the registry for dependencies.'
    }

    Write-Step 'Preflight: openclaw update --dry-run'
    $dryRun = Invoke-Native -Command $openclawCmd -Arguments @('update', '--dry-run', '--yes', '--no-restart', '--tag', $tarballPath) -Show
    if ($dryRun.ExitCode -ne 0) {
        $hint = Get-FailureHint $dryRun.Lines
        # We stopped the Gateway above; put it back before bailing out.
        Write-Note 'Preflight failed. Restarting the Gateway so the machine keeps working.'
        Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'start') -Show | Out-Null
        if ($hint) { Write-Note $hint }
        throw "The update preflight failed (exit $($dryRun.ExitCode)). Nothing was changed."
    }
    Write-Ok 'preflight passed: the updater accepted the artifact and the install ownership'

    Write-Step "Applying: openclaw update --tag $tarballLeaf"
    $updateRun = Invoke-Native -Command $openclawCmd -Arguments @('update', '--yes', '--tag', $tarballPath) -Show
    if ($updateRun.ExitCode -ne 0) {
        $hint = Get-FailureHint $updateRun.Lines
        if ($hint) { Write-Note $hint }
        Write-Note 'If the updater reports a pending recovery, run: openclaw update repair --yes --json'
        Write-Note 'The Gateway may be left stopped: openclaw gateway start (or re-run with -RescueTree).'
        throw "openclaw update failed with exit code $($updateRun.ExitCode)."
    }
    Write-Ok 'update applied'
}

# restore the caller's npm environment
$env:NPM_CONFIG_PREFIX = $savedPrefix
$env:npm_config_cache = $savedCache
$env:npm_config_offline = $savedOffline

# ---------------------------------------------------------------- service + verify
Write-Step 'Reinstalling the Gateway service and verifying'
Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'install', '--force') -Show | Out-Null
Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'restart') -Show | Out-Null
Start-Sleep -Seconds 3

$after = Get-InstalledVersion $openclawCmd
Write-Host "    installed now: $($after.Raw)"
if ("$targetVersion" -and $after.Raw -notmatch [regex]::Escape("$targetVersion")) {
    Write-Note "The CLI does not report $targetVersion. Check the update output above before using this installation."
}

$postDoctor = Invoke-Native -Command $openclawCmd -Arguments @('doctor', '--post-upgrade') -Show
if ($postDoctor.ExitCode -ne 0) { Write-Note "doctor --post-upgrade exited $($postDoctor.ExitCode); review its output above (openclaw doctor --fix)." }
Invoke-Native -Command $openclawCmd -Arguments @('gateway', 'status', '--deep', '--json') -Show | Out-Null
Invoke-Native -Command $openclawCmd -Arguments @('doctor', '--lint', '--json') -Show | Out-Null

Write-Host ''
Write-Host 'Upgrade finished.' -ForegroundColor Green
Write-Host "  CLI          : $openclawCmd"
Write-Host "  Version      : $($current.Version) -> $($after.Version)"
if ($archivePath) { Write-Host "  Backup       : $archivePath" }
Write-Host "  Control UI   : http://127.0.0.1:$GatewayPort"
Write-Host ''
Write-Host 'If something is wrong:' -ForegroundColor Cyan
Write-Host "  1. openclaw update repair --yes --json        (pending recovery / post-update convergence)"
Write-Host "  2. openclaw doctor --fix                      (config / plugin repairs)"
if ($archivePath) {
    Write-Host "  3. openclaw backup restore `"$archivePath`" --target <empty dir>"
    Write-Host '     Restore never happens in place: stop the Gateway, point the state dir at the'
    Write-Host '     restored copy, run openclaw doctor, then start the Gateway again.'
} else {
    Write-Host '  3. No backup was taken this run - there is no rollback path.'
}
Write-Host '  4. Fallback if the updater refused: re-run this script with -RescueTree'
