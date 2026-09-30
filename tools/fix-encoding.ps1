#Requires -Version 5.1
<#
.SYNOPSIS
    Ensure every .ps1 file is UTF-8 WITH BOM.

.DESCRIPTION
    Windows PowerShell 5.1 reads .ps1 files using the system ANSI code page
    (GBK on a Chinese Windows). A UTF-8 file WITHOUT a BOM is therefore
    mis-decoded: Chinese text turns into garbage and, worse, a mangled
    multi-byte sequence can swallow a following quote and cause a parser
    error such as:

        The string is missing the terminator: ".

    Adding a UTF-8 BOM makes PowerShell decode the file as UTF-8, which is
    what we want. This script is idempotent and safe to re-run.

    Its own text is English-only on purpose: it must be runnable even
    before the BOM has been added to itself.

.PARAMETER Path
    Root directory to scan. Defaults to the repository root.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$fixed = 0
$already = 0

$files = Get-ChildItem -Path $Path -Filter '*.ps1' -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\\.state\\|\\logs\\|\\downloads\\' }

foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    if ($hasBom) {
        $already++
        continue
    }

    # Read as UTF-8 (without BOM) and rewrite with BOM.
    $text = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom)
    [System.IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
    Write-Host ("  + BOM added: {0}" -f $file.FullName.Substring($Path.Length + 1)) -ForegroundColor Yellow
    $fixed++
}

Write-Host ''
Write-Host ("Done. added={0} already-ok={1} total={2}" -f $fixed, $already, $files.Count) -ForegroundColor Green
exit 0
