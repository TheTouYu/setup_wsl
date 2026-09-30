#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 20 —— 确保 WSL 本体可用。
.DESCRIPTION
    先看 wsl --version 能否工作；不行才动手装。
    优先走 Microsoft Store 通道（微软 CDN，国内可达性好）；
    Store 不可用时提示 --web-download 备选。
.EXITCODE
    0   已就绪
    20  需要管理员权限
    10  需要重启
    1   失败
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '20-install-wsl' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 20：确保 WSL 本体已就绪'

if (Test-WslReady) {
    $ver = Invoke-WslCli -Arguments @('--version')
    foreach ($line in ($ver.Output -split "`n")) {
        $t = $line.Trim()
        if ($t) { Write-SetupLog -Message "  $t" }
    }
    Write-SetupOk 'WSL 已就绪，跳过安装'
    Set-SetupStageState -RepoRoot $root -Stage '20-install-wsl' -Status 'ok' -Note 'already-ready'
    exit $global:SW_OK
}

Assert-SetupAdmin -Reason '安装 WSL 本体需要管理员权限'
Write-SetupLog -Message 'WSL 本体尚未安装，开始安装（--no-distribution：只装 WSL，不装任何发行版）'

$out = & wsl.exe --install --no-distribution 2>&1
$code = $LASTEXITCODE
foreach ($line in $out) {
    $t = "$line".Trim()
    if ($t) { Write-SetupLog -Message "  $t" }
}

if ($code -ne 0) {
    Write-SetupWarn "wsl --install 返回 $code"
    Write-SetupWarn '可尝试的备选通道（任选其一，均需管理员）：'
    Write-SetupWarn '  1) wsl.exe --install --no-distribution --web-download   # 从 GitHub 下载'
    Write-SetupWarn '  2) 打开 Microsoft Store 搜索 "Windows Subsystem for Linux" 手动安装'
    Set-SetupStageState -RepoRoot $root -Stage '20-install-wsl' -Status 'failed' -Note "exit=$code"
    exit $global:SW_ERROR
}

Start-Sleep -Seconds 2
if (Test-WslReady) {
    $ver = Invoke-WslCli -Arguments @('--version')
    Write-SetupOk ('安装完成：' + (($ver.Output -split "`n")[0]).Trim())
    Set-SetupStageState -RepoRoot $root -Stage '20-install-wsl' -Status 'ok' -Note 'installed'
    exit $global:SW_OK
}

Write-SetupWarn '安装命令已执行，但 WSL 仍未就绪 —— 通常需要重启后生效。'
Set-SetupStageState -RepoRoot $root -Stage '20-install-wsl' -Status 'reboot-required' -Note 'verify-after-reboot'
exit $global:SW_REBOOT
