<#
.SYNOPSIS
    Pre-flight checks for the offline-bundle scripts. Run this before shipping a bundle.

.DESCRIPTION
    Read-only. Runs on the build machine (Windows PowerShell 5.1) or anywhere a
    PowerShell is available; it installs nothing and touches no system state.

    Checks:
      1. every .ps1 parses cleanly (PowerShell parser)
      2. Windows PowerShell 5.1 surface only:
         - Join-Path must never get three or more positional arguments
           (-AdditionalChildPath exists only in PowerShell 6.0+ and a 5.1 host
           fails with "A positional parameter cannot be found")
         - no PS 6/7-only syntax or cmdlets
      3. deliverables are ASCII (the target console is read in the OEM code page)
         and use CRLF line endings (LF-only .cmd files are a known cmd.exe risk)
      4. every README #L anchor matches its own label, its content contract and stays
         inside the file
      5. the cross-file contract still holds: the manifest schema version, the npm
         package name, the Node window, the gateway port, the bundle's carry list and
         the .cmd wiring must agree across Make/Install/Upgrade/Test. Silent drift here
         is what breaks an air-gapped install months later.

    Exit code 0 = all checks passed; 1 = at least one failure.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent folder of this script.

.EXAMPLE
    .\Test-OpenClawOfflineScripts.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$Message) { $script:failures.Add($Message) | Out-Null; Write-Host "    FAIL  $Message" -ForegroundColor Red }
function Pass([string]$Message) { Write-Host "    ok    $Message" -ForegroundColor Green }
function Section([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

# Cross-file contract helper: assert that a deliverable still contains a pattern.
function Assert-Match([string]$Name, [string]$Pattern, [string]$Label) {
    $path = Join-Path $bundleDir $Name
    if (-not (Test-Path $path)) { Fail "$Label - missing file $Name"; return }
    $text = Get-Content -Path $path -Raw
    if ($text -notmatch $Pattern) { Fail "$Label - $Name does not match /$Pattern/" } else { Pass $Label }
}

$bundleDir = $PSScriptRoot
$ps1Files = @(Get-ChildItem -Path $bundleDir -Filter '*.ps1' -File | Sort-Object Name)
$cmdFiles = @(Get-ChildItem -Path $bundleDir -Filter '*.cmd' -File | Sort-Object Name)
$deliverables = @($ps1Files + $cmdFiles)

# Tokens that do not exist on Windows PowerShell 5.1. The patterns are matched against
# the raw source; keep them specific to avoid false positives.
$ps7Only = @(
    @{ Name = 'null-coalescing ??';        Pattern = '\?\?' },
    @{ Name = 'null-conditional ?.';       Pattern = '\?\.' },
    @{ Name = 'type construction ::new(';  Pattern = '::new\(' },
    @{ Name = 'ConvertFrom-Json -AsHashtable'; Pattern = '-AsHashtable' },
    @{ Name = 'utf8NoBOM encoding';        Pattern = 'utf8NoBOM' },
    @{ Name = 'Test-Json';                 Pattern = '\bTest-Json\b' },
    @{ Name = 'Get-Error';                 Pattern = '\bGet-Error\b' },
    @{ Name = 'Get-Uptime';                Pattern = '\bGet-Uptime\b' },
    @{ Name = '$IsWindows';                Pattern = '\$IsWindows' },
    @{ Name = '$IsLinux';                  Pattern = '\$IsLinux' },
    @{ Name = 'ForEach-Object -Parallel';  Pattern = '-Parallel\b' },
    @{ Name = 'Join-String';               Pattern = '\bJoin-String\b' },
    @{ Name = 'Get-Content -AsByteStream'; Pattern = '-AsByteStream' },
    @{ Name = 'Invoke-RestMethod -SkipHttpErrorCheck'; Pattern = '-SkipHttpErrorCheck' },
    @{ Name = 'Get-ChildItem -FollowSymlink'; Pattern = '-FollowSymlink' }
)

Section 'Parsing and PowerShell 5.1 checks'
foreach ($file in $ps1Files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Fail "$($file.Name):$($e.Extent.StartLineNumber) parse error: $($e.Message)" }
        continue
    }
    Pass "$($file.Name) parses ($($tokens.Count) tokens)"

    # Join-Path positional arity, checked on the AST rather than by text.
    $joinCalls = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Join-Path' }, $true)
    foreach ($call in $joinCalls) {
        $elements = @($call.CommandElements)
        $values = 0
        $valueParams = 0
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $text = "$($elements[$i].Extent.Text)"
            if ($text.StartsWith('-')) {
                if ($text -in @('-Path', '-ChildPath', '-AdditionalChildPath')) { $valueParams++ }
                if ($text -eq '-AdditionalChildPath') { Fail "$($file.Name):$($call.Extent.StartLineNumber) Join-Path -AdditionalChildPath is PowerShell 6.0+" }
            } else {
                $values++
            }
        }
        $positional = $values - $valueParams
        if ($positional -gt 2) {
            Fail "$($file.Name):$($call.Extent.StartLineNumber) Join-Path called with $positional positional arguments (max 2 on PowerShell 5.1) - nest the calls"
        }
    }

    $source = Get-Content -Path $file.FullName -Raw
    # The token scan reads raw text, so it must ignore comment lines (the compatibility
    # comments legitimately name these constructs) and the checker's own pattern table.
    $tokenScanExcluded = @('Test-OpenClawOfflineScripts.ps1')
    $line = 0
    foreach ($rawLine in ($source -split "`r?`n")) {
        $line++
        if ($rawLine.TrimStart().StartsWith('#')) { continue }
        if ($tokenScanExcluded -contains $file.Name) { continue }
        foreach ($check in $ps7Only) {
            if ($rawLine -match $check.Pattern) { Fail "$($file.Name):$line uses $($check.Name)" }
        }
    }
}

