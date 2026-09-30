# 踩坑记录

本文件记录在**真实环境**里踩到并已修复的问题。
每条都包含：现象 → 真因 → 修法 → 代码里的位置。

写这份文档的原因是：这里几乎每一条，网上流传的说法都是错的或者过时的，
只讲现象不讲根因，下次换个环境又会重新踩一遍。

---

## 1. PowerShell 5.1 把无 BOM 的中文 `.ps1` 读成乱码

**现象**

脚本在中文 Windows 上运行时报出莫名其妙的解析错误：

```
At ...\lint-powershell.ps1:44 char:13
+ Write-Host ("璇硶妫€鏌ラ€氳繃锛歿0} 涓枃浠? -f $files.Count)
The string is missing the terminator: ".
```

注意报错内容里的 `璇硶妫€鏌` —— 那正是"语法检查"四个字的 UTF-8 字节被按 GBK 解读的结果。

**真因**

Windows PowerShell 5.1（系统内置版本）读取 `.ps1` 文件时，
**如果文件没有 BOM，就按系统 ANSI 代码页解码**。中文系统上是 GBK。
UTF-8 的中文被按 GBK 解读会变成乱码；更糟的是，
乱码后的某个字节序列可能恰好吃掉后面的引号，于是报"字符串未结束"——
错误位置和真实原因完全无关，极难排查。

**修法**

所有含非 ASCII 字符的 `.ps1` 一律保存为 **UTF-8 with BOM**。

**代码位置**

- `tools/fix-encoding.ps1` —— 批量补 BOM，幂等可重复运行
- `tests/lint-powershell.ps1` —— 把 BOM 检查固化为门禁，缺失即失败
- `README.md` 开发章节 —— 编辑 `.ps1` 后必须跑一次 `fix-encoding.ps1`

---

## 2. 向 `wsl.exe` 传含引号的命令字符串会被吃掉引号

**现象**

```powershell
wsl.exe -d archlinux -u root -- bash -c 'echo "user=$(whoami)"'
```

期待输出 `user=h`，实际只输出 `user=`，后面的内容整段消失；
有时还会报 `syntax error near unexpected token`。

**真因**

PowerShell 5.1 在把参数传给原生程序（`wsl.exe`）时，
对参数内嵌引号的转义处理有缺陷 —— 它不会按 C 运行库的规则转义内嵌引号，
于是 bash 收到的已经是被截断的命令串。
命令越长、引号越多、越容易踩到。

**修法**

**绝不把命令拼成字符串传进 WSL。**
一律先落地成脚本文件，再把**文件路径**交给 bash：

```powershell
wsl.exe -d archlinux -u root -- bash /path/to/script.sh --arg value
```

这样参数里没有引号，转义问题从根上消失；顺带还获得了可复用、可单独调试的脚本。

**代码位置**

- `lib/windows/common.ps1` 的 `Invoke-WslShell` —— 刻意只接受脚本路径，
  不接受命令字符串，从接口层面杜绝这种写法
- 所有 `stages/linux/*.sh` 都是独立脚本文件

---

## 3. pacman 7 在 WSL 下所有镜像都 DNS 超时

**现象**

配置好国内镜像后 `pacman -Syy`，**每一个**镜像都报：

```
error: failed retrieving file 'core.db' from mirrors.ustc.edu.cn : Resolving timed out after 10002 milliseconds
warning: too many errors from mirrors.ustc.edu.cn, skipping for the remainder of this transaction
```

但同一个地址用 `curl` 访问**完全正常**（HTTP 200）。看起来像 DNS 故障或网络问题，
换镜像、改 DNS、重启 WSL 都没用。

**真因**

两条事实叠加：

1. WSL 里 `/etc/resolv.conf` 是一个**符号链接**，指向 `/mnt/wsl/resolv.conf`
   （WSL 自动生成并维护它）。
2. pacman 7 引入了下载沙箱：把下载进程**降权**到 `alpm` 用户，
   并用 **Landlock** 限制它能访问的文件路径。

沙箱不允许跟随指向 `/mnt/wsl/` 的符号链接，于是降权后的下载进程读不到
`resolv.conf`，DNS 解析必然失败。
报错信息说的是"解析超时"，真因却是**沙箱挡了文件访问** —— 极具误导性。

**修法**

在 `/etc/pacman.conf` 里关闭下载沙箱：

```
DisableSandboxFilesystem
DisableSandboxSyscalls
```

