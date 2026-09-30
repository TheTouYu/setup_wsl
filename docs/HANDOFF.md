# 交接文档

> 面向**没有参与开发会话**的接手者（人或 Agent）。
> 读完这份 + [ARCHITECTURE.md](ARCHITECTURE.md) + [PITFALLS.md](PITFALLS.md)，
> 你应该能独立维护和继续开发这个仓库。

---

## 0. 一句话状态

`setup_wsl` v0.2.0 已发布（<https://github.com/TheTouYu/setup_wsl>），
Windows 侧阶段在**本机真机验证过**，Linux 侧 09/99 验证过，
**但「从全新机器 00→90 一次跑通」这条最关键的路径从未执行过** —— 这是接手后的第一优先级。

---

## 1. 本机环境事实

这些是开发时的实际环境。**换机器时不能假设一致**，但排查问题时这是基准。

| 项目 | 值 |
|---|---|
| 操作系统 | Windows 11 家庭中文版 Build **26300** |
| CPU | Intel Core Ultra X7 358H（16 核） |
| WSL | **3.0.1.0**，内核 `6.18.40.1-microsoft-standard-WSL2` |
| 发行版 | `archlinux`（**早先手工导入**，非本工具安装） |
| 发行版数据目录 | `D:\WSL\ArchLinux\ext4.vhdx`（约 3.25 GB） |
| 交换文件 | `D:\WSL\swap.vhdx` |
| Linux 用户 | `h` / 密码 `h`（**1 位，弱口令，已在文档中告警**） |
| 网络模式 | `mirrored`（`eth0` = 主机局域网 IP，如 `192.168.0.110`） |
| 主机代理 | Clash Verge（`verge-mihomo`）混合端口 `127.0.0.1:7897` |
| 实测最快镜像 | USTC 中科大 4.04 MB/s |
| DSH | `@deepseek-ai/dsh` **0.2.0-rc.2**，服务监听 `127.0.0.1:3080` |
| SSH 密钥指纹 | `SHA256:glzPF7oaPkIJOeOANOfjCMzJQONlpcTttNaJXfR2vZU` |

**重要**：Windows 侧**没有安装 git**，所有 git 操作都在 WSL 里做。

机器上还住着另外两个项目（与本仓库无关，但共用这台机器）：

- `~/projects/portable-knowledge` —— PKC 知识树引擎（已装全局技能）
- `~/projects/AI-Brand-Lab` —— 已接入 PKC 知识树

---

## 2. 仓库在哪、怎么开发

### 当前位置

```
WSL 内（git 仓库在这里）：  /home/h/projects/setup_wsl
Windows 暂存目录：          D:\WSL\setup_wsl-build
本次会话的临时脚本/日志：   D:\WSL\setup\ 、 D:\WSL\logs\
```

### 为什么有个"暂存目录"

开发本仓库时遇到一个工具限制：DSH 的写入工具用「临时文件 + 原子改名」落盘，
而 WSL 的 9p 文件系统**不支持**这种操作（报 `ENOTSUP`）。
于是采用：

```
在 D:\WSL\setup_wsl-build\ 编辑  →  rsync 同步进 WSL  →  在 WSL 里跑 lint / git
```

同步命令：

```bash
rsync -a --delete --exclude .git --exclude logs --exclude downloads --exclude .state \
    /mnt/d/WSL/setup_wsl-build/ /home/h/projects/setup_wsl/
```

**你的 Agent 环境不一定有同样的限制**。如果可以直接写 WSL 路径，就直接在
`/home/h/projects/setup_wsl` 里工作，跳过暂存步骤 —— 那样更简单。
**但要保证 `.ps1` 的 UTF-8 BOM 不被破坏**（见 AGENTS.md 硬约束）。

### 提交

```bash
cd /home/h/projects/setup_wsl
git add -A
git commit -m "..."
git push origin main          # 先跑完两侧 lint
```

仓库级 git 身份已配好（`TheTouYu <TheTouYu@users.noreply.github.com>`），
不影响全局配置。

---

## 3. 验证矩阵（诚实版）

**这是本文档最重要的一节。** 「跑过」和「没跑过」的界线必须清楚。

### Windows 侧阶段