Section 'Encoding and line endings'
foreach ($file in $deliverables) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    if ($nonAscii.Count -gt 0) { Fail "$($file.Name) is not pure ASCII ($($nonAscii.Count) byte(s) > 127)" }
    $crlf = 0
    for ($i = 1; $i -lt $bytes.Count; $i++) { if ($bytes[$i] -eq 10 -and $bytes[$i - 1] -eq 13) { $crlf++ } }
    $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
    if ($lf -ne $crlf) { Fail "$($file.Name) has $($lf - $crlf) LF-only line ending(s); Windows deliverables must be CRLF" }
    if ($nonAscii.Count -eq 0 -and $lf -eq $crlf) { Pass "$($file.Name) is ASCII + CRLF ($lf lines)" }
}

# Anchor content contract: label -> a distinctive marker that must appear inside the
# referenced line range. A label that still resolves but points at the wrong lines is
# the failure this catches. When a script grows or shrinks, recompute the README anchors
# and update this table in the same change.
$anchorExpectations = @{
    'Install:176-177' = 'PROCESSOR_ARCHITEW6432'
    'Make:283-285'    = 'OSArchitecture'
    'Install:532'     = 'Installing the Gateway service'
    'Install:443-457' = 'CheckEndpoint'
    'Install:211-226' = 'Checking the Node runtime'
    'Install:286'     = 'needAllow'
    'Make:20-22'      = 'build on Windows x64'
    'Make:738'        = 'Unblock-File'
    'Install:158-172' = 'Get-Prop \$manifest'
}

# ---------------------------------------------------------------- cross-file contract
Section 'Cross-file contract'

foreach ($name in @('Make-OpenClawOfflineBundle.ps1', 'Install-OpenClawOffline.ps1',
                    'Upgrade-OpenClawOffline.ps1', 'install.cmd', 'upgrade.cmd',
                    'UPGRADE.md', 'UPGRADE-BRIEF.md')) {
    if (Test-Path (Join-Path $bundleDir $name)) { Pass "$name present" } else { Fail "$name present" }
}

# Manifest schema: one declared value, written by make, understood by install/upgrade.
Assert-Match 'Make-OpenClawOfflineBundle.ps1' '\$BundleSchemaVersion\s*=\s*4\b' 'make declares manifest schemaVersion 4'
Assert-Match 'Make-OpenClawOfflineBundle.ps1' 'schemaVersion\s*=\s*\$BundleSchemaVersion' 'make writes the declared schemaVersion'
Assert-Match 'Install-OpenClawOffline.ps1' '\$BundleSchemaVersion\s*=\s*4\b' 'install understands manifest schemaVersion 4'
Assert-Match 'Install-OpenClawOffline.ps1' '\[int\]\$manifestSchema -gt \$BundleSchemaVersion' 'install refuses a newer manifest'
Assert-Match 'Upgrade-OpenClawOffline.ps1' '\$BundleSchemaVersion\s*=\s*4\b' 'upgrade understands manifest schemaVersion 4'
Assert-Match 'Upgrade-OpenClawOffline.ps1' '\[int\]\$manifestSchema -gt \$BundleSchemaVersion' 'upgrade refuses a newer manifest'

# npm package name.
foreach ($f in @('Make-OpenClawOfflineBundle.ps1', 'Install-OpenClawOffline.ps1', 'Upgrade-OpenClawOffline.ps1')) {
    Assert-Match $f "\`$OpenClawPackage\s*=\s*'openclaw'" "$f pins the npm package name"
}

# Node window (openclaw's engines field).
foreach ($f in @('Make-OpenClawOfflineBundle.ps1', 'Install-OpenClawOffline.ps1')) {
    Assert-Match $f "\`$NodeFloor\s*=\s*'24\.16\.0'" "$f records the Node floor"
    Assert-Match $f "\`$NodeCeiling\s*=\s*'25\.0\.0'" "$f records the Node ceiling"
    Assert-Match $f "\`$NodeAltFloor\s*=\s*'26\.1\.0'" "$f records the second Node floor"
}

