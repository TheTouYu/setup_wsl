#Requires -Version 5.1
<#
.SYNOPSIS
    setup_wsl —— Windows 侧公共库。

.DESCRIPTION
    提供日志、配置解析、路径换算、WSL 调用与阶段状态记录。
    被 bootstrap.ps1 和 stages/windows/*.ps1 dot-source 引入，不直接执行。

.NOTES
    只使用 PowerShell 5.1 兼容语法（Windows 10/11 内置版本），
    刻意避开 PS7 专属语法：空值合并运算符、三元表达式、
    utf8NoBOM 编码参数等。tests\lint-powershell.ps1 会做语法门禁。
    另：本文件必须保存为 UTF-8 with BOM，否则中文系统下会被按 GBK 解码。
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 记录本库所在目录：$PSScriptRoot 在函数内会跟着定义文件走，先固化下来
$script:SwLibDir = $PSScriptRoot

# ------------------------------------------------------------------ 退出码约定
# 所有阶段脚本都必须用这套退出码，bootstrap 才能正确编排。
$global:SW_OK         = 0    # 成功
$global:SW_ERROR      = 1    # 失败
$global:SW_REBOOT     = 10   # 成功但需重启后继续
$global:SW_NEED_ADMIN = 20   # 需要管理员权限
$global:SW_NEED_INPUT = 30   # 需要用户提供信息
$global:SW_SKIPPED    = 40   # 条件已满足，无需操作

$script:SwLogFile = $null

# ------------------------------------------------------------------ 基础路径

function Get-SetupRepoRoot {
    <# 返回仓库根目录（本文件位于 <root>/lib/windows/）。 #>
    [CmdletBinding()]
    param()
    return (Resolve-Path (Join-Path $script:SwLibDir '..\..')).Path
}

function Get-SetupWorkDir {
    <# 返回仓库内的运行产物目录（logs / downloads / .state）。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $path = Join-Path $RepoRoot $Name
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    return $path
}

# ------------------------------------------------------------------ 配置

function Import-SetupConfig {
    <#
    .SYNOPSIS
        读取 config/default.conf 与 config/local.conf，后者覆盖前者。
    .DESCRIPTION
        严格解析 KEY=value：值内不得含空格、不加引号、# 开头为注释。
        两侧（PowerShell / bash）共用同一份配置，解析规则必须一致。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $merged = [ordered]@{}
    foreach ($rel in @('config\default.conf', 'config\local.conf')) {
        $path = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i].Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $idx = $line.IndexOf('=')
            if ($idx -lt 1) {
                throw "[$rel 第 $($i + 1) 行] 配置格式错误，应为 KEY=value，实际为：$line"
            }
            $key = $line.Substring(0, $idx).Trim()
            $value = $line.Substring($idx + 1).Trim()
            if ($key -notmatch '^[A-Z][A-Z0-9_]*$') {
                throw "[$rel 第 $($i + 1) 行] 键名不合法（须为大写字母/数字/下划线）：$key"
            }
            $merged[$key] = $value
        }
    }
    if ($merged.Count -eq 0) { throw "没有读到任何配置：$RepoRoot\config" }
    return $merged
}

function Test-SetupSwitch {
    <# 判断 yes/no 型配置项。 #>
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim().ToLowerInvariant() -in @('yes', 'y', 'true', '1', 'on'))
}

# ------------------------------------------------------------------ 日志

function Initialize-SetupLog {
    <# 初始化 Windows 侧日志文件，并清理过期日志。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$Name = 'setup',
        [int]$KeepDays = 30
    )
    $dir = Join-Path $RepoRoot 'logs\windows'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if ($KeepDays -gt 0) {
        $deadline = (Get-Date).AddDays(-$KeepDays)
        Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $deadline } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $script:SwLogFile = Join-Path $dir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-SetupLog -Message "日志文件：$script:SwLogFile" -Level INFO
    return $script:SwLogFile
}

function Write-SetupLog {
    <# 同时输出到控制台与日志文件。 #>
    [CmdletBinding()]
    param(
        # AllowEmptyString 是必须的：Mandatory 的 string 参数默认拒绝空字符串，
        # 而调用方经常用 -Message '' 输出空行；缺了它会抛参数绑定异常，
        # 脚本在"看起来成功"之后突然以退出码 1 结束（真机上踩过）。
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$stamp][$Level] $Message"

    switch ($Level) {
        'STEP'  { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'DEBUG' { if ($env:SW_DEBUG) { Write-Host $line -ForegroundColor DarkGray } }
        default { Write-Host $line }
    }

    if ($script:SwLogFile) {
        # UTF8 带 BOM：Windows 侧日志用 Get-Content 默认就能正确读出中文
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::AppendAllText($script:SwLogFile, $line + [Environment]::NewLine, $enc)
    }
}

function Write-SetupStep { param([string]$Message) Write-SetupLog -Message $Message -Level STEP }
function Write-SetupOk   { param([string]$Message) Write-SetupLog -Message $Message -Level OK }
function Write-SetupWarn { param([string]$Message) Write-SetupLog -Message $Message -Level WARN }
function Write-SetupFail { param([string]$Message) Write-SetupLog -Message $Message -Level ERROR }

# ------------------------------------------------------------------ 权限

function Test-SetupAdmin {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SetupAdmin {
    <# 需要管理员时统一从这里退出，bootstrap 才能识别并给出提权指引。 #>
    [CmdletBinding()]
    param([string]$Reason = '本阶段需要管理员权限')
    if (-not (Test-SetupAdmin)) {
        Write-SetupFail "$Reason —— 请用【管理员身份】重新运行。"
        exit $global:SW_NEED_ADMIN
    }
}

# ------------------------------------------------------------------ 路径换算

function ConvertTo-SetupWinPath {
    <# 配置里统一用正斜杠，落到 Windows API 前转成反斜杠。 #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return ($Path.Replace('/', '\'))
}

function Resolve-SetupDistroDir {
    <# 发行版数据目录：DISTRO_DIR 优先，否则 <INSTALL_ROOT>\<DISTRO_NAME>。 #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)
    if ($Config.DISTRO_DIR) { return (ConvertTo-SetupWinPath $Config.DISTRO_DIR) }
    $root = ConvertTo-SetupWinPath $Config.INSTALL_ROOT
    return (Join-Path $root $Config.DISTRO_NAME)
}

function ConvertTo-SetupWslPath {
    <#
    .SYNOPSIS
        把 Windows 路径换算成 WSL 内可见的 Linux 路径。
    .DESCRIPTION
        同时支持两种仓库布局：
          1) 仓库在 Windows 盘上   D:\a\b        -> /mnt/d/a/b
          2) 仓库在 WSL 文件系统内  \\wsl.localhost\archlinux\home\h\...  -> /home/h/...
        第二种情形让"直接在 WSL 里 clone 再跑 bootstrap"也能工作。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WinPath)

    if ($WinPath -match '^\\\\wsl(?:\.localhost|\$)\\[^\\]+\\(.*)$') {
        $rest = $matches[1] -replace '\\', '/'
        return '/' + $rest.TrimStart('/')
    }
    if ($WinPath -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    throw "无法换算成 WSL 路径（既不是盘符路径也不是 \\wsl.localhost 路径）：$WinPath"
}

function Write-SetupTextFile {
    <# 写 UTF-8 无 BOM 文本。.wslconfig 等被非 Windows 程序读取的文件必须无 BOM。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# ------------------------------------------------------------------ WSL 调用

function Invoke-WslCli {
    <#
    .SYNOPSIS
        调用 wsl.exe 自身的子命令（--version、-l -v、--import 等）。
    .DESCRIPTION
        wsl.exe 的输出是 UTF-16LE，必须临时把控制台输出编码切到 Unicode，
        否则中文会变成乱码或夹杂 \0 字节。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return Invoke-NativeCapture -Exe 'wsl.exe' -Arguments $Arguments -Encoding ([System.Text.Encoding]::Unicode)
}

function Test-WslReady {
    <# WSL 本体是否已就绪（能报告版本）。 #>
    [CmdletBinding()]
    param()
    $r = Invoke-WslCli -Arguments @('--version')
    if ($r.ExitCode -ne 0) { return $false }
    return ($r.Output -match 'WSL')
}

function Get-WslDistroNames {
    <# 已注册的发行版名列表（--list --quiet 的输出是 UTF-16LE）。 #>
    [CmdletBinding()]
    param()
    $r = Invoke-NativeCapture -Exe 'wsl.exe' -Arguments @('--list', '--quiet') `
        -Encoding ([System.Text.Encoding]::Unicode)
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) { return @() }
    return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Test-WslDistroInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Distro)
    return ((Get-WslDistroNames) -contains $Distro)
}

function Invoke-NativeCapture {
    <#
    .SYNOPSIS
        调用原生程序并捕获输出，同时屏蔽两件很容易踩的事。
    .DESCRIPTION
        1) **stderr 不等于失败**。在 $ErrorActionPreference='Stop' 下，
           原生程序写到 stderr 的内容会被 PowerShell 提升为终止性错误。
           WSL 在本机会固定打印一条 localhost 代理提示到 stderr
           （"检测到 localhost 代理配置，但未镜像到 WSL…"），
           于是一次成功的调用也会让整个阶段崩掉。
           所以这里把错误偏好临时降为 Continue，只看退出码判断成败。
        2) **编码**。wsl.exe 自身的输出是 UTF-16LE，发行版内的命令输出是 UTF-8，
           必须分别指定，否则中文乱码或夹杂 \0 字节。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding
    )

    $prevEncoding = [Console]::OutputEncoding
    $prevPreference = $ErrorActionPreference
    $exitCode = 1
    $text = ''

    try {
        [Console]::OutputEncoding = $Encoding
        $ErrorActionPreference = 'Continue'
        $raw = & $Exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($raw | Out-String)
    } finally {
        [Console]::OutputEncoding = $prevEncoding
        $ErrorActionPreference = $prevPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($text -replace "`0", '').Trim()
    }
}

function Invoke-WslShell {
    <#
    .SYNOPSIS
        在发行版内执行一个**脚本文件**。
    .DESCRIPTION
        刻意只接受脚本路径而不接受命令字符串：
        PowerShell 5.1 向原生程序传参时对内嵌引号的处理有缺陷，
        把命令拼成字符串传进 bash 会被吃掉引号（本项目在真实环境踩过）。
        统一写成脚本文件再执行，可彻底绕开这类问题。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [string]$User = 'root',
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArgs = @()
    )
    $argv = @('-d', $Distro, '-u', $User, '--', 'bash', $ScriptPath) + $ScriptArgs
    return Invoke-NativeCapture -Exe 'wsl.exe' -Arguments $argv -Encoding ([System.Text.Encoding]::UTF8)
}

function Test-WslPathReadable {
    <# 确认发行版内能读到该路径（用于给出"仓库位置不可达"的明确报错）。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$LinuxPath
    )
    $r = Invoke-NativeCapture -Exe 'wsl.exe' `
        -Arguments @('-d', $Distro, '-u', 'root', '--', 'test', '-r', $LinuxPath) `
        -Encoding ([System.Text.Encoding]::UTF8)
    return ($r.ExitCode -eq 0)
}

# ------------------------------------------------------------------ 状态记录

function Get-SetupStateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $dir = Get-SetupWorkDir -RepoRoot $RepoRoot -Name '.state'
    return (Join-Path $dir 'state.json')
}

function Get-SetupState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $file = Get-SetupStateFile -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $file)) { return @{} }
    try {
        $obj = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
        return $map
    } catch {
        Write-SetupWarn "状态文件损坏，将重建：$file"
        return @{}
    }
}

function Set-SetupStageState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Note = ''
    )
    $map = Get-SetupState -RepoRoot $RepoRoot
    $map[$Stage] = [pscustomobject]@{
        status = $Status
        time   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        note   = $Note
    }
    $file = Get-SetupStateFile -RepoRoot $RepoRoot
    Write-SetupTextFile -Path $file -Content ($map | ConvertTo-Json -Depth 5)
}

# ------------------------------------------------------------------ 其它工具

function Get-SetupFreeSpaceGB {
    <# 返回指定路径所在盘的剩余空间（GB）。 #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $drive = $root.TrimEnd('\').TrimEnd(':')
    if ($drive.Length -eq 1) {
        $d = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
        if ($d) { return [math]::Round($d.Free / 1GB, 1) }
    }
    return -1
}

function Set-IniValue {
    <#
    .SYNOPSIS
        在 INI 文件里设置某个段（section）下的键值，保留其它全部内容。
    .DESCRIPTION
        .wslconfig 是用户自己的配置文件，可能已有 memory / processors 等设置，
        绝不能用整文件覆盖的方式写入。本函数按段定位，只改目标键：
        键存在则替换，不存在则在该段末尾插入，段不存在则整体追加。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
    }

    $out = New-Object System.Collections.Generic.List[string]
    $inTarget = $false
    $sectionFound = $false
    $keyWritten = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\[(.+)\]$') {
            # 即将离开目标段：若键还没写，补在本段末尾
            if ($inTarget -and -not $keyWritten) {
                $out.Add("$Key=$Value"); $keyWritten = $true
            }
            $inTarget = ($matches[1].Trim() -ieq $Section)
            if ($inTarget) { $sectionFound = $true }
            $out.Add($line)
            continue
        }

        if ($inTarget -and $trimmed -match ("^" + [regex]::Escape($Key) + "\s*=")) {
            $out.Add("$Key=$Value"); $keyWritten = $true
            continue
        }

        $out.Add($line)
    }

    if ($inTarget -and -not $keyWritten) { $out.Add("$Key=$Value"); $keyWritten = $true }

    if (-not $sectionFound) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -ne '') { $out.Add('') }
        $out.Add("[$Section]")
        $out.Add("$Key=$Value")
    }

    Write-SetupTextFile -Path $Path -Content (($out -join "`r`n") + "`r`n")
}

function Read-SetupSecret {
    <# 交互读取密码并转成明文，供写入临时文件交给 Linux 阶段使用。 #>
    [CmdletBinding()]
    param([string]$Prompt = '请输入 Linux 用户密码')
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Confirm-SetupAction {
    <# 需要人确认时的统一入口；-AssumeYes 时直接放行（供 CI 使用）。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [switch]$AssumeYes
    )
    if ($AssumeYes) { return $true }
    $answer = Read-Host -Prompt "$Question [y/N]"
    return ($answer -match '^(y|yes|Y|YES)$')
}
