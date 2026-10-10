# 目标机 AI 交接说明：OpenClaw 离线升级（2026.9.5 → 2026.9.9）

> **请先通读全文再动手。** 你是运行在**气隙 Windows 10 x64 目标机**上的 AI；本机**没有互联网**，本文自带全部背景，不要尝试联网查资料或下载任何东西。
> **术语**："气隙机（air-gapped host）"＝与互联网无任何链路、数据只能靠 U 盘搬运的机器。
> **注意**：这台机器**内网是可达的**（要访问局域网模型端点），所以"气隙"只代表外网不可达——不要据此认为内网命令（如 ping/HTTP 到内网地址）也会失败。
> 本文配套 `UPGRADE.md`（同一 U 盘包内也会带一份），里面有每一条结论的官方文档出处。

---

## 1. 来龙去脉（背景）

**这套 OpenClaw 不是联网安装的，是从 U 盘上的离线包安装的。**

| | 构建侧 | 目标机（你所在的这台） |
| --- | --- | --- |
| 作用 | 联网打包，产出离线升级包 | 从 U 盘拷贝后本地安装/升级 |
| 网络 | 可访问 npm / GitHub | **完全无外网**，仅内网可达 |
| 权限 | 无特殊要求 | **普通用户，无管理员权限** |

**目标机现状**（安装脚本 `Install-OpenClawOffline.ps1` 的既有产物，已稳定使用一段时间）：

| 项 | 值 |
| --- | --- |
| OpenClaw 版本 | **2026.9.5**（`openclaw --version` 会显示 `2026.9.5 (ec9c1a1)` 之类） |
| 安装位置 | `C:\OpenClaw\app`（**这是一个被拷贝过来的 npm 全局 prefix**，里面 `node_modules\openclaw` + `openclaw.cmd` 启动器） |
| CLI 入口 | `openclaw`（用户级 PATH 中指向 `C:\OpenClaw\app`；若命令找不到，用绝对路径 `C:\OpenClaw\app\openclaw.cmd`） |
| Gateway | 以**用户级计划任务**常驻，任务名 `OpenClaw Gateway`，端口 `18789`，地址 `ws://127.0.0.1:18789` |
| 配置与状态 | `%USERPROFILE%\.openclaw`（`openclaw.json`、凭据、会话、SQLite 数据库、日志、备份环） |
| 文档 | `C:\OpenClaw\docs`（离线文档，`docs_map.md` 是索引；**`openclaw docs` 走线上、离线不可用**） |
| Node | 由 **nvm-windows** 提供，当前应为 **26.7.0** |
| 界面 | 浏览器 Control UI（`http://127.0.0.1:18789`）。**本包不含桌面客户端，也不含 WebView2**，不要去找 Companion/Hub |

**这次要做什么**：把 OpenClaw 从 **2026.9.5 升到 2026.9.9**，通道 `stable`，走**官方 updater** 并以**本地 tarball** 为升级目标。

---

## 2. 三个必须先知道的结论（决定你后面怎么做）

### 2.1 官方 updater 可以用本地 tarball，但官方**没有**离线模式