代价是失去一层针对恶意镜像的纵深防御。在镜像走 HTTPS 且来源可信的前提下可以接受。
（替代方案是把 `resolv.conf` 改成实体文件，但那会破坏 WSL 的自动 DNS 管理。）

**代码位置**

- `stages/linux/02-mirrors.sh` 的 `fix_download_sandbox()`
- `tests/lint.sh` 有回归检查，确保这个修复不会被误删

---

## 4. Arch 镜像里的 gnupg 目录是个空壳

**现象**

按官方文档执行 `pacman-key --populate archlinux`，报：

```
==> ERROR: You do not have sufficient permissions to read the pacman keyring.
==> Use 'pacman-key --init' to correct the keyring permissions.
```

但当前身份**明明是 root**，权限不可能不足。按提示跑 `--init` 又像是多余的。

**真因**

Arch 官方 WSL 镜像里的 `/etc/pacman.d/gnupg/` 目录**存在，但里面只有一个
`.gpg-v21-migrated` 标记文件，没有任何密钥环**（镜像为可复现构建，
密钥环在首次启动时才生成）。

`pacman-key` 的判断逻辑是"目录在但密钥环不可用 → 报权限问题"，
于是给出了这条误导性的错误信息。

**修法**

判断密钥环是否可用时，**不能只看目录是否存在**，要看实体文件：

```bash
[[ -s /etc/pacman.d/gnupg/pubring.gpg ]] && pacman-key --list-keys >/dev/null 2>&1
```

不满足才执行 `pacman-key --init`。

**代码位置**

- `stages/linux/01-keyring.sh` 的 `keyring_usable()`
- `tests/lint.sh` 有回归检查
- 顺带记录：初始化后正常应有 **180+ 个公钥**，脚本会在少于 50 个时报错中止

---

## 5. WSL 虚拟机空闲后自动关闭，`/tmp` 里的东西会消失

**现象**

先生成一份计划文件到 `/tmp`，几分钟后再执行时：

```
[Errno 2] No such file or directory: '/tmp/pkc-install-plan-aibl.json'
```

**真因**

WSL2 的虚拟机在所有会话退出后会自动关闭（默认有一段空闲等待）。
虚拟机关闭 = 整个 Linux 根文件系统卸载，**`/tmp` 不是持久存储**。
每次 `wsl.exe ...` 是独立进程，中间完全可能隔着一次虚拟机关闭。

**修法**

跨调用需要保留的文件，放到持久位置：
`$HOME` 下的目录、`/var/lib/...`、或仓库内的目录。
只有"同一次调用内会产生也会消费"的临时文件才放 `/tmp`。

**代码位置**

- `stages/windows/70-provision.ps1` 等生成中间产物时统一落在仓库的
  `.state/` 或 `downloads/` 目录
- `lib/linux/common.sh` 的阶段状态标记写在 `/var/lib/setup-wsl/`

---

## 6. npm 的全局配置目录 `/usr/etc` 默认不存在

**现象**

```bash
echo 'registry=https://registry.npmmirror.com' > /usr/etc/npmrc
# bash: /usr/etc/npmrc: No such file or directory
```

**真因**

Arch 上 npm 的全局配置路径是 `/usr/etc/npmrc`，
但 `/usr/etc` 这个目录**默认根本不存在**（它是 npm 按 prefix 推导出来的路径，
不是发行版预建的目录）。

**修法**

写之前先 `mkdir -p /usr/etc`。

**代码位置**

- `stages/linux/07-package-mirrors.sh`
- `tests/lint.sh` 有回归检查

---

## 7. `known_hosts` 由 root 创建后普通用户写不进去

**现象**

普通用户执行 ssh 时报：

```
Failed to add the host to the list of known hosts (/home/h/.ssh/known_hosts).
```

**真因**

安装脚本以 root 身份运行，`ssh-keyscan >> ~/.ssh/known_hosts`
创建出的文件属主是 `root:root`，权限 644。
之后普通用户 ssh 想往里追加主机指纹时被拒绝。
功能上"能用"，但每次都告警，而且主机指纹永远补不进去。

**修法**

凡是给用户使用的文件，创建后立即 `chown` 给该用户，并设定正确权限：

```bash
chown "$USER:$USER" "$known"; chmod 644 "$known"
```

`~/.ssh` 目录 700、私钥 600、config 600、公钥与 known_hosts 644。

**代码位置**

- `stages/linux/08-ssh.sh`

---

## 8. 整文件覆盖 `.wslconfig` 会丢掉用户已有设置

**现象**