| 阶段 | 状态 | 说明 |
|---|---|---|
| 00 环境体检 | ✅ **真机跑过** | Win11/虚拟化/WSL 版本/功能状态/磁盘/镜像连通性，全部正确 |
| 10 启用功能 | ⚠️ **只走过"已启用"分支** | 两个功能是早先手工启用的，本工具只验证了幂等跳过路径 |
| 20 装 WSL 本体 | ⚠️ **只走过"已就绪"分支** | WSL 是系统自动装的，真实安装路径未验证 |
| 30 获取镜像 | ✅ **真机跑过** | 111.9 MB / 8.68 MB/s；双站 SHA256 一致；重跑正确跳过 |
| 40 导入发行版 | ⚠️ **只走过"已注册"分支** | 发行版是早先手工 `wsl --import` 的，真实导入路径未验证 |
| 50 配 .wslconfig | ✅ **真机跑过** | swapFile 双反斜杠、networkingMode、autoProxy 布尔转换；段级合并不动用户设置 |
| 60 建快捷方式 | ⚠️ **本工具未跑过** | 快捷方式是手工建的 `Arch Linux.lnk`，工具只做过存在性检查 |
| 70 驱动 Linux 侧 | ❌ **从未跑过** | Linux 阶段是逐个手工执行的，编排逻辑（含密码文件传递）未验证 |
| 80 DSH 开机自启 | ✅ **真机跑过** | 启动项 VBS + 快捷方式 + 立即触发 |
| 90 端到端验证 | ✅ **真机跑过** | exit=0，Windows 侧 6 项 + Linux 侧 10 板块全绿 |

### Linux 侧阶段

| 阶段 | 状态 | 说明 |
|---|---|---|
| 01 密钥环 | ⚠️ **正式版未跑过** | 同会话的**一次性脚本**跑过并发现了"gnupg 空壳"问题 |
| 02 镜像源 | ⚠️ **正式版未跑过** | 一次性脚本跑过并发现了 pacman 沙箱 DNS 问题 |
| 03 系统更新 | ⚠️ **正式版未跑过** | 一次性脚本跑过（238 包） |
| 04 开发环境 | ⚠️ **正式版未跑过** | 一次性脚本跑过 |
| 05 用户 | ⚠️ **正式版未跑过** | 一次性脚本跑过 |
| 06 语言环境 | ⚠️ **正式版未跑过** | 一次性脚本跑过 |
| 07 语言包源 | ⚠️ **正式版未跑过** | 一次性脚本跑过并发现了 `/usr/etc` 不存在的问题 |
| 08 SSH | ⚠️ **正式版未跑过** | 一次性脚本跑过并发现了 known_hosts 属主问题 |
| 09 DSH | ✅ **正式版跑过** | 幂等分支 + 服务 active + 端口监听 + dsh-url |
| 99 验证 | ✅ **正式版跑过** | 经 90-verify 调用，全部通过 |

> **关键风险**：01–08 的**正式版本**（`stages/linux/*.sh`）是把同会话中
> 已实测通过的**一次性脚本**（`D:\WSL\setup\NN-*.sh`）改写而来的。
> 改写过程可能引入偏差，而正式版从未执行过。
> **接手后第一件事就是补上这个验证。**

### 从未验证过的场景

- 全新机器从零 00→90
- Windows 10
- 无代理环境（`DSH_PROXY=` 留空）
- 非 Arch 发行版（代码里没有分支，会直接失败）
- 磁盘空间不足、网络中断等异常路径
- `config/local.conf` 覆盖机制的实际效果（只用过默认值）

---

## 4. 关键决策与理由

这些决策看起来"绕"，但每条都有实测依据。**改之前先读理由。**

### 4.1 用 `wsl --import` 而不是 `wsl --install -d archlinux`

在线发行版列表的源站在国内常常不可达，而且 `--install` 默认装到 C 盘。
`--import` 让安装位置完全可控。镜像从官方镜像站下载，**双站 SHA256 交叉校验**
（单站的"文件+校验值同时坏"无法发现）。

### 4.2 `networkingMode=mirrored`

需求是「WSL 与主机共用网络」。NAT 模式下 WSL 是 `172.19.x.x` 独立子网，
它自己的 `127.0.0.1` **不是**主机的，所以主机代理 `127.0.0.1:7897` 够不到。
mirrored 模式下 WSL 的 `eth0` 直接持有主机局域网 IP，localhost 双向可达。

### 4.3 `autoProxy=false`

WSL 默认会把 Windows 系统代理**自动注入成 WSL 环境变量**。
实测后果：**所有**流量（包括 pacman 拉国内镜像）都被赶去走代理，
而代理访问国内镜像反而 SSL 失败。关掉后直连 USTC 只要 0.2 秒。

**设计原则：代理是按需的局部手段，不是全局默认。**
只有访问 GitHub/npmjs 这类国际源时才值得走代理，那些步骤会显式设置。

### 4.4 DSH 服务只设 `http_proxy`，不设 `all_proxy`

