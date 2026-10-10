<#
.SYNOPSIS
    Pre-flight checks for the dsh-web-offline scripts. Run this before shipping a bundle.

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
      4. the cross-file contract still holds: the manifest schema version, the
         package name, the Node floor, the default port, the install-script list
         and the win32-x64 native package list must AGREE between the build-side
         and target-side scripts. A drift here installs a broken tree on an
         air-gapped host months later, which is the expensive failure this
         catches.
      5. the .cmd entry points reference the scripts that exist, and the docs the
         bundle is supposed to carry are present next to the scripts.

    Exit code 0 = all checks passed; 1 = at least one failure.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent folder of this script.

.EXAMPLE
    .\Test-DshWebOfflineScripts.ps1
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
function Read-Source([string]$Name) { return (Get-Content -Path (Join-Path $PSScriptRoot $Name) -Raw) }
function Assert-Match([string]$Name, [string]$Pattern, [string]$Label) {
    $source = Read-Source $Name
    if ($source -match $Pattern) { Pass "$Label ($Name)" } else { Fail "$Label - expected /$Pattern/ in $Name" }
}

$bundleDir = $PSScriptRoot
$ps1Files = @(Get-ChildItem -Path $bundleDir -Filter '*.ps1' -File | Sort-Object Name)
$cmdFiles = @(Get-ChildItem -Path $bundleDir -Filter '*.cmd' -File | Sort-Object Name)
$deliverables = @($ps1Files + $cmdFiles)

# Tokens that do not exist on Windows PowerShell 5.1. The patterns are matched
# against the raw source; keep them specific to avoid false positives - note the
# trailing \b: a local variable such as $isWindowsHost is NOT the PowerShell 6.0+
# automatic variable $IsWindows, and a bare '\$IsWindows' pattern would flag it.
$ps7Only = @(
    @{ Name = 'null-coalescing ??';        Pattern = '\?\?' },
    @{ Name = 'null-conditional ?.';       Pattern = '\?\.' },
    @{ Name = 'type construction ::new(';  Pattern = '::new\(' },
    @{ Name = 'ConvertFrom-Json -AsHashtable'; Pattern = '-AsHashtable' },
    @{ Name = 'utf8NoBOM encoding';        Pattern = 'utf8NoBOM' },
    @{ Name = 'Test-Json';                 Pattern = '\bTest-Json\b' },
    @{ Name = 'Get-Error';                 Pattern = '\bGet-Error\b' },
    @{ Name = 'Get-Uptime';                Pattern = '\bGet-Uptime\b' },
    @{ Name = '$IsWindows';                Pattern = '\$\{?IsWindows\}?\b' },
    @{ Name = '$IsLinux';                  Pattern = '\$\{?IsLinux\}?\b' },
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
    # The token scan reads raw text, so it must ignore comment lines (the
    # compatibility comments legitimately name these constructs) and the
    # checker's own pattern table.
    $tokenScanExcluded = @('Test-DshWebOfflineScripts.ps1')
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
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Fail "$($file.Name) starts with a UTF-8 BOM (cmd.exe and PS 5.1 misread it)"
    }
    $crlf = 0
    for ($i = 1; $i -lt $bytes.Count; $i++) { if ($bytes[$i] -eq 10 -and $bytes[$i - 1] -eq 13) { $crlf++ } }
    $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
    if ($lf -ne $crlf) { Fail "$($file.Name) has $($lf - $crlf) LF-only line ending(s); Windows deliverables must be CRLF" }
    if ($nonAscii.Count -eq 0 -and $lf -eq $crlf) { Pass "$($file.Name) is ASCII + CRLF ($lf lines)" }
}

Section 'Cross-file contract'
# The make/install/upgrade/test scripts are standalone copies of the same
# constants on purpose (they are shipped separately), so the agreement has to be
# verified rather than assumed.
Assert-Match 'Make-DshWebOfflineBundle.ps1' '\$BundleSchemaVersion\s*=\s*1\b' 'make declares manifest schemaVersion 1'
Assert-Match 'Install-DshWebOffline.ps1' 'schemaVersion \$manifestSchema \(this installer understands 1\)|\[int\]\$manifestSchema -ne 1' 'install accepts manifest schemaVersion 1'
Assert-Match 'Make-DshWebOfflineBundle.ps1' "\`$DshPackage\s*=\s*'@deepseek-ai/dsh'" 'make pins the npm package name'
Assert-Match 'Install-DshWebOffline.ps1' "'@deepseek-ai/dsh'" 'install knows the npm package name'
Assert-Match 'Make-DshWebOfflineBundle.ps1' "\`$NodeFloor\s*=\s*'22\.19\.0'" 'make records the Node floor'
Assert-Match 'Install-DshWebOffline.ps1' "\`$NodeFloor = '22\.19\.0'|\`$NodeFloor -eq '22\.19\.0'" 'install falls back to the same Node floor'
Assert-Match 'Make-DshWebOfflineBundle.ps1' '\$DefaultWebPort\s*=\s*3080' 'make records the default web port'
Assert-Match 'Install-DshWebOffline.ps1' '\[int\]\$WebPort\s*=\s*3080' 'install defaults to the same web port'
Assert-Match 'Install-DshWebOffline.ps1' '--dump-config' 'install composes the profile offline before booting'
Assert-Match 'Install-DshWebOffline.ps1' 'start-web\.cmd' 'install writes the start script'
Assert-Match 'Install-DshWebOffline.ps1' 'stop-web\.cmd' 'install writes the stop script'
Assert-Match 'Install-DshWebOffline.ps1' 'current\.txt' 'install switches versions through current.txt'
Assert-Match 'Install-DshWebOffline.ps1' 'DshWeb' 'install registers the DshWeb logon task'