# Gateway port.
Assert-Match 'Make-OpenClawOfflineBundle.ps1' '\$DefaultGatewayPort\s*=\s*18789' 'make records the default gateway port'
Assert-Match 'Install-OpenClawOffline.ps1' '\[int\]\$GatewayPort\s*=\s*18789' 'install defaults to the same gateway port'
Assert-Match 'Upgrade-OpenClawOffline.ps1' '\[int\]\$GatewayPort\s*=\s*18789' 'upgrade defaults to the same gateway port'

# The bundle must be self-contained: open it and double-click the entry points.
foreach ($n in @('Install-OpenClawOffline.ps1', 'Upgrade-OpenClawOffline.ps1', 'install.cmd', 'upgrade.cmd')) {
    Assert-Match 'Make-OpenClawOfflineBundle.ps1' ([regex]::Escape("'$n'")) "make carries $n into the bundle"
}

# A .cmd must call the script it ships with.
Assert-Match 'install.cmd' 'Install-OpenClawOffline\.ps1' 'install.cmd calls the installer'
Assert-Match 'upgrade.cmd' 'Upgrade-OpenClawOffline\.ps1' 'upgrade.cmd calls the upgrade script'

# Cross-platform cache warming: platform pinned, install scripts left to the target.
Assert-Match 'Make-OpenClawOfflineBundle.ps1' '\$TargetPlatform\s*=\s*.win32-x64.' 'make records the target platform'
Assert-Match 'Make-OpenClawOfflineBundle.ps1' '--ignore-scripts' 'make skips install scripts while cross-warming'
Assert-Match 'Make-OpenClawOfflineBundle.ps1' "'--os', 'win32', '--cpu', 'x64'" 'make pins the platform when warming'
Assert-Match 'Install-OpenClawOffline.ps1' "-eq 'win32-x64'" 'install pins the platform when installing'
Assert-Match 'Make-OpenClawOfflineBundle.ps1' 'installScriptPackages' 'make records the install-script package list'
Assert-Match 'Install-OpenClawOffline.ps1' 'installScriptPackages' 'install uses the recorded install-script list'

# Native platform packages: recorded by make, asserted by install.
Assert-Match 'Make-OpenClawOfflineBundle.ps1' 'nativePackages' 'make records the native package list'
Assert-Match 'Install-OpenClawOffline.ps1' 'nativePackages' 'install verifies the native package list'

# ---------------------------------------------------------------- README anchors
Section 'README line anchors'
$readmePath = Join-Path $RepoRoot 'README.md'
if (-not (Test-Path $readmePath)) {
    Fail "README.md not found at $readmePath (pass -RepoRoot)"
} else {
    $readme = Get-Content -Path $readmePath -Raw
    $pattern = '\[(?<label>[^\]]+)\]\((?<path>[^)#]+)#L(?<start>\d+)(?:-L(?<end>\d+))?\)'
    $found = 0
    foreach ($m in [regex]::Matches($readme, $pattern)) {
        $found++
        $target = Join-Path $RepoRoot $m.Groups['path'].Value
        $label = $m.Groups['label'].Value
        $start = [int]$m.Groups['start'].Value
        $end = if ($m.Groups['end'].Success) { [int]$m.Groups['end'].Value } else { $start }
        if (-not (Test-Path $target)) { Fail "README anchor '$label' points at a missing file: $($m.Groups['path'].Value)"; continue }
        $short = [System.IO.Path]::GetFileNameWithoutExtension($target)
        $short = $short -replace '^Install-OpenClawOffline$', 'Install' -replace '^Make-OpenClawOfflineBundle$', 'Make'
        $expected = if ($end -ne $start) { "$short`:$start-$end" } else { "$short`:$start" }
        if ($label -ne $expected) { Fail "README anchor label '$label' does not match its target '$expected'" }
        $lines = @(Get-Content -Path $target)
        if ($end -gt $lines.Count) { Fail "README anchor '$label' points past the end of $($m.Groups['path'].Value) ($($lines.Count) lines)"; continue }
        if (-not $anchorExpectations.ContainsKey($label)) {
            Fail "README anchor '$label' has no content expectation in this checker - add one, or the anchor can silently drift onto other lines"
        } else {
            $range = ($lines[($start - 1)..($end - 1)]) -join "`n"
            if ($range -notmatch $anchorExpectations[$label]) {
                Fail "README anchor '$label' no longer points at '$($anchorExpectations[$label])' - recompute the anchor"
            }
        }
    }
    if ($found -eq 0) { Fail 'No #L anchors found in README.md - the anchor check verified nothing.' }
    else { Pass "$found README anchor(s) checked (label + content)" }
}

Section 'Result'
if ($failures.Count -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "$($failures.Count) check(s) failed:" -ForegroundColor Red
foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
exit 1
