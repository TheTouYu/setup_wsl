#Requires -Version 5.1
<#
.SYNOPSIS
    setup_wsl —— 从零创建 WSL 开发环境的一键入口（Windows 侧）。

.DESCRIPTION
    按阶段编排整个流程，每个阶段独立进程执行、可单独重跑：
        00 环境体检      只读，检查版本/虚拟化/磁盘/网络
        10 启用功能      需要管理员，可能要求重启
        20 安装 WSL      需要管理员
        30 获取镜像      下载 + SHA256 双镜像交叉校验
        40 导入发行版    数据落在指定盘（默认 D:）
        50 配置 wslconfig 交换文件挪到安装盘
        60 创建快捷方式   开始菜单入口
        70 配置发行版    在发行版内执行 Linux 侧全部阶段
        90 端到端验证    只读，报告真实状态

    阶段是幂等的：已完成的会自行跳过，中断后直接重跑即可。

.PARAMETER Only
    只执行指定阶段编号，逗号分隔，例如 -Only 30,40

.PARAMETER Skip
    跳过指定阶段编号，例如 -Skip 50,60

.PARAMETER Password
    Linux 用户的密码。不传则读取 config/local.conf 的 LINUX_PASSWORD；
    两者都没有时，阶段 05 会在交互终端里询问。

.PARAMETER Plan
    只打印将要执行的阶段，不实际执行。

.EXAMPLE
    # 先看要做什么
    .\bootstrap.ps1 -Plan

    # 以管理员身份全量执行
    .\bootstrap.ps1

    # 只重跑镜像下载与导入
    .\bootstrap.ps1 -Only 30,40
