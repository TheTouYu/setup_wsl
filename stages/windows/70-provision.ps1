#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 70 —— 在发行版内按序执行 Linux 侧阶段脚本。
.DESCRIPTION
    这是 Windows 侧与 Linux 侧的唯一接缝。三条硬规则：
      1) 只把**脚本文件路径**交给 bash，绝不把命令拼成字符串 ——
         PowerShell 5.1 向原生程序传参时对内嵌引号的处理有缺陷，
         拼字符串会被吃掉引号（本项目在真实环境踩过这个坑）。
      2) 每个阶段独立进程执行，一个失败不影响已完成的阶段。
      3) 密码等敏感值只经文件传递，且由 Linux 阶段用完即删。
.EXITCODE
    0   全部成功
    1   有阶段失败
    30  需要用户提供信息（如密码）
#>
[CmdletBinding()]
param(
    [string]$Password = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '70-provision' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 70：配置发行版内部环境'

$distro = $config['DISTRO_NAME']

if (-not (Test-WslDistroInstalled -Distro $distro)) {
    Write-SetupFail "发行版 '$distro' 未安装，请先执行阶段 40。"
    exit $global:SW_NEED_INPUT
}

# ---------------------------------------------------------------- 定位 Linux 侧脚本
$linuxRepo = ConvertTo-SetupWslPath -WinPath $root
$linuxStagesDir = "$linuxRepo/stages/linux"
Write-SetupLog -Message "Linux 侧仓库路径：$linuxRepo"

if (-not (Test-WslPathReadable -Distro $distro -LinuxPath $linuxStagesDir)) {
    Write-SetupFail "发行版内读不到脚本目录：$linuxStagesDir"
    Write-SetupWarn '常见原因与处理：'
    Write-SetupWarn '  · /mnt 自动挂载被关闭 —— 检查 /etc/wsl.conf 的 [automount] enabled'
    Write-SetupWarn '  · 换个位置：把仓库 clone 到 WSL 里，再从 WSL 内执行 Linux 阶段：'
    Write-SetupWarn "      wsl -d $distro -u root -- bash /path/to/repo/stages/linux/run-all.sh"
    Set-SetupStageState -RepoRoot $root -Stage '70-provision' -Status 'failed' -Note 'linux-path-unreadable'
    exit $global:SW_ERROR
}

# ---------------------------------------------------------------- 密码传递
$passwordArgs = @()
$plainPassword = $Password
if ([string]::IsNullOrEmpty($plainPassword)) { $plainPassword = $config['LINUX_PASSWORD'] }

if (-not [string]::IsNullOrEmpty($plainPassword)) {
    $stateDir = Get-SetupWorkDir -RepoRoot $root -Name '.state'
    $pwWin = Join-Path $stateDir 'linux-password'
    # 无 BOM 且末尾仅一个换行；Linux 阶段读完立即删除
    Write-SetupTextFile -Path $pwWin -Content ($plainPassword + "`n")
    $pwLinux = ConvertTo-SetupWslPath -WinPath $pwWin
    $passwordArgs = @('--password-file', $pwLinux)
    Write-SetupLog -Message '密码经临时文件传递，Linux 阶段使用后会立即删除'
} else {
    Write-SetupLog -Message '未提供密码，将由 Linux 阶段交互询问'
}

# ---------------------------------------------------------------- 阶段清单
$stagesDirWin = Join-Path $root 'stages\linux'
$files = Get-ChildItem -LiteralPath $stagesDirWin -Filter '*.sh' -File |
    Sort-Object Name |
    Where-Object { $_.Name -notlike 'run-all*' }

$filter = $config['LINUX_STAGES']
if (-not [string]::IsNullOrWhiteSpace($filter)) {
    $prefixes = @($filter.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $files = $files | Where-Object {
        $name = $_.Name
        ($prefixes | Where-Object { $name.StartsWith($_) }).Count -gt 0
    }
    Write-SetupLog -Message ("仅执行指定阶段：{0}" -f ($prefixes -join ', '))
}

if (@($files).Count -eq 0) {
    Write-SetupWarn '没有找到要执行的 Linux 阶段脚本'
    exit $global:SW_OK
}

Write-SetupLog -Message ("待执行 {0} 个阶段：" -f @($files).Count)
foreach ($f in $files) { Write-SetupLog -Message "  · $($f.Name)" }

# ---------------------------------------------------------------- 逐个执行
$results = @()
$failed = $false

foreach ($file in $files) {
    $stageName = $file.BaseName
    Write-SetupStep "→ $stageName"

    $scriptPath = "$linuxStagesDir/$($file.Name)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WslShell -Distro $distro -User 'root' -ScriptPath $scriptPath -ScriptArgs $passwordArgs
    $sw.Stop()

    $logFile = Join-Path (Join-Path $root 'logs\windows') ("70-{0}.log" -f $stageName)
    Write-SetupTextFile -Path $logFile -Content $r.Output

    if ($r.Output) {
        foreach ($line in ($r.Output -split "`n")) {
            $t = $line.TrimEnd()
            if ($t) { Write-Host "    $t" }
        }
    }
    Write-SetupLog -Message "  （完整输出：$logFile，用时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）" -Level DEBUG

    $status = if ($r.ExitCode -eq 0) { 'ok' } else { 'failed' }
    $results += [pscustomobject]@{ Stage = $stageName; ExitCode = $r.ExitCode; Status = $status }

    if ($r.ExitCode -ne 0) {
        Write-SetupFail "$stageName 失败（退出码 $($r.ExitCode)）"
        $failed = $true
        break
    }
    Write-SetupOk "$stageName 完成"
}

# ---------------------------------------------------------------- 汇总
Write-SetupStep '阶段 70 汇总'
foreach ($r in $results) {
    $mark = if ($r.Status -eq 'ok') { '✓' } else { '✗' }
    Write-SetupLog -Message ("  {0} {1,-28} exit={2}" -f $mark, $r.Stage, $r.ExitCode)
}

if ($failed) {
    Set-SetupStageState -RepoRoot $root -Stage '70-provision' -Status 'failed' -Note '见上方失败阶段'
    exit $global:SW_ERROR
}

Set-SetupStageState -RepoRoot $root -Stage '70-provision' -Status 'ok' -Note ("$(@($results).Count) 个阶段")
exit $global:SW_OK
