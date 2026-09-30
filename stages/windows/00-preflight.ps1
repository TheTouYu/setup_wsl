#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 00 —— 环境体检（只读，不改动任何东西）。
.DESCRIPTION
    在动手之前把"能不能装"讲清楚：系统版本、权限、虚拟化、磁盘、网络。
    发现问题只报告，不擅自修改。
.EXITCODE
    0  体检通过
    1  存在硬性阻塞（版本过低 / 无虚拟化 / 空间不足）
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '00-preflight' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 00：环境体检'
Write-SetupLog -Message "仓库位置：$root"

$blockers = @()
$warnings = @()

# ---------------------------------------------------------------- 操作系统
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-SetupLog -Message ("系统：{0}（Build {1}）" -f $os.Caption, $build)

if ($build -lt 19041) {
    $blockers += "Windows 版本过低（Build $build）。WSL2 需要 Build 19041 及以上。"
} elseif ($build -lt 22000) {
    $warnings += "当前是 Windows 10（Build $build），WSL 的部分新特性（如 --location）不可用。"
} else {
    Write-SetupOk "Windows 11，满足全部要求"
}

# ---------------------------------------------------------------- 权限
$isAdmin = Test-SetupAdmin
Write-SetupLog -Message "当前会话管理员：$isAdmin"
if (-not $isAdmin) {
    $warnings += '当前不是管理员。阶段 10 / 20 需要用管理员身份重跑（bootstrap 会给出指引）。'
}

# ---------------------------------------------------------------- 虚拟化
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs = Get-CimInstance Win32_ComputerSystem
$vbs = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue

# 注意：HypervisorPresent=True 时 VirtualizationFirmwareEnabled 常报 False，
# 那是被上层 hypervisor 遮蔽所致，不代表 BIOS 里没开虚拟化。
$virtualizationOk = $false
if ($cs.HypervisorPresent) {
    $virtualizationOk = $true
    Write-SetupOk '虚拟化已启用（检测到 hypervisor 正在运行，通常来自 VBS/内存完整性）'
} elseif ($cpu.VirtualizationFirmwareEnabled) {
    $virtualizationOk = $true
    Write-SetupOk '虚拟化已启用（固件层）'
} else {
    $blockers += 'BIOS/UEFI 中未启用虚拟化（Intel VT-x / AMD-V）。请进 BIOS 打开后重试。'
}

if ($vbs -and $vbs.VirtualizationBasedSecurityStatus -eq 2) {
    Write-SetupLog -Message 'VBS（基于虚拟化的安全）正在运行 —— 与 WSL2 兼容，无需关闭'
}
Write-SetupLog -Message "CPU：$($cpu.Name)"

# ---------------------------------------------------------------- WSL 现状
$wslReady = Test-WslReady
if ($wslReady) {
    $ver = Invoke-WslCli -Arguments @('--version')
    $first = ($ver.Output -split "`n")[0]
    Write-SetupOk "WSL 已就绪：$($first.Trim())"
} else {
    Write-SetupWarn 'WSL 尚未安装（阶段 20 会处理）'
}

$features = Get-CimInstance Win32_OptionalFeature -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') }
foreach ($f in $features) {
    $state = switch ($f.InstallState) { 1 { '已启用' } 2 { '已禁用' } default { "未知($($f.InstallState))" } }
    Write-SetupLog -Message ("功能 {0}：{1}" -f $f.Name, $state)
}

# ---------------------------------------------------------------- 发行版
$distro = $config['DISTRO_NAME']
if (Test-WslDistroInstalled -Distro $distro) {
    Write-SetupOk "发行版 '$distro' 已注册（重复运行会走已安装分支）"
} else {
    Write-SetupLog -Message "发行版 '$distro' 尚未注册"
}

# ---------------------------------------------------------------- 磁盘
$distroDir = Resolve-SetupDistroDir -Config $config
$probePath = $distroDir
while (-not (Test-Path -LiteralPath (Split-Path -Parent $probePath)) -and (Split-Path -Parent $probePath) -ne $probePath) {
    $probePath = Split-Path -Parent $probePath
}
$freeGB = Get-SetupFreeSpaceGB -Path $probePath
Write-SetupLog -Message ("安装目录：{0}" -f $distroDir)
if ($freeGB -ge 0) {
    Write-SetupLog -Message ("所在盘剩余空间：{0} GB" -f $freeGB)
    if ($freeGB -lt 20) {
        $blockers += "安装盘剩余空间不足（${freeGB} GB）。初始安装至少需要约 10 GB，建议预留 30 GB 以上。"
    } elseif ($freeGB -lt 40) {
        $warnings += "安装盘剩余空间偏紧（${freeGB} GB），开发环境装完后占用会持续增长。"
    }
}

# ---------------------------------------------------------------- 网络
Write-SetupStep '镜像站连通性'
$mirror = $config['IMAGE_MIRROR']
$altMirror = $config['IMAGE_ALT_MIRROR']
foreach ($m in @($mirror, $altMirror)) {
    if ([string]::IsNullOrWhiteSpace($m)) { continue }
    $url = "$m/wsl/$($config['IMAGE_VERSION'])/archlinux.wsl.SHA256"
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
        $sw.Stop()
        Write-SetupOk ("{0}  可达（{1} ms）" -f $m, [int]$sw.ElapsedMilliseconds)
    } catch {
        $msg = "{0}  不可达：{1}" -f $m, $_.Exception.Message
        if ($m -eq $mirror) { $warnings += $msg } else { Write-SetupWarn $msg }
        Write-SetupWarn $msg
    }
}

# ---------------------------------------------------------------- 结论
Write-SetupStep '体检结论'
if ($warnings.Count -gt 0) {
    Write-SetupWarn '提醒事项：'
    foreach ($w in $warnings) { Write-SetupLog -Message "  · $w" -Level WARN }
}
if ($blockers.Count -gt 0) {
    Write-SetupFail '发现阻塞问题：'
    foreach ($b in $blockers) { Write-SetupLog -Message "  · $b" -Level ERROR }
    Set-SetupStageState -RepoRoot $root -Stage '00-preflight' -Status 'blocked' -Note ($blockers -join ' / ')
    exit $global:SW_ERROR
}

Write-SetupOk '体检通过，可以继续安装'
Set-SetupStageState -RepoRoot $root -Stage '00-preflight' -Status 'ok' -Note ("free=${freeGB}GB")
exit $global:SW_OK
