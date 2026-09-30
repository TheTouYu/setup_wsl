#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 40 —— 把镜像导入为 WSL 发行版，数据落在指定盘。
.DESCRIPTION
    用 `wsl --import` 而不是 `wsl --install -d`，原因有二：
      1) 安装位置完全可控（--install 默认落在 C 盘用户目录）
      2) 不依赖在线发行版列表（该列表源站在国内常常不可达）
    已注册则跳过，不重复导入。
.EXITCODE
    0   发行版就绪
    30  镜像不存在，需要先跑阶段 30
    1   导入失败
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '40-import-distro' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 40：导入发行版'

$distro = $config['DISTRO_NAME']
$distroDir = Resolve-SetupDistroDir -Config $config
$fileName = if ($config['IMAGE_VERSION'] -eq 'latest') { 'archlinux.wsl' } else { "archlinux-$($config['IMAGE_VERSION']).wsl" }
$image = Join-Path (Join-Path $root 'downloads') $fileName

Write-SetupLog -Message "发行版名：$distro"
Write-SetupLog -Message "安装位置：$distroDir"

# ---------------------------------------------------------------- 已安装？
if (Test-WslDistroInstalled -Distro $distro) {
    Write-SetupOk "发行版 '$distro' 已注册，跳过导入"
    $vhd = Join-Path $distroDir 'ext4.vhdx'
    if (Test-Path -LiteralPath $vhd) {
        $sizeMB = [math]::Round((Get-Item -LiteralPath $vhd).Length / 1MB, 1)
        Write-SetupLog -Message "系统盘：$vhd（$sizeMB MB）"
    }
    Set-SetupStageState -RepoRoot $root -Stage '40-import-distro' -Status 'ok' -Note 'already-imported'
    exit $global:SW_OK
}

if (-not (Test-Path -LiteralPath $image)) {
    Write-SetupFail "找不到镜像文件：$image"
    Write-SetupFail '请先执行阶段 30（bootstrap.ps1 -Only 30）。'
    Set-SetupStageState -RepoRoot $root -Stage '40-import-distro' -Status 'failed' -Note 'image-missing'
    exit $global:SW_NEED_INPUT
}

if (-not (Test-Path -LiteralPath $distroDir)) {
    New-Item -ItemType Directory -Force -Path $distroDir | Out-Null
    Write-SetupLog -Message "已创建安装目录：$distroDir"
}

Write-SetupLog -Message '导入中（解压镜像并创建 ext4.vhdx，通常几十秒）...'
$sw = [Diagnostics.Stopwatch]::StartNew()
$result = Invoke-WslCli -Arguments @('--import', $distro, $distroDir, $image, '--version', '2')
$sw.Stop()

if ($result.ExitCode -ne 0) {
    Write-SetupFail "导入失败（退出码 $($result.ExitCode)）"
    if ($result.Output) { Write-SetupFail $result.Output }
    Set-SetupStageState -RepoRoot $root -Stage '40-import-distro' -Status 'failed' -Note "exit=$($result.ExitCode)"
    exit $global:SW_ERROR
}

Write-SetupOk ("导入完成，用时 {0} 秒" -f [math]::Round($sw.Elapsed.TotalSeconds, 1))

if (-not (Test-WslDistroInstalled -Distro $distro)) {
    Write-SetupFail '导入命令返回成功，但发行版未出现在列表中。'
    Set-SetupStageState -RepoRoot $root -Stage '40-import-distro' -Status 'failed' -Note 'not-registered'
    exit $global:SW_ERROR
}

$vhdPath = Join-Path $distroDir 'ext4.vhdx'
if (Test-Path -LiteralPath $vhdPath) {
    $sizeMB = [math]::Round((Get-Item -LiteralPath $vhdPath).Length / 1MB, 1)
    Write-SetupOk "系统盘：$vhdPath（$sizeMB MB，动态增长）"
} else {
    Write-SetupWarn "未在预期位置找到 ext4.vhdx：$vhdPath"
}

Set-SetupStageState -RepoRoot $root -Stage '40-import-distro' -Status 'ok' -Note $distroDir
exit $global:SW_OK
