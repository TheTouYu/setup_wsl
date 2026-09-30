#Requires -Version 5.1
<#
.SYNOPSIS
    静态检查：用 PowerShell 自己的解析器检查所有 .ps1 的语法。
.DESCRIPTION
    比任何正则检查都可靠 —— 直接调用 PSParser，
    能抓出 PS 5.1 不支持的语法（??、三元、-Encoding utf8NoBOM 等）
    以及嵌套引号之类的低级错误。
    这是本项目最容易踩的坑：开发机上没有 PS7，
    却写了 PS7 语法，直到运行时才炸。
.EXITCODE
    0  全部通过
    1  存在语法错误
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

Write-Host '检查 PowerShell 脚本语法 ...' -ForegroundColor Cyan

$files = Get-ChildItem -Path $root -Filter '*.ps1' -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\\.state\\|\\logs\\|\\downloads\\' }

$failed = 0

# ---------------------------------------------------------------- BOM 检查
# 中文 Windows 上 PowerShell 5.1 按 GBK 解码无 BOM 的 .ps1，
# 中文会乱码并可能吞掉引号导致解析失败。含中文的 .ps1 必须带 UTF-8 BOM。
Write-Host '检查 UTF-8 BOM ...' -ForegroundColor Cyan
$noBom = 0
foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $rel = $file.FullName.Substring($root.Length + 1)
    if ($hasBom) {
        Write-Host ("  ✓ {0}" -f $rel) -ForegroundColor Green
    } else {
        Write-Host ("  ✗ {0}  缺少 UTF-8 BOM（修复：tools\fix-encoding.ps1）" -f $rel) -ForegroundColor Red
        $noBom++
    }
}
if ($noBom -gt 0) { $failed += $noBom }
Write-Host ''

# ---------------------------------------------------------------- 语法检查
Write-Host '检查 PowerShell 脚本语法 ...' -ForegroundColor Cyan
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    $rel = $file.FullName.Substring($root.Length + 1)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host ("  ✗ {0}" -f $rel) -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("      第 {0} 行：{1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
        $failed++
    } else {
        Write-Host ("  ✓ {0}" -f $rel) -ForegroundColor Green
    }
}

Write-Host ''

# ---------------------------------------------------------------- .cmd 纯 ASCII 检查
# cmd.exe 按 OEM 代码页（中文系统是 GBK）解析 .bat/.cmd，且不认识 UTF-8 BOM，
# 因此批处理文件里任何非 ASCII 字节都会破坏命令解析。
# 所有面向用户的中文输出都放在 .ps1 里，由 PowerShell 负责。
Write-Host '检查 .cmd 是否纯 ASCII ...' -ForegroundColor Cyan
$cmdFiles = Get-ChildItem -Path $root -Include '*.cmd', '*.bat' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.state\\|\\logs\\|\\downloads\\' }
$badCmd = 0
foreach ($file in $cmdFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    $rel = $file.FullName.Substring($root.Length + 1)
    if ($nonAscii.Count -eq 0) {
        Write-Host ("  ✓ {0}" -f $rel) -ForegroundColor Green
    } else {
        Write-Host ("  ✗ {0}  含 {1} 个非 ASCII 字节（cmd.exe 会解析出错）" -f $rel, $nonAscii.Count) -ForegroundColor Red
        $badCmd++
    }
}
if ($badCmd -gt 0) { $failed += $badCmd }
Write-Host ''

if ($failed -gt 0) {
    Write-Host ("语法检查失败：{0} 个文件有错误" -f $failed) -ForegroundColor Red
    exit 1
}
Write-Host ("语法检查通过：{0} 个文件" -f $files.Count) -ForegroundColor Green
exit 0
