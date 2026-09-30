#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 10 —— 启用 WSL 所需的 Windows 功能。
.DESCRIPTION
    启用 Microsoft-Windows-Subsystem-Linux 与 VirtualMachinePlatform。
    两个功能都是幂等的：已启用就跳过。
    VirtualMachinePlatform 必须重启才生效，因此可能返回"需要重启"。
.EXITCODE
    0   已全部启用（无需重启）
    10  已启用，但必须重启后才有生效
    20  需要管理员权限
    1   失败
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '10-enable-features' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 10：启用 WSL 功能'
Assert-SetupAdmin -Reason '启用 Windows 可选功能需要管理员权限'

$required = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
$needEnable = @()

foreach ($name in $required) {
    $feature = Get-CimInstance Win32_OptionalFeature -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if (-not $feature) {
        Write-SetupWarn "系统里找不到功能 $name —— 可能是极精简的系统镜像"
        continue
    }
    if ($feature.InstallState -eq 1) {
        Write-SetupOk "$name 已启用"
    } else {
        Write-SetupLog -Message "$name 当前已禁用，准备启用"
        $needEnable += $name
    }
}

if ($needEnable.Count -eq 0) {
    Write-SetupOk '两个功能都已启用，无需改动'
    Set-SetupStageState -RepoRoot $root -Stage '10-enable-features' -Status 'ok' -Note 'already-enabled'
    exit $global:SW_OK
}

$rebootRequired = $false
foreach ($name in $needEnable) {
    Write-SetupLog -Message "启用 $name ..."
    # DISM 退出码：0 成功 / 3010 成功但需重启
    $out = & dism.exe /online /enable-feature /featurename:$name /all /norestart 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        $t = "$line".Trim()
        if ($t -and $t -notmatch '^\[=*\s*\d') { Write-SetupLog -Message "    $t" -Level DEBUG }
    }

    switch ($code) {
        0     { Write-SetupOk "$name 启用成功" }
        3010  { Write-SetupOk "$name 启用成功（需重启生效）"; $rebootRequired = $true }
        default {
            Write-SetupFail "$name 启用失败，DISM 退出码 $code"
            Set-SetupStageState -RepoRoot $root -Stage '10-enable-features' -Status 'failed' -Note "dism=$code"
            exit $global:SW_ERROR
        }
    }
}

if ($rebootRequired) {
    Write-SetupStep '需要重启'
    Write-SetupWarn 'VirtualMachinePlatform 必须重启后才生效。'
    Write-SetupWarn '请重启电脑，然后重新运行 bootstrap.ps1 —— 已完成的阶段会自动跳过。'
    Set-SetupStageState -RepoRoot $root -Stage '10-enable-features' -Status 'reboot-required' -Note 'VM Platform'
    exit $global:SW_REBOOT
}

Set-SetupStageState -RepoRoot $root -Stage '10-enable-features' -Status 'ok' -Note ($needEnable -join ',')
exit $global:SW_OK