（潜在问题）脚本写入 `.wslconfig` 后，用户自己配的
`memory`、`processors`、`networkingMode` 等设置全部消失。

**真因**

`.wslconfig` 是用户自己的配置文件，直接整文件覆盖是最省事但最不负责任的做法。

**修法**

做**段级合并**：定位到目标 `[section]`，只替换或插入目标键，
其余内容原样保留；改前留带时间戳的备份。

**代码位置**

- `lib/windows/common.ps1` 的 `Set-IniValue`
- `stages/windows/50-wslconfig.ps1`

---

## 9. 国内直连 GitHub：HTTPS 被重置、22 端口不通

**现象**

```
git clone https://github.com/...
fatal: unable to access '...': OpenSSL SSL_read: unexpected eof while reading
```

或 `git ls-remote https://...` 直接卡死；SSH 走 22 端口也常常连不上。

**真因**

GitHub 的 HTTPS 与 22 端口在国内经常被干扰或阻断。
但 **443 端口的 SSH（`ssh.github.com:443`）通常可用**，且 `api.github.com`
往往也能访问。

**修法**

1. 优先用 SSH 而不是 HTTPS 克隆。
2. 在 `~/.ssh/config` 里把 `github.com` 指向 `ssh.github.com:443`：

```
Host github.com
  HostName ssh.github.com
  Port 443
  User git
```

3. 需要读取远端引用时，把远端写成 SSH 形式再 `ls-remote`
   （很多工具默认用 HTTPS，需要显式指定）。

**代码位置**

- `stages/linux/08-ssh.sh`
- 排查方法：同一地址用 `curl` 通、用 `git` 不通 → 基本可以确定是协议层被干扰，
  而不是网络不通

---

## 10. `wsl.exe` 的输出是 UTF-16LE

**现象**

在 PowerShell 里捕获 `wsl.exe -l -v` 的输出，得到的是
`W S L   Hr,g:` 这种字符间夹空格、甚至混着 `\0` 的字符串。

**真因**

`wsl.exe` 属于 Windows 子系统组件，部分子命令输出 **UTF-16LE**，
而 PowerShell 默认按当前控制台编码解码。

**修法**

调用前临时切换输出编码，调用后还原：

```powershell
$prev = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode  # wsl.exe 自身输出
    ...
} finally { [Console]::OutputEncoding = $prev }
```

执行 **Linux 侧命令**时输出是 UTF-8，对应切成 `[System.Text.Encoding]::UTF8`。

**代码位置**

- `lib/windows/common.ps1` 的 `Invoke-WslCli`（Unicode）
  与 `Invoke-WslShell`（UTF8）

---

## 11. 官方 `.wsl` 镜像其实是 xz 压缩的 tar

**现象**

想检查镜像内容，用普通 `tar -tf` 可能失败；某些工具按扩展名判断会拒绝处理。

**真因**

`archlinux.wsl` 的前 6 个字节是 `FD 37 7A 58 5A 00`，即 **xz 魔数**。
它本质上是一个 **xz 压缩的 tar**，只是换了扩展名。
`wsl --import` 使用 libarchive，能直接吃这种格式。

**修法**

- 用 `wsl --import <名称> <目录> <镜像文件>` 导入，不要试图先手工解压。
- 需要检查内容时（Windows 自带 bsdtar 支持 xz）：
  `tar -tvf archlinux.wsl`

**代码位置**

- `stages/windows/30-fetch-image.ps1`、`40-import-distro.ps1`

---

## 12. 不能凭 `VirtualizationFirmwareEnabled=False` 判断 BIOS 没开虚拟化

**现象**

WMI 查询结果：

```
HypervisorPresent                   : True
VirtualizationFirmwareEnabled       : False
VMMonitorModeExtensions             : False
```

看起来像"BIOS 里没开虚拟化"，但 WSL2 其实能正常工作。

**真因**

`VirtualizationFirmwareEnabled` 反映的是**操作系统能否直接查询到固件层的虚拟化能力**。
当上层已经有一个 hypervisor 在运行时（例如 Windows 自带的
VBS / 内存完整性，`HypervisorPresent=True`），
这一层被遮蔽，该属性就会报 `False`。

**修法**

判断虚拟化是否可用，应优先看 `HypervisorPresent`：

```powershell
if ($cs.HypervisorPresent) { '可用（已有 hypervisor 在运行）' }
elseif ($cpu.VirtualizationFirmwareEnabled) { '可用（固件层）' }
else { '需要进 BIOS 开启' }
```

