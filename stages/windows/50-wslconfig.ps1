#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 50 —— 配置 %USERPROFILE%\.wslconfig（交换文件位置等）。
.DESCRIPTION
    把 WSL2 的交换文件从 C 盘挪到安装盘，避免系统盘被悄悄吃掉。
    用段级合并写入，不动用户已有的其它设置；改动前留备份。
.EXITCODE
    0   已配置 / 已是最新
    1   失败
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '50-wslconfig' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 50：配置 .wslconfig'

if (-not (Test-SetupSwitch $config['CONFIGURE_SWAP'])) {
    Write-SetupLog -Message 'CONFIGURE_SWAP=no，跳过'
    Set-SetupStageState -RepoRoot $root -Stage '50-wslconfig' -Status 'skipped' -Note 'disabled'
    exit $global:SW_OK
}

$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$installRoot = ConvertTo-SetupWinPath $config['INSTALL_ROOT']
$swapFile = Join-Path $installRoot 'swap.vhdx'

Write-SetupLog -Message "配置文件：$wslConfig"
Write-SetupLog -Message "交换文件：$swapFile"

if (-not (Test-Path -LiteralPath $installRoot)) {
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    Write-SetupLog -Message "已创建目录：$installRoot"
}

# 备份（带时间戳，不覆盖历史备份）
if (Test-Path -LiteralPath $wslConfig) {
    $backup = "$wslConfig.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $wslConfig -Destination $backup -Force
    Write-SetupLog -Message "已备份原文件：$backup"
}

# ⚠ 必须写成双反斜杠。
# WSL 的 INI 解析器会处理转义序列：写成 D:\WSL\swap.vhdx 时，
# 非法的转义序列（\W、\s）会把路径吃掉，WSL 取不到合法路径就
# 静默回退到默认位置（%LOCALAPPDATA%\Temp\<GUID>\swap.vhdx），
# 交换文件于是重新落回 C 盘 —— 而且不会报任何错。
# 这一点在真机上验证过：单反斜杠 → 文件出现在 C 盘 Temp；
# 双反斜杠 → 文件正确出现在 D 盘。
$swapFileIni = $swapFile.Replace('\', '\\')
Set-IniValue -Path $wslConfig -Section 'wsl2' -Key 'swapFile' -Value $swapFileIni
Write-SetupLog -Message "写入值（注意双反斜杠是必须的）：$swapFileIni"

$swapSize = $config['SWAP_SIZE']
if (-not [string]::IsNullOrWhiteSpace($swapSize)) {
    Set-IniValue -Path $wslConfig -Section 'wsl2' -Key 'swap' -Value $swapSize
    Write-SetupLog -Message "交换文件大小上限：$swapSize"
}

Write-SetupOk '已写入 .wslconfig'
Write-SetupLog -Message '当前内容：'
foreach ($line in [System.IO.File]::ReadAllLines($wslConfig, [System.Text.Encoding]::UTF8)) {
    Write-SetupLog -Message "    $line"
}
Write-SetupLog -Message '（改动将在下次 WSL 虚拟机关闭后生效：wsl --shutdown）'

Set-SetupStageState -RepoRoot $root -Stage '50-wslconfig' -Status 'ok' -Note $swapFile
exit $global:SW_OK