- 官方文档明确把"显式 artifact（tarball 路径）"与注册表目标视为同一条升级流程：`openclaw update --tag <路径>\openclaw-2026.9.9.tgz`。
- 但官方**没有** `--offline` 参数、没有气隙流程。openclaw 的 tarball **不自带全部依赖**（9.9 的 tarball 只含 3 个包，而 `package.json` 声明 66 个依赖）。
- 所以离线能否成功 = **随包带的 npm 缓存全不全** + **npm 是否只走缓存**。升级包里会带一份预热好的 `npm-cache\`，执行时用环境变量把 npm 指过去（见 §5）。

### 2.2 updater 要求这个安装"有主"（owner 判定）

updater 会从 **npm 配置的全局 prefix + 已安装启动器** 推断这个 OpenClaw 安装是否归它管。我们这份是 robocopy 来的 prefix，默认 npm 的全局 prefix 在别处，**可能被判成"异地/无主"而拒绝升级**（官方此时的措辞类似 `global-install-foreign-destination` 或 `no detected package-manager owner`，并且**不会**改动任何东西）。
已知的官方解法是让 npm 的全局 prefix 指向这棵树：`$env:NPM_CONFIG_PREFIX = 'C:\OpenClaw\app'`。
**这一点只能在真机验证**——这正是第一阶段诊断要回答的问题之一。

### 2.3 这次升级**跨数据库 schema 迁移**，所以回滚只有一条路

已在真实 2026.9.5 / 2026.9.9 包上实测：

| 观测 | 结果 |
| --- | --- |
| 9.5 声明 schema | `state 17 / agent 21` |
| 9.9 声明 schema | `state 19 / agent 24` |
| 9.5 建的 state 库 | `PRAGMA user_version = 17` |
| 用 9.9 打开同一状态目录后 | 变成 `19`（迁移已发生，且不可逆） |
| 之后再用 9.5 打开 | **被拒绝**：`uses newer schema version 19; this build supports 17`，并提示 *restore your pre-update backup created with `openclaw backup create`* |

**推论（很重要）**：
1. 升级后**"只把旧版本换回来"是救不回来的**——9.5 会拒绝启动。官方自动回滚也不适用。
2. **回滚的唯一路径 = 恢复升级前用 `openclaw backup create` 做的归档**，所以那步必须成功、必须 `--verify` 通过、归档必须放在 `%USERPROFILE%\.openclaw` **之外**（建议 `C:\Backups`，最好再拷一份到 U 盘）。
3. 升级包里那份"完整 9.9 整树"只用于**修复/重装**，**不是回滚手段**。

---

## 3. 安全红线（违反其中任何一条都可能弄坏这台机器）

1. **不要用管理员权限做任何事**（本机也没有管理员）。不要改系统 PATH、不要写 `HKLM`。
2. **不要删除、不要手工编辑 `%USERPROFILE%\.openclaw`**。不要直接改 SQLite、不要动 `user_version` / `schema_meta.schema_version`。
3. **绝对不要运行**：`openclaw reset`、`openclaw uninstall`、`openclaw update cleanup`（cleanup 会永久放弃回滚原件）。
4. **任何"替换文件/升级"动作之前，先停 Gateway 并确认它已经退出**（9.5 没有"安装被替换"监听器，边跑边换文件会失败或半死不活）。
5. **严格按本文顺序执行**；某一步输出与"期望"不符就**停下来、把输出记进日志**，不要自行发挥去"修好它"。
6. **不要执行本文没有列出的修复/清理命令**；不要尝试任何需要网络的命令（如果某条命令卡在等待网络，说明用法错了，停下并记录）。
7. Shell 是 **Windows PowerShell 5.1**：不要用 `Join-Path` 三参数、`??`、`?.`、`Get-Error`、`$IsWindows` 等 PS 6/7 语法；本机也不要依赖 `curl.exe` 之外的联网工具。

---

## 4. 第一阶段任务：只做诊断，**不改动任何东西**（现在就能做，不需要新 U 盘包）

目的：把升级要用到的事实**在本机核实并存档**。这台机器与构建侧之间没有回传通道（公司内网、U 盘单向），
所以**不要等任何外部确认**——结论写进本机文件 `RECON.txt`（放在你自己的工作目录，例如 `C:\Backups\`），
后续判定全部由第 5 节的脚本闸门给出。

逐条执行，把命令与完整输出（含退出码）原样追加到 `RECON.txt`：

| # | 命令 | 想确认什么 |
| --- | --- | --- |
| D1 | `$PSVersionTable.PSVersion` | 是否 5.1 |
| D2 | `openclaw --version` | 现装版本（期望 2026.9.5） |
| D3 | `node -v` ; `npm -v` ; `npm prefix -g` | Node/npm 版本 + npm 的全局 prefix（决定 owner 判定） |
| D4 | `(Get-Content 'C:\OpenClaw\app\node_modules\openclaw\package.json' -Raw \| ConvertFrom-Json).openclaw` | 现装包声明的 schema（期望 `state 17 / agent 21`） |
| D5 | `Get-ScheduledTask -TaskName 'OpenClaw*' \| Select-Object TaskName,State` | 计划任务是否存在、叫什么、是否在运行 |
| D6 | `openclaw update status --json` | updater 认不认这个安装（Install kind / Channel / 是否报 owner 或 registry 错误） |
| D7 | `openclaw config get update` | 现在 `checkOnStart` 是什么值（期望未设置=true） |
| D8 | `Get-PSDrive C \| Select-Object Used,Free` | C 盘余量（升级峰值约需 1.5 GB） |
| D9 | `Get-ChildItem "$env:USERPROFILE\.openclaw" -Recurse -Filter *.sqlite \| Select-Object FullName,Length` | 状态库 / agent 库位置与大小 |
| D10 | `Get-Process node -ErrorAction SilentlyContinue \| Select-Object Id,Path` | 当前有哪些 node 进程（后面停服要用作对照） |
| D11 | `openclaw gateway status --json` | 服务与探测状态（只读） |

补充要求：
- D6/D7 很可能因为**无外网**而报错或超时，**那是预期**——把原文与退出码照样存档，注明"是否等了很久"。
- 如果某条命令报"不是内部或外部命令"或参数不存在，也照抄，注明。
- **本阶段不要运行 `openclaw update`（不带 `--dry-run` 的那种）**，也不要停服务。

**存档格式**（`RECON.txt`，给现场和下一次升级用，不是给别人回传的）：
```
D1: <命令>
输出:
<原样粘贴>
退出码: <n>
...
结论串（一行一个，不要推测）:
- 现装版本:
- Node/npm 版本:
- npm prefix -g:
- 计划任务名与状态:
- update.checkOnStart:
- C 盘可用空间:
- openclaw update status 是否认这个安装:
- 任何与本文"期望"不符之处:
```

**自决规则**：上面每条都是只读的，不需要请示。存档完成后直接进入第 5 节；第 5 节的 `-DryRun` 会给出
"能不能走官方升级"的结论，你按第 6 节的表处置即可。

---

## 5. 第二阶段任务：拿到新的升级 U 盘包后执行升级

> 前置：第 4 节已存档（不需要外部确认）。**先跑 `-DryRun`**，它零副作用且会给出放行结论。

### 5.1 包内容与准备

升级包目录（示例：`E:\openclaw-offline-bundle\`）是**自包含**的——脚本就在包里，双击即可：

```
bundle-manifest.json      ← 先读：mode / openClawVersion / packagedTarball / tarballSha256 / schemaVersions / nativePackages
openclaw-2026.9.9.tgz     ← 升级目标（文件名与父目录都不能含逗号）
npm-cache\                ← 预热好的 npm 缓存（含 9.9 全部传递依赖）
app\                      ← 仅 mode=app 时存在：完整 9.9 整树（救援/重装用）
docs\                     ← 包内文档 + OFFLINE-CAPABILITIES.md（能力边界，建议先读）
UPGRADE.md  UPGRADE-BRIEF.md  install.cmd  Upgrade-OpenClawOffline.ps1  upgrade.cmd
```

准备：
1. `Get-Content .\bundle-manifest.json -Raw | ConvertFrom-Json` 看 `mode`、`openClawVersion`、`packagedTarball`、`tarballSha256`、`schemaVersions`。
2. 核对 tarball 哈希：`Get-FileHash .\openclaw-<版本>.tgz -Algorithm SHA256`（与 manifest 的 `tarballSha256` 一致）。
3. `Get-ChildItem -Recurse | Unblock-File`（U 盘文件带 MOTW，不解除会执行失败）。
4. 读 `docs\OFFLINE-CAPABILITIES.md`（离线能力边界）与本文。

### 5.2 执行顺序

**推荐走脚本**：在包目录里双击 `upgrade.cmd`（破坏性步骤前会要求输入 `YES`），或：

```powershell
# 先预演 —— 零副作用：不备份、不停服、不改动任何东西
.\Upgrade-OpenClawOffline.ps1 -DryRun