**代码位置**

- `stages/windows/00-preflight.ps1`

---

## 13. `\.wsl` 导入的发行版不会出现在开始菜单

**现象**

`wsl --import` 导入成功后，开始菜单里搜不到这个发行版。

**真因**

开始菜单快捷方式是 Store 版发行版安装流程的一部分，
手动 `--import` 只做注册，不创建任何 UI 入口。

**修法**

自己建一个 `.lnk`：
目标 `wsl.exe`，参数 `-d <发行版> --cd ~`，
图标用镜像导入时顺带落在发行版目录里的 `shortcut.ico`。

**代码位置**

- `stages/windows/60-shortcut.ps1`

---

## 14. `.cmd` / `.bat` 里不能有任何非 ASCII 字节

**现象**

批处理包装器执行时报出一串莫名其妙的错误：

```
'��（-ExecutionPolicy' is not recognized as an internal or external command
'��理员权限的阶段会自动检测并提示' is not recognized as an internal or external command
'.exe' is not recognized as an internal or external command
```

文件内容明明只是 `REM` 注释和几行命令。

**真因**

`cmd.exe` 解析 `.bat` / `.cmd` 时使用 **OEM 代码页**（中文系统上是 GBK），
而且**不认识 UTF-8 BOM**。中文注释被按 GBK 解读后变成乱码字节，
其中某些字节序列会被 cmd 当成命令分隔符，把一行注释切成了好几条"命令"。

加 BOM 也不行：BOM 会被当作第一个命令的一部分，直接报错。

**修法**

`.cmd` / `.bat` 保持**纯 ASCII**（英文注释与提示）。
所有面向用户的中文输出放到 `.ps1` 里，由 PowerShell 负责编码 ——
PowerShell 侧只要带 UTF-8 BOM 就没问题（见第 1 条）。

**代码位置**

- `bootstrap.cmd` —— 全文英文，文件头有醒目注释说明为什么必须这样
- `tests/lint-powershell.ps1` —— 检查所有 `.cmd` / `.bat` 不含非 ASCII 字节

---

## 15. `.wslconfig` 里的 Windows 路径必须写双反斜杠

**现象**

把交换文件配到 D 盘：

```ini
[wsl2]
swapFile=D:\WSL\swap.vhdx
```

**没有任何报错**，但交换文件跑到了 C 盘：

```
C:\Users\<用户>\AppData\Local\Temp\70607560-91AD-498D-AEF8-C116E4EEA9B0\swap.vhdx
```

而且原来在 D 盘的那份被删掉了。`swapon --show` 显示交换区正常工作，
所以从系统状态上完全看不出配置没生效。

**真因**

WSL 的 `.wslconfig` 解析器**会处理反斜杠转义序列**。
`D:\WSL\swap.vhdx` 里的 `\W` 和 `\s` 不是合法转义，
路径被吃掉后 WSL 拿不到合法值，就**静默回退到默认位置**
（`%LOCALAPPDATA%\Temp\<GUID>\swap.vhdx`），不报错、不告警。

正确写法是双反斜杠：

```ini
swapFile=D:\\WSL\\swap.vhdx
```

**怎么发现的**

这是"验证假设"而不是"假设正确"的典型收益 ——
本项目的脚本一开始写的是单反斜杠（看起来更自然），
真机测试时用 `wsl --shutdown` 重启后检查文件落点才发现不对。
**只检查 `.wslconfig` 的内容是发现不了这个问题的，
必须去看文件到底落在哪。**

**代码位置**

- `stages/windows/50-wslconfig.ps1` —— 写入前 `.Replace('\', '\\')`，
  并在注释里写明原因
- `tests/lint.sh` 有回归检查
- 验证方法：改完 `.wslconfig` 后 `wsl --shutdown`，
  启动发行版，确认目标盘上的 `swap.vhdx` 时间戳被更新，
  且 `%LOCALAPPDATA%\Temp` 下没有新的 `swap.vhdx`

---

## 16. `source` 一个带 `set -e` 的库会悄悄改变调用方的行为

**现象**

端到端验证脚本跑到一半就没了下文：

```
[STEP] 7. 开发工具
    gcc      gcc (GCC) 16.1.0
    ...
    vim      VIM - Vi IMproved 9.2
        ← 到此为止，既没有报错也没有结论
```

**真因**

`lib/linux/common.sh` 顶部有 `set -euo pipefail`。
在 bash 里 `source` 是在**当前 shell** 里逐行执行，
所以被 source 的脚本里的 `set -e` **会作用于调用方**。

