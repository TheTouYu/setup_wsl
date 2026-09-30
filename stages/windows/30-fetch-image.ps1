#Requires -Version 5.1
<#
.SYNOPSIS
    阶段 30 —— 下载并校验 Arch Linux 官方 WSL 镜像。
.DESCRIPTION
    只做下载与校验，不安装任何东西。
    校验策略：从主镜像取 .SHA256，并与备用镜像的 .SHA256 交叉比对，
    两处一致才认为可信 —— 单一镜像的文件与校验值同时损坏时无法发现，
    交叉比对能挡住这种情况。
    已下载且校验一致时直接跳过（幂等）。
.EXITCODE
    0   镜像就绪
    1   下载或校验失败
#>
[CmdletBinding()]
param(
    [switch]$Force   # 忽略本地缓存，强制重新下载
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name '30-fetch-image' -KeepDays ([int]($config['LOG_KEEP_DAYS'])) | Out-Null

Write-SetupStep '阶段 30：获取 Arch Linux 镜像'

$version = $config['IMAGE_VERSION']
$mirror = $config['IMAGE_MIRROR']
$altMirror = $config['IMAGE_ALT_MIRROR']
$downloadDir = Get-SetupWorkDir -RepoRoot $root -Name 'downloads'

if ($version -eq 'latest') {
    $fileName = 'archlinux.wsl'
} else {
    $fileName = "archlinux-$version.wsl"
}
$url = "$mirror/wsl/$version/$fileName"
$target = Join-Path $downloadDir $fileName
$manifestPath = Join-Path $downloadDir 'image-manifest.json'

Write-SetupLog -Message "版本：$version"
Write-SetupLog -Message "来源：$url"
Write-SetupLog -Message "落地：$target"

function Get-RemoteSha256 {
    param([string]$BaseUrl, [string]$Version, [string]$File)
    $shaUrl = "$BaseUrl/wsl/$Version/$File.SHA256"
    $resp = Invoke-WebRequest -Uri $shaUrl -UseBasicParsing -TimeoutSec 30
    # 官方 .SHA256 的 Content-Type 是 octet-stream，PowerShell 会返回 byte[]，
    # 直接当字符串用会得到 "55 98 51 ..." 这样的字节序列 —— 必须先解码。
    $text = if ($resp.Content -is [byte[]]) {
        [System.Text.Encoding]::ASCII.GetString($resp.Content)
    } else {
        [string]$resp.Content
    }
    if ($text -match '([0-9a-fA-F]{64})') { return $matches[1].ToLowerInvariant() }
    throw "无法从 $shaUrl 解析出 SHA256（内容：$($text.Trim())）"
}

# ---------------------------------------------------------------- 取权威哈希
Write-SetupLog -Message '获取官方校验值 ...'
$expected = Get-RemoteSha256 -BaseUrl $mirror -Version $version -File $fileName
Write-SetupOk "主镜像 SHA256：$expected"

if (-not [string]::IsNullOrWhiteSpace($altMirror) -and $altMirror -ne $mirror) {
    try {
        $altHash = Get-RemoteSha256 -BaseUrl $altMirror -Version $version -File $fileName
        if ($altHash -eq $expected) {
            Write-SetupOk "备用镜像校验值一致（$altMirror）"
        } else {
            Write-SetupWarn "备用镜像校验值不一致！主=$expected 备=$altHash"
            Write-SetupWarn '这可能是镜像同步延迟。将只信任主镜像，但请留意。'
        }
    } catch {
        Write-SetupWarn "备用镜像校验值取不到（$($_.Exception.Message)），跳过交叉比对"
    }
}

# ---------------------------------------------------------------- 本地是否已可用
$needDownload = $true
if ((-not $Force) -and (Test-Path -LiteralPath $target)) {
    $localFile = Get-Item -LiteralPath $target
    if ($localFile.Length -gt 0) {
        Write-SetupLog -Message '本地已有镜像，校验中 ...'
        $localHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($localHash -eq $expected) {
            Write-SetupOk ("本地镜像校验通过，跳过下载（{0} MB）" -f [math]::Round($localFile.Length / 1MB, 1))
            $needDownload = $false
        } else {
            Write-SetupWarn "本地镜像校验不通过，将重新下载"
            Write-SetupWarn "  本地：$localHash"
            Write-SetupWarn "  期望：$expected"
        }
    }
}

# ---------------------------------------------------------------- 下载
if ($needDownload) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    Write-SetupLog -Message '开始下载 ...'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.WebClient
    $client.Headers.Add('User-Agent', 'setup-wsl')
    try {
        $client.DownloadFile($url, $target)
    } finally {
        $client.Dispose()
    }
    $sw.Stop()

    $size = (Get-Item -LiteralPath $target).Length
    $mb = [math]::Round($size / 1MB, 1)
    $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($mb / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
    Write-SetupOk "下载完成：$mb MB / ${sec}s（$speed MB/s）"

    Write-SetupLog -Message '校验下载结果 ...'
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Write-SetupFail 'SHA256 校验失败，文件已删除，请重试或更换镜像。'
        Write-SetupFail "  实际：$actual"
        Write-SetupFail "  期望：$expected"
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        Set-SetupStageState -RepoRoot $root -Stage '30-fetch-image' -Status 'failed' -Note 'sha256-mismatch'
        exit $global:SW_ERROR
    }
    Write-SetupOk 'SHA256 校验通过'
}

# ---------------------------------------------------------------- 记录清单
$finalFile = Get-Item -LiteralPath $target
$manifest = [ordered]@{
    schema_version = 1
    file           = $fileName
    url            = $url
    version        = $version
    sha256         = $expected
    size_bytes     = $finalFile.Length
    verified_at    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
Write-SetupTextFile -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 3)

Set-SetupStageState -RepoRoot $root -Stage '30-fetch-image' -Status 'ok' -Note ("$fileName $expected")
exit $global:SW_OK
