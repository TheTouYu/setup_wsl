#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 90 —— 端到端验证。
.DESCRIPTION
    分别报告 Windows 侧与 Linux 侧的真实状态：
    存储落点、交换文件、快捷方式、开发环境、国内源是否真的能拉到包。
    只读，不修改任何东西。结论分「通过 / 提醒」两级。
.EXITCODE
    0   通过
    1   有硬失败项
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '90-verify' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 90：端到端验证'

$distro = $config['DISTRO_NAME']
$distroDir = Resolve-SetupDistroDir -Config $config
$hardFailures = @()
$notes = @()

# ---------------------------------------------------------------- 1. WSL 本体
if (Test-WslReady) {
    $ver = Invoke-WslCli -Arguments @('--version')
    $wslVer = (($ver.Output -split "`n") | Where-Object { $_ -match 'WSL' } | Select-Object -First 1)
    Write-SetupOk "WSL：$($wslVer.Trim())"
} else {
    $hardFailures += 'WSL 本体不可用'
    Write-SetupFail 'WSL 本体不可用'
}

# ---------------------------------------------------------------- 2. 发行版注册
if (Test-WslDistroInstalled -Distro $distro) {
    Write-SetupOk "发行版已注册：$distro"
} else {
    $hardFailures += "发行版 $distro 未注册"
    Write-SetupFail "发行版 $distro 未注册"
}

# ---------------------------------------------------------------- 3. 存储落点
$vhd = Join-Path $distroDir 'ext4.vhdx'
if (Test-Path -LiteralPath $vhd) {
    $sizeGB = [math]::Round((Get-Item -LiteralPath $vhd).Length / 1GB, 2)
    Write-SetupOk "系统盘位于目标盘：$vhd（$sizeGB GB）"
    $driveLetter = (Split-Path -Qualifier $vhd).TrimEnd(':')
    $systemDrive = ($env:SystemDrive).TrimEnd(':')
    if ($driveLetter -ieq $systemDrive) {
        $notes += '发行版数据仍在系统盘上，如有需要可迁移到其它盘'
    }
} else {
    $hardFailures += "找不到系统盘文件：$vhd"
    Write-SetupFail "找不到系统盘文件：$vhd"
}

# ---------------------------------------------------------------- 4. 交换文件
# 语义说明：这里验证的是"配置指向了安装盘"，而不是"文件此刻存在"。
# WSL 每次启动虚拟机都会重建 swap 虚拟盘，检查时可能正好撞上重建窗口，
# 因此文件存在只能作为加分项，配置正确才是判据。
if (Test-SetupSwitch $config['CONFIGURE_SWAP']) {
    $swap = Join-Path (ConvertTo-SetupWinPath $config['INSTALL_ROOT']) 'swap.vhdx'
    $swapConfigured = $false
    $wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path -LiteralPath $wslConfigPath) {
        $expectedIni = 'swapFile=' + $swap.Replace('\', '\\')
        foreach ($line in [System.IO.File]::ReadAllLines($wslConfigPath, [System.Text.Encoding]::UTF8)) {
            if ($line.Trim() -ieq $expectedIni) { $swapConfigured = $true; break }
        }
    }

    if ($swapConfigured -and (Test-Path -LiteralPath $swap)) {
        Write-SetupOk ("交换文件已配置在目标盘且已生成：{0}（{1} MB）" -f $swap, [math]::Round((Get-Item -LiteralPath $swap).Length / 1MB, 1))
    } elseif ($swapConfigured) {
        Write-SetupOk "交换文件已配置在目标盘：$swap（当前未生成，WSL 启动时会创建）"
    } else {
        $notes += "交换文件未指向安装盘（$swap）—— 执行阶段 50 并在 wsl --shutdown 后重启生效"
        Write-SetupWarn "交换文件未指向安装盘：$swap"
    }
}

# ---------------------------------------------------------------- 5. 快捷方式
if (Test-SetupSwitch $config['CREATE_SHORTCUT']) {
    $displayName = $config['SHORTCUT_NAME']
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $distro }
    $link = Join-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') "$displayName.lnk"
    if (Test-Path -LiteralPath $link) {
        Write-SetupOk "开始菜单快捷方式：$link"
    } else {
        $notes += '开始菜单快捷方式缺失'
        Write-SetupWarn "开始菜单快捷方式缺失：$link"
    }
}

# ---------------------------------------------------------------- 6. 磁盘余量
$freeGB = Get-SetupFreeSpaceGB -Path $distroDir
if ($freeGB -ge 0) {
    Write-SetupLog -Message "安装盘剩余：$freeGB GB"
    if ($freeGB -lt 10) { $notes += "安装盘剩余空间偏低（${freeGB} GB）" }
}

# ---------------------------------------------------------------- 7. Linux 侧验证
$linuxRepo = ConvertTo-SetupWslPath -WinPath $root
$verifyScript = "$linuxRepo/stages/linux/99-verify.sh"

Write-SetupStep 'Linux 侧验证'
if (Test-WslDistroInstalled -Distro $distro) {
    $r = Invoke-WslShell -Distro $distro -User 'root' -ScriptPath $verifyScript
    $logFile = Join-Path (Join-Path $root 'logs\windows') '90-linux-verify.log'
    Write-SetupTextFile -Path $logFile -Content $r.Output
    if ($r.Output) {
        foreach ($line in ($r.Output -split "`n")) {
            $t = $line.TrimEnd()
            if ($t) { Write-Host "    $t" }
        }
    }
    if ($r.ExitCode -ne 0) {
        $hardFailures += "Linux 侧验证失败（退出码 $($r.ExitCode)）"
        Write-SetupFail "Linux 侧验证失败，详见 $logFile"
    } else {
        Write-SetupOk 'Linux 侧验证通过'
    }
}

# ---------------------------------------------------------------- 结论
Write-SetupStep '验证结论'
foreach ($n in $notes) { Write-SetupWarn "提醒：$n" }

if ($hardFailures.Count -gt 0) {
    foreach ($f in $hardFailures) { Write-SetupFail "失败：$f" }
    Set-SetupStageState -RepoRoot $root -Stage '90-verify' -Status 'failed' -Note ($hardFailures -join ' / ')
    exit $global:SW_ERROR
}

Write-SetupOk '全部验证通过'
Write-SetupLog -Message ''
Write-SetupLog -Message "启动方式：wsl -d $distro    或   开始菜单搜索 $distro"
Set-SetupStageState -RepoRoot $root -Stage '90-verify' -Status 'ok' -Note 'passed'
exit $global:SW_OK