验证脚本本意是"故意执行各种可能失败的命令、把问题收集完再报告"，
但被 `set -e` 管住之后，第一个非零退出就中止了 ——
`tmux --version` 恰好不被 tmux 支持，于是验证在它那里断掉。
断得还很安静：没有错误信息，因为并不是"出错"，而是"提前正常退出"。

**修法**

诊断类脚本在 source 之后**显式关掉** errexit：

```bash
set -uo pipefail
source ".../lib/linux/common.sh"
set +e          # 本脚本要容错收集问题，必须在 source 之后关掉
```

同时给可能失败的赋值加兜底：`ver="$("$tool" --version 2>&1 | head -1 || true)"`。

**更普遍的教训**

`source` 不是"导入函数"，是**在当前 shell 里执行代码**。
它带进来的不只是函数，还有变量、选项、陷阱（trap）。
库文件不要在顶层随意设全局选项；如果一定要设，
调用方必须在 source 之后按需复写。

**代码位置**

- `stages/linux/99-verify.sh` —— source 之后 `set +e`，注释写明原因
- `lib/linux/common.sh` —— `set -euo pipefail` 保留（对需要 fail-fast 的 01–08 阶段是对的），
  在文件头注明"会被引入调用方 shell"

---

## 17. 给 `Mandatory` 的字符串参数传空串会抛异常

**现象**

验证阶段打印出"全部验证通过"，紧接着整个阶段却报失败：

```
[12:18:14][OK] 全部验证通过
[12:18:14][ERROR] [90] 失败，退出码 1
```

日志里**没有任何错误信息**，输出到此为止。

**真因**

脚本里有一句 `Write-SetupLog -Message ''`（用来输出一个空行），
而函数的参数声明是：

```powershell
[Parameter(Mandatory = $true)][string]$Message
```

PowerShell 中 `Mandatory` 的 `string` 参数**默认拒绝空字符串**，
传入 `''` 会抛参数绑定异常。由于 `$ErrorActionPreference='Stop'`，
脚本当场终止 —— 于是"成功了吗？"这个问题的答案变成了"打印了成功，然后退出码 1"。

**修法**

给需要接受空串的参数加 `[AllowEmptyString()]`：

```powershell
[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
```

**教训**

"日志显示成功但退出码非 0"这类矛盾现象，几乎总是
**在打印成功之后、`exit` 之前还有语句崩了**。
排查时不要盯着成功信息，去看成功信息之后紧跟着什么。

**代码位置**

- `lib/windows/common.ps1` 的 `Write-SetupLog` 参数声明

---

## 18. 网络类检查必须有界重试，否则会误报失败

**现象**

端到端验证报"pacman 同步失败"，但**同一条命令手工执行完全正常**
（HTTP 200，0.15 秒）；而且前一次验证跑的时候还是通过的。

**真因**

镜像站偶发抖动（限流、瞬时丢包、连接被重置）是常态，
尤其在国内访问各类镜像时。把一次失败当成配置错误，会得到随机波动的验证结果 ——
这种"有时通过有时失败"的验证比没有验证更糟，因为它会让人不再相信验证结果。

**修法**

区分两类检查：

| 类型 | 处理 | 例子 |
|---|---|---|
| 事实检查 | 一次判定 | 文件权限、配置项是否存在 |
| 网络/外部检查 | **有界重试**（3 次、间隔数秒） | 同步软件源、拉取远端校验值 |

```bash
retry 3 3 "pacman 同步" timeout 90 pacman -Sy
```

**代码位置**

- `stages/linux/99-verify.sh` 的 `retry()`
- 类似地，`stages/windows/30-fetch-image.ps1` 对远端校验值失败给出告警而非直接失败

---

## 附：几条排查心法

1. **报错信息经常指错方向**。`Resolving timed out` 的真因是文件沙箱；
   `insufficient permissions` 的真因是目录空壳。
   看到反常的报错，先怀疑它，而不是顺着它查。
2. **同一个操作换条路径对比**。`curl` 通而 `pacman` 不通 → 问题在 pacman 而不在网络；
   `api.github.com` 通而 `git clone` 不通 → 问题在协议层而不在连通性。
3. **别把"命令执行过"当成"配置生效了"**。要验证就验证结果：
   源配好了要能拉到包，sudo 配好了要能被 `sudo -l` 认。
4. **临时文件要问清生命周期**。跨进程、跨虚拟机关闭的中间产物，
   永远不要放 `/tmp`。