# 预演通过后再正式执行
.\Upgrade-OpenClawOffline.ps1
```

脚本自己按顺序完成：校验 bundle/artifact → 比对版本与 schema → 备份（`backup create --verify`）→
停 Gateway 并等它退出 → 官方 `update --dry-run` 闸门 → 应用 → `gateway install --force` →
`gateway restart` → `doctor --post-upgrade` 验证 → 打印回滚命令。

**手动等价步骤**（脚本不可用时照此执行，顺序与脚本一致）：

```powershell
# (0) 起点
openclaw --version
openclaw update status --json

# (1) 备份 —— 这是本次升级唯一的回滚路径，必须成功
New-Item -ItemType Directory -Force -Path C:\Backups\openclaw | Out-Null
openclaw backup create --output C:\Backups\openclaw --verify
#    ⚠ 目录必须先存在：--output 指向【已存在目录】→ 在里面生成带时间戳的 .tar.gz（官方配方就是这样）；
#      若该路径不存在，它会被当成【归档文件本身】，生成一个没有扩展名的文件（实测确认）。
#    ⚠ 已存在的归档不会被覆盖；输出路径不能落在状态目录/工作区树内（会被拒绝）。
#    记下归档文件名与大小；再拷一份到 U 盘（U 盘上另建目录，不要覆盖原文件）

# (2) 停 Gateway 并等它完全退出（9.5 第一跳的硬性要求）
openclaw gateway stop            # 若报错，再试 openclaw gateway stop --force
#    对照 D10：确认没有仍指向 C:\OpenClaw\app 的 node 进程
Get-Process node -ErrorAction SilentlyContinue | Select-Object Id,Path
Get-ScheduledTask -TaskName 'OpenClaw*' | Select-Object TaskName,State

# (3) 闸门：确认 owner 判定与 tarball 解析（依赖只走随包缓存，不出网）
$env:NPM_CONFIG_PREFIX  = 'C:\OpenClaw\app'
$env:npm_config_cache   = 'E:\openclaw-offline-bundle\npm-cache'
$env:npm_config_offline = 'true'
openclaw update --dry-run --yes --no-restart --tag 'E:\openclaw-offline-bundle\openclaw-2026.9.9.tgz'

