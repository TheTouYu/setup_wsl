#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 60 —— 创建开始菜单快捷方式。
.DESCRIPTION
    `wsl --import` 导入的发行版不会自动出现在开始菜单，这里补一个。
    图标用镜像自带的 shortcut.ico（导入时会落在发行版目录里）。
    受 CREATE_SHORTCUT 开关控制；重复执行直接覆盖同名快捷方式。
.EXITCODE
    0   已创建 / 已跳过
    1   失败
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '60-shortcut' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 60：创建开始菜单快捷方式'

if (-not (Test-SetupSwitch $config['CREATE_SHORTCUT'])) {
    Write-SetupLog -Message 'CREATE_SHORTCUT=no，跳过'
    Set-SetupStageState -RepoRoot $root -Stage '60-shortcut' -Status 'skipped' -Note 'disabled'
    exit $global:SW_OK
}

$distro = $config['DISTRO_NAME']
$distroDir = Resolve-SetupDistroDir -Config $config
$iconPath = Join-Path $distroDir 'shortcut.ico'

$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
if (-not (Test-Path -LiteralPath $programs)) {
    Write-SetupFail "找不到开始菜单目录：$programs"
    Set-SetupStageState -RepoRoot $root -Stage '60-shortcut' -Status 'failed' -Note 'no-start-menu'
    exit $global:SW_ERROR
}

$displayName = $config['SHORTCUT_NAME']
if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $config['DISTRO_NAME'] }
$linkPath = Join-Path $programs "$displayName.lnk"

# --cd ~ 让每次打开都直接进入 Linux 家目录，而不是 Windows 侧当前目录
$arguments = "-d $distro --cd ~"

try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($linkPath)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $link.Arguments = $arguments
    $link.Description = "$distro (WSL2)"
    $link.WorkingDirectory = $env:USERPROFILE
    if (Test-Path -LiteralPath $iconPath) {
        $link.IconLocation = $iconPath
    } else {
        Write-SetupWarn "未找到图标 $iconPath，将使用默认图标"
    }
    $link.Save()
    Write-SetupOk "已创建：$linkPath"
    Write-SetupLog -Message "  目标：wsl.exe $arguments"
} catch {
    Write-SetupFail "创建快捷方式失败：$($_.Exception.Message)"
    Write-SetupWarn '可手动创建：右键开始菜单 → 运行 → 输入 shell:programs，然后手工新建指向 wsl.exe 的快捷方式'
    Set-SetupStageState -RepoRoot $root -Stage '60-shortcut' -Status 'failed' -Note $_.Exception.Message
    exit $global:SW_ERROR
}

Set-SetupStageState -RepoRoot $root -Stage '60-shortcut' -Status 'ok' -Note $linkPath
exit $global:SW_OK