DSH 的 HTTP 客户端（Node 生态）**不认** `socks5://` 形式的 `all_proxy`，
会打印警告并直连。Clash 的混合端口（7897）本身就同时接受 HTTP 和 SOCKS5，
写成 `http://` 不损失任何能力。

### 4.5 自启用"启动文件夹 VBS"而不是"任务计划"

先按正统做法写的 `Register-ScheduledTask`，实测**非管理员直接 Access is denied**
（HRESULT 0x80070005）。启动文件夹方案永远可用，且用户 `shell:startup`
就能看到、删除。

### 4.6 开机自启是**两层**的

```
Windows 登录 → 启动文件夹 VBS 保活 WSL 虚拟机 → linger 拉起 dsh.service
```

WSL 虚拟机会在所有会话退出后十几秒被回收，**发行版内的 systemd/linger 拦不住**
（表现为服务 `Started→Stopped` 循环）。所以虚拟机本身必须由 Windows 侧保活。

### 4.7 Memory/配置写入一律幂等

- 配置文件：`sw_upsert_block`（bash）/ `Set-IniValue`（PowerShell），带 `# >>> setup-wsl >>>` 标记
- 装包：`pacman -S --needed` + 先查 `pacman -q`
- 下载：先算本地 SHA256 与远端比对

标记 `# >>> setup-wsl` 同时是**审计锚点**：想知道工具改过哪些文件，全仓 grep 它。

---

## 5. 维护手册

### 换代理端口

改 `config/local.conf`：

```ini
DSH_PROXY=http://127.0.0.1:8888
```

然后 `bootstrap.cmd -Only 09,80`（09 重写服务单元，80 重建启动项）。

### 换发行版

当前**只支持 Arch**。`stages/linux/` 里全是 pacman 语法。
要支持别的发行版，需要抽象包管理接口 —— 见 ARCHITECTURE.md 的扩展指南。

### 加一个新阶段

见 [ARCHITECTURE.md](ARCHITECTURE.md) 第 7 节「怎么加一个新阶段」。
要点：Linux 阶段按文件名自动发现（不用改编排器）；
Windows 阶段要在 `bootstrap.ps1` 的 `$allStages` 登记（`tests/lint.sh` 会检查漏登记）。

### 改 DSH 版本

```bash
wsl -d archlinux -u root -- bash -c 'npm install -g @deepseek-ai/dsh@<版本> --registry=https://registry.npmjs.org --allow-scripts=...'
```

`--allow-scripts` 那串**不能省**（npm 12+ 会拦截原生模块的安装脚本）。

### 关掉 DSH 自启

```ini
DSH_AUTOSTART=no
```