# Every package the installer must allow scripts for, and every win32-x64
# native package it verifies, has to be declared by the make script too.
foreach ($pkg in @('koffi', 'node-pty', 'protobufjs', '@deepseek-ai/dsh-subprocess-local')) {
    Assert-Match 'Make-DshWebOfflineBundle.ps1' ([regex]::Escape("'$pkg'")) "make lists install-script package $pkg"
}
foreach ($native in @('@koromix/koffi-win32-x64', '@img/sharp-win32-x64', '@vscode/ripgrep-win32-x64',
                      'sherpa-onnx-win-x64', '@deepseek-ai/libreoffice-kit-win32-x64',
                      'node-addon-require-builtin-win32-x64-msvc')) {
    Assert-Match 'Make-DshWebOfflineBundle.ps1' ([regex]::Escape("'$native'")) "make lists native package $native"
}
# sherpa's win32 package is deliberately NOT named sherpa-onnx-win32-x64; a
# plausible-looking wrong name would silently skip the check.
Assert-Match 'Make-DshWebOfflineBundle.ps1' 'sherpa-onnx-win-x64' 'make uses the real sherpa win-x64 package name'

Section 'Entry points and carried files'
Assert-Match 'install.cmd' 'Install-DshWebOffline\.ps1' 'install.cmd calls the installer'
Assert-Match 'install.cmd' 'nvm' 'install.cmd explains how to fix a missing node'
Assert-Match 'upgrade.cmd' 'Upgrade-DshWebOffline\.ps1' 'upgrade.cmd calls the upgrade script'
Assert-Match 'Make-DshWebOfflineBundle.ps1' 'UPGRADE-BRIEF\.md' 'make carries UPGRADE-BRIEF.md into the bundle'
Assert-Match 'Make-DshWebOfflineBundle.ps1' 'Install-DshWebOffline\.ps1' 'make carries the installer into the bundle'

foreach ($required in @('Install-DshWebOffline.ps1', 'Upgrade-DshWebOffline.ps1', 'install.cmd', 'upgrade.cmd',
                        'Make-DshWebOfflineBundle.ps1', 'UPGRADE.md', 'UPGRADE-BRIEF.md')) {
    if (Test-Path (Join-Path $bundleDir $required)) { Pass "$required present" } else { Fail "$required is missing from $bundleDir" }
}
foreach ($doc in @('OFFLINE-CAPABILITIES.md', 'LLM-ENDPOINT.md', 'WEB-SURFACE.md')) {
    $docPath = Join-Path (Join-Path $bundleDir 'docs') $doc
    if (Test-Path $docPath) { Pass "docs\$doc present" } else { Fail "docs\$doc is missing - the air-gapped host has no other source for it" }
}

# The repo README is the delivery spec; the component must stay registered there.
Section 'Repository registration'
$readmePath = Join-Path $RepoRoot 'README.md'
if (-not (Test-Path $readmePath)) {
    Fail "README.md not found at $readmePath (pass -RepoRoot)"
} else {
    $readme = Get-Content -Path $readmePath -Raw
    if ($readme -match 'dsh-web-offline') { Pass 'README.md registers the dsh-web-offline package' }
    else { Fail "README.md does not mention dsh-web-offline - add it to the package table" }
    # Anchors into the openclaw package are owned by Test-OpenClawOfflineScripts.ps1;
    # this checker only insists that none of them point at this package.
    if ($readme -match '\[[^\]]*\]\(dsh-web-offline/[^)]*#L\d+') {
        Fail 'README.md uses #L anchors into dsh-web-offline; this checker does not verify those, so cite the files without line anchors'
    }
}

Section 'Result'
if ($failures.Count -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "$($failures.Count) check(s) failed:" -ForegroundColor Red
foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
exit 1