# (4) 正式升级（不加 --no-restart，让 updater 自己处理重启阶段）
openclaw update --yes --tag 'E:\openclaw-offline-bundle\openclaw-2026.9.9.tgz'

# (5) Windows 收尾（官方要求：重建计划任务 launcher）
openclaw gateway install --force
openclaw gateway restart
openclaw --version                      # 期望 2026.9.9
openclaw doctor --post-upgrade
openclaw health
openclaw gateway status --deep --json
openclaw doctor --lint --json
```

**第 (3) 步的期望**：输出一份"计划"（写明 `Tag/spec` 指向那个 tarball、要跑包管理器更新、跳过重启），
并且**不出现** owner / registry 相关错误。
**第 (3) 步是唯一判定点**：若报 `global-install-foreign-destination` 或"没有检测到包管理器 owner"，
**不要执行第 (4) 步** —— 先把 Gateway 起回来，然后按 §6 用 `-RescueTree` 处置。

**两种包模式**（`manifest.mode`）：`app` = 整树在包内（安装脚本 robocopy + 计数校验）；`npmcache` =
只有 cache + tarball，目标机自己跑离线安装。脚本按 manifest 自动处理，不需要你选。

### 5.3 记录格式（本地存档，不回传）

把每一步的命令与输出追加到 `C:\Backups\openclaw\UPGRADE-<日期>.log`，供现场复核与下次升级对照。
必须包含：

```
- 备份归档: <路径> <大小> <verify 结果>
- 第(3)步 dry-run 是否通过: <是/否 + 关键输出行>
- 第(4)步 update 的输出与退出码
- 升级后 openclaw --version / update status --json
- state 库 user_version 变化: <17 -> ?>
- doctor --post-upgrade / doctor --lint --json 结论
- 计划任务状态与 gateway status --deep 结论
- 任何非 0 退出码与错误码
- Control UI 是否可打开: <http://127.0.0.1:18789>
```

---

## 6. 失败分支（自行按表处置，不要硬闯）

| 现象 | 含义 | 处置 |
| --- | --- | --- |
| dry-run 报 `global-install-foreign-destination` / 无 owner | prefix 归属不匹配 | 重新 `openclaw gateway start`；改用 `.\Upgrade-OpenClawOffline.ps1 -RescueTree`（用包内整树替换），并在日志里记下原因 |
| `ENOTCACHED` / 依赖解析失败 | npm 缓存不全，或有别的 registry 配置在干扰 | **不要改 registry**（会让缓存键失配）；改用 `-RescueTree`，并记录"cache 不全" |
| 升级中止在 recovery pending | 9.5 旧驱动交接未完成 | `openclaw update repair --yes --json`，再重跑升级脚本 |
| 重命名失败 `EPERM`/`EBUSY`/`EACCES` | 有进程占用文件 | 确认 Gateway 确实停了（D10 对照）；updater 自身会重试约 58 秒，仍失败则停服后重试 |
| 启动报 `newer schema version` / 退出码 78 | 磁盘 schema 比当前构建新 | 属预期现象（见 §2.3）；用 `openclaw backup restore` 恢复升级前归档 |
| 升级后想回退到 9.5 | 已跨 schema 迁移 | **换回旧整树无效**；唯一路径：`openclaw backup restore <归档> --target <空目录>`，再按官方流程切换状态目录、跑 doctor、启动 |
| 服务指向旧路径 | Windows 上 updater 不会重绑服务定义 | `openclaw gateway install --force` |

**恢复（restore）注意**：`openclaw backup restore` **从不就地恢复**，目标必须是空目录/不存在；恢复后需要停 Gateway、把状态目录切换到恢复出来的那份、先跑 `openclaw doctor`，再启动。走到这一步前，**先在日志里记下当前状态、拟恢复的归档路径与原因**，再动作。

---

## 7. 术语速查

| 词 | 含义 |
| --- | --- |
| Gateway | 常驻的本地服务（本机是计划任务），端口 18789 |
| state 目录 | `%USERPROFILE%\.openclaw`，配置/凭据/会话/SQLite/日志都在这里 |
| schema / `user_version` | SQLite 数据库结构版本；9.5 是 17，9.9 是 19，迁移单向 |
| owner / prefix | 包的"归属"判定：npm 全局 prefix 与启动器是否指向同一棵树 |
| tarball | 升级目标文件 `openclaw-2026.9.9.tgz`（npm 包归档） |
| npm cache | 依赖包的本地缓存；离线升级靠它，不需要外网 |

---

## 8. 一句话总结你的任务

**先做 §4 的只读诊断并存档到本机 `RECON.txt`（不需要请示）；然后按 §5 先跑 `-DryRun` 拿到放行结论，
再正式升级。升级前必须完成并验证备份——本次跨 schema 迁移，备份是唯一回滚路径。出错时按 §6 表自行处置
（首选 `-RescueTree`），并把全过程记进本机日志。**