或直接删除 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\setup-wsl-dsh-keepalive.vbs`。

### 完全卸载发行版

```powershell
wsl --unregister archlinux          # 会删除所有数据
Remove-Item "$env:USERPROFILE\.wslconfig.bak-*"   # 可选：清理备份
```

---

## 6. 排查手册

完整版在 [PITFALLS.md](PITFALLS.md)（24 条，每条含现象/真因/修法/代码位置）。速查：

| 症状 | 真因 | 编号 |
|---|---|---|
| 所有镜像报 `Resolving timed out`，但 `curl` 正常 | pacman 7 下载沙箱挡住了 `/etc/resolv.conf` 符号链接 | 3 |
| `pacman-key` 报权限不足（明明是 root） | 镜像里的 gnupg 目录是空壳 | 4 |
| 日志说成功，退出码却是 1 | `Mandatory` 字符串参数拒绝空串 | 17 |
| 验证脚本跑到一半安静中止 | `source` 带 `set -e` 的库改变了调用方 | 16 |
| swap 文件跑回 C 盘 | `.wslconfig` 路径要双反斜杠 | 15 |
| WSL 报"不支持该值"并忽略配置 | `.wslconfig` 布尔只认 `true`/`false` | 24 |
| 服务 `Started→Stopped` 循环 | WSL 虚拟机被空闲回收，不是服务崩溃 | 22 |
| WSL 里连不上主机代理 | NAT 模式，`127.0.0.1` 不是主机的 | 19 |
| 国内镜像突然全挂 | `autoProxy` 把系统代理注入成全局变量 | 20 |
| 中文 `.ps1` 报奇怪的解析错误 | 文件缺 UTF-8 BOM | 1 |
| 批处理报一串"不是内部或外部命令" | `.cmd` 里有非 ASCII 字节 | 14 |

**通用心法**：

1. **报错信息经常指错方向** —— 看到反常的报错，先怀疑它
2. **换条路径对比** —— `curl` 通而 `pacman` 不通 → 问题在 pacman
3. **别把"命令执行过"当"配置生效了"** —— 要看结果（swap 文件实际落点、代理真能通）
4. **临时文件先问生命周期** —— 跨进程/跨虚拟机关闭的中间产物别放 `/tmp`

---

## 7. 方法论：本项目是怎么写出来的

理解这套方法，比读代码更重要。

**核心：先验证假设，再写代码；每一步都在真机上取证。**

典型例子（`.wslconfig` 的 swapFile 路径）：

1. 脚本里按"自然写法"写单反斜杠 `D:\WSL\swap.vhdx`
2. 不满足于"文件写进去了"，而是 `wsl --shutdown` 重启后**看文件实际落在哪**
3. 发现跑到了 `C:\...\Temp\<GUID>\swap.vhdx`
4. 定位真因（INI 转义），改成双反斜杠
5. 再重启验证文件回到 D 盘
6. 写进 PITFALLS 第 15 条
7. **加一条 lint 回归检查**，防止以后被"顺手清理"掉

结果是：24 条踩坑记录，其中**约 10 条是本项目自己的测试过程抓出来的**
（不是用户报的 bug，也不是文档抄的）。这就是为什么这个仓库的注释看起来啰嗦 ——
它们在解释"为什么不能写成更自然的样子"。

**接手后请延续这套做法**：
改脚本 → 真机跑 → 检查**生效**而非**执行** → 写记录 → 加回归检查。

---

## 8. 下一步建议（按优先级）

### P0 —— 补上最大的一块空白

**在本机跑一次 `bootstrap.cmd -Only 70`**，让 `70-provision.ps1` 编排器
真正执行一遍 Linux 阶段 01–08 的**正式版本**。

它们设计为幂等，在已配置好的机器上跑应该全部走"跳过"分支 ——
即便如此也能验证编排逻辑、密码传递、日志聚合、错误处理是否正常。
之后再找一台干净机器跑完整 00→90。

### P1 —— 补验证盲区

- Windows 10 兼容性（代码里有版本检查，但没实跑）
- 无代理环境（`DSH_PROXY=` 留空）
- 断网/磁盘不足等异常路径

### P2 —— 功能扩展

1. **多发行版支持** —— 抽象包管理接口（当前硬编码 pacman）
2. **迁移/卸载阶段** —— `wsl --manage --move` 迁盘、`--unregister` 干净卸载
3. **导出/导入备份** —— `wsl --export` 定期快照
4. **CI** —— GitHub Actions 跑两侧 lint（目前需手动跑）

### P3 —— 工程完善

- `tests/lint.sh` 里的 `shellcheck` 目前是"装了才跑"，CI 里应固定安装
- 没有自动化集成测试（验收需要干净 Windows，成本高）
- 尚未声明开源许可（`LICENSE` 缺失）

---

## 9. 本次会话产出的其他文件

别丢掉这些，它们记录了实际执行过的证据：

| 路径 | 内容 |
|---|---|
| `D:\WSL\setup\NN-*.sh` / `.ps1` | 会话中的**一次性验证脚本**（01–08 正式版的前身，就是实际跑通过的那些） |
| `D:\WSL\logs\*.log` / `*.txt` | 各步骤的真实输出（含失败现场） |
| `D:\WSL\README.md` | 第一阶段的 WSL 安装记录（PKC 接入前） |
| `~/projects/portable-knowledge` | PKC 知识树引擎，含 `docs/PITFALLS` 风格的经验沉淀 |

`D:\WSL\setup\` 里的一次性脚本**不要**直接删 —— 它们是"正式版应该等价于什么"的参考基准。

---

## 10. 快速上手清单

接手第一小时建议按顺序做：

```powershell
# 1. 确认工具能跑（只读，不改动任何东西）
cd D:\WSL\setup_wsl-build
bootstrap.cmd -Plan

# 2. 环境体检（只读）
bootstrap.cmd -Only 00

# 3. 端到端验证（只读 + 在发行版内跑验证脚本）
bootstrap.cmd -Only 90
```

```bash
# 4. 确认仓库与静态检查都健康
cd /home/h/projects/setup_wsl
git status && git log --oneline -3
bash tests/lint.sh
```

```powershell
# 5. Windows 侧静态检查
powershell -ExecutionPolicy Bypass -File D:\WSL\setup_wsl-build\tests\lint-powershell.ps1
```

```powershell
# 6. 确认 DSH 服务在跑
wsl -d archlinux -u h -- bash -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user status dsh --no-pager | head -5'
# 忘记访问地址时
wsl -d archlinux -u h -- dsh-url
```

全部正常 → 可以开始 **P0：`bootstrap.cmd -Only 70`**。