#>
[CmdletBinding()]
param(
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [string]$Password = '',
    [switch]$Plan
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name 'bootstrap' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

$allStages = @(
    [pscustomobject]@{ Id = '00'; File = '00-preflight.ps1';      Title = '环境体检' }
    [pscustomobject]@{ Id = '10'; File = '10-enable-features.ps1'; Title = '启用 WSL 功能（需管理员）' }
    [pscustomobject]@{ Id = '20'; File = '20-install-wsl.ps1';     Title = '安装 WSL 本体（需管理员）' }
    [pscustomobject]@{ Id = '30'; File = '30-fetch-image.ps1';     Title = '获取并校验镜像' }
    [pscustomobject]@{ Id = '40'; File = '40-import-distro.ps1';   Title = '导入发行版' }
    [pscustomobject]@{ Id = '50'; File = '50-wslconfig.ps1';       Title = '配置 .wslconfig' }
    [pscustomobject]@{ Id = '60'; File = '60-shortcut.ps1';        Title = '创建开始菜单快捷方式' }
    [pscustomobject]@{ Id = '70'; File = '70-provision.ps1';       Title = '配置发行版内部环境' }
    [pscustomobject]@{ Id = '80'; File = '80-dsh-autostart.ps1';   Title = 'DSH 服务与开机自启' }
    [pscustomobject]@{ Id = '90'; File = '90-verify.ps1';          Title = '端到端验证' }
)

# ---------------------------------------------------------------- 阶段筛选
$stages = $allStages
if ($Only.Count -gt 0) {
    $stages = $stages | Where-Object { $Only -contains $_.Id }
}
if ($Skip.Count -gt 0) {
    $stages = $stages | Where-Object { $Skip -notcontains $_.Id }
}

# ---------------------------------------------------------------- 概览
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' setup_wsl —— WSL 开发环境一键安装' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("  仓库位置    : {0}" -f $root)
Write-Host ("  发行版名称  : {0}" -f $config['DISTRO_NAME'])
Write-Host ("  安装位置    : {0}" -f (Resolve-SetupDistroDir -Config $config))
Write-Host ("  Linux 用户  : {0}" -f $config['LINUX_USER'])
Write-Host ("  镜像源方案  : {0}" -f $config['MIRROR_PROFILE'])
Write-Host ("  管理员权限  : {0}" -f (Test-SetupAdmin))
Write-Host ''
Write-Host '  执行计划：' -ForegroundColor Cyan
foreach ($s in $stages) {
    Write-Host ("    [{0}] {1}" -f $s.Id, $s.Title)
}
Write-Host ''

if ($Plan) {
    Write-Host '（-Plan 模式：未执行任何操作）' -ForegroundColor Yellow
    exit $global:SW_OK
}

if (-not (Test-SetupAdmin)) {
    Write-SetupWarn '当前不是管理员：阶段 10、20 会失败并提示提权。其余阶段可正常执行。'
}

# ---------------------------------------------------------------- 逐阶段执行
$stagesDir = Join-Path $root 'stages\windows'
$summary = @()
$stopReason = $null
$overallExit = $global:SW_OK

foreach ($stage in $stages) {
    $path = Join-Path $stagesDir $stage.File
    if (-not (Test-Path -LiteralPath $path)) {
        Write-SetupFail "阶段脚本缺失：$path"
        $overallExit = $global:SW_ERROR
        break
    }

    Write-Host ''
    Write-Host ('─' * 60) -ForegroundColor DarkGray
    Write-Host (" ▶ [{0}] {1}" -f $stage.Id, $stage.Title) -ForegroundColor Cyan
    Write-Host ('─' * 60) -ForegroundColor DarkGray

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path)
    if ($stage.Id -eq '70' -and -not [string]::IsNullOrEmpty($Password)) {
        $childArgs += @('-Password', $Password)
    }

    & powershell.exe @childArgs
    $code = $LASTEXITCODE
    $sw.Stop()

    $summary += [pscustomobject]@{
        Id       = $stage.Id
        Title    = $stage.Title
        ExitCode = $code
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }

    switch ($code) {
        0 {
            Write-SetupOk ("[{0}] 完成（{1} 秒）" -f $stage.Id, [math]::Round($sw.Elapsed.TotalSeconds, 1))
        }
        { $_ -eq $global:SW_REBOOT } {
            Write-Host ''
            Write-SetupWarn '接下来需要重启电脑，重启后重新运行本脚本即可（已完成的阶段会自动跳过）。'
            $stopReason = 'reboot'
            $overallExit = $global:SW_REBOOT
        }
        { $_ -eq $global:SW_NEED_ADMIN } {
            Write-Host ''
            Write-SetupFail '该阶段需要管理员权限。请以管理员身份打开 PowerShell，然后重新运行：'
            Write-Host '    .\bootstrap.ps1' -ForegroundColor Yellow
            $stopReason = 'admin'
            $overallExit = $global:SW_NEED_ADMIN
        }
        { $_ -eq $global:SW_NEED_INPUT } {
            $stopReason = 'input'
            $overallExit = $global:SW_NEED_INPUT
        }
        default {
            Write-SetupFail ("[{0}] 失败，退出码 {1}" -f $stage.Id, $code)
            $stopReason = 'error'
            $overallExit = $global:SW_ERROR
        }
    }

    if ($stopReason) { break }
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' 执行汇总' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
foreach ($s in $summary) {
    $mark = if ($s.ExitCode -eq 0) { '✓' } elseif ($s.ExitCode -eq 10) { '↻' } else { '✗' }
    $color = if ($s.ExitCode -eq 0) { 'Green' } elseif ($s.ExitCode -eq 10) { 'Yellow' } else { 'Red' }
    Write-Host ("  {0} [{1}] {2,-24} exit={3,-3} {4}s" -f $mark, $s.Id, $s.Title, $s.ExitCode, $s.Seconds) -ForegroundColor $color
}

switch ($stopReason) {
    'reboot' {
        Write-Host ''
        Write-SetupWarn '请重启电脑，然后重新运行 .\bootstrap.ps1 继续。'
    }
    'admin' {
        Write-Host ''
        Write-SetupWarn '请用管理员身份重新运行 .\bootstrap.ps1。'
    }
    'input' {
        Write-Host ''
        Write-SetupWarn '需要补充信息后重试（详见上方提示）。'
    }
    'error' {
        Write-Host ''
        Write-SetupWarn ("详细日志：{0}" -f (Join-Path $root 'logs\windows'))
    }
    default {
        Write-Host ''
        $distro = $config['DISTRO_NAME']
        Write-SetupOk ('全部完成。启动方式：wsl -d {0}     或   开始菜单搜索 {0}' -f $distro)
    }
}

$finalNote = if ($stopReason) { $stopReason } else { 'done' }
$finalStatus = if ($overallExit -eq 0) { 'ok' } else { 'stopped' }
Set-SetupStageState -RepoRoot $root -Stage 'bootstrap' -Status $finalStatus -Note $finalNote
exit $overallExit
