# OpenClaw 离线升级方案

**适用范围**：`openclaw-offline` 这个包在气隙 Win10 x64 目标机上的**版本升级**（本次：`2026.9.5 → 2026.9.9`）。
**本文性质**：设计文档。结论优先依据 openclaw 官方文档；官方未定义的部分单独标注为"工程补充"，未经实机验证的标注为"待验证"。
**术语**：气隙机（air-gapped host）＝与互联网无任何链路、数据只能靠 U 盘搬运的机器；本项目目标机**内网可达**，所以"气隙"只否决"安装时回源"的设计，不否决局域网内访问（见 [README §2.3](../README.md#23-网络)）。

标注约定：

| 标记 | 含义 |
| --- | --- |
| `[文档]` | 出自 openclaw@2026.9.9 包内 `package/docs/**` 或 `package/CHANGELOG.md`，附 `文件:行` |
| `[实测]` | 本仓库在 macOS 上用真实 `openclaw@2026.9.5` / `2026.9.9` 包做的等价验证 |
| `[工程补充]` | 官方文档没有定义、由本仓库补上的动作 |
| `[待验证]` | 必须在真机上确认后才能当结论用的点 |

---

## 1. 结论摘要

1. **主路径用官方 updater，升级目标用本地 tarball**：`openclaw update --tag <bundle>\openclaw-<ver>.tgz`。官方明确把"显式 artifact（tarball 路径）"与注册表目标视为同一条流程 `[文档]` `docs/cli/update.md:202`，且非注册表 spec 会跳过 npm 版本查询（`[实测]` dry-run 输出 *"Non-registry package specs skip npm version lookup"`）。
2. **官方没有离线模式**：没有 `--offline` 参数、没有气隙流程、没有本地 registry 指南 `[文档]`（子代理逐条检索未找到）。tarball 也不自带全部依赖——9.9 的 tarball 只含 3 个包（`@openclaw/proxyline`、`chrome-devtools-mcp`、`undici`），而 `package.json` 声明 66 个依赖 `[实测]`。**所以离线可行性 = 随包带一份为新版本预热的 npm cache，并让 npm 走缓存。**
3. **前提是安装"有主"**：updater 要求能从 npm 配置的 prefix + 已安装启动器推断出 owner `[文档]` `docs/cli/update.md:20-24`；否则记录为 **skipped**、退出 0、不升级 `[文档]` `docs/cli/update.md:33-37`。我们现在的 `C:\OpenClaw\app` 是 robocopy 过来的全局 prefix，默认情况下 npm 的全局 prefix 指向别处 —— `[实测]` 在 macOS 上撞到 `global-install-foreign-destination`；用 `NPM_CONFIG_PREFIX` 对齐到该树后 dry-run 立即通过。
4. **本次升级的一个硬性顺序**：目标机是 2026.9.5，而"9.5 的 Gateway 没有安装替换监听器"，第一跳必须**先停 Gateway 并等它退出**，再 update，再启动 `[文档]` `docs/cli/update/how-updates-run.md:848-852`。
5. **升级前必须有恢复点，而且这次是唯一回滚路径**：`update` 自带的只是"升级前配置副本"，不是全量恢复点 `[文档]` `docs/install/updating/rollback-and-recovery.md:276-277`；DB/config 迁移是单向的 `[文档]` `docs/reference/database-schemas/integrity-and-recovery.md:516`。
6. **本次升级确认跨数据库 schema 迁移（已实证）**：9.5 声明 `state 17 / agent 21`，9.9 声明 `state 19 / agent 24`；9.5 建的 state 库 `user_version=17`，被 9.9 打开后变 `19`，随后 9.5 **拒绝打开**该库。**所以升级后"换回旧包"救不回来**，官方自动回滚也不适用，回滚 = 恢复升级前的 `backup create` 归档。详见 §2.8。
7. **顺手要关掉自动出网检查**：`update.checkOnStart` 默认 `true`，Gateway 每次启动 + 每 24h 请求 `https://telemetry.openclaw.ai/api/latest-version` `[文档]` `docs/gateway/config-runtime.md:140`；气隙机上应设 `false`（或 `OPENCLAW_NO_AUTO_UPDATE=1`）。
8. **本次不需动 Node**：9.5 与 9.9 的 engines 完全相同 `>=24.16.0 <25 || >=26.1.0`，下限是 2026.9.3 引入的 `[文档]` `docs/install/node-compatibility.md:21,89`；目标机 nvm 的 26.7.0 继续有效。

---

## 2. 官方升级机制（事实与出处）

### 2.1 命令面

```
openclaw update [--tag <dist-tag|version|spec>] [--channel stable|extended-stable|beta|dev]
                [--dry-run] [--no-restart] [--yes] [--json] [--timeout <s>]
                [--admission auto|installed] [--accept-capabilities] [--reapply-local-overrides]
openclaw update status [--json] [--timeout <s>]
openclaw update repair [--channel <c>] [--yes] [--json] [--no-restart]
openclaw update cleanup [--dry-run] [--yes] [--json]
openclaw update wizard [--timeout <s>]
openclaw --update          # 等价于 openclaw update
```

- 命令面与参数表：`[文档]` `docs/cli/update.md:46-62`、`379-390`；`--update` 等价别名：`docs/cli/update.md:64-65`。
- 阶段：requested → staging → validating → activating → restarting → verifying → finished；**只有 activating 会停托管服务** `[文档]` `docs/cli/update.md:398-401`、`docs/cli/update/how-updates-run.md:430`。
- npm 安装的落地方式：先 stage 到临时 prefix，再把干净的包树 swap 进真实全局 prefix `[文档]` `docs/cli/update/how-updates-run.md:1088-1096`。
- **没有** `update history`、**没有** `update rollback` 子命令；历史查 `update status --json` 的 `activeRun`/`lastRun` `[文档]` `docs/cli/update/status-and-history.md:123-124`。

### 2.2 本地 artifact 是官方认可的升级目标

| 事实 | 出处 |
| --- | --- |
| "Registry targets and explicit artifacts such as `--tag ./openclaw.tgz` use the same flow." | `[文档]` `docs/cli/update.md:202` |
| 显式 artifact（tarball 路径/URL）即使版本相同也会被校验并安装 | `[文档]` `docs/install/updating.md:314-316`、`docs/cli/update/how-updates-run.md:96` |
| npm 12 下本地 `.tgz` 的**文件名与父目录都不能含逗号**；相对路径仍支持 | `[文档]` `docs/install/installer.md:23`、`docs/install/updating/update-methods.md:367-368` |
| 包 spec 形态示例：`--tag openclaw@2026.4.1-beta.1` | `[文档]` `docs/install/development-channels.md:82-96` |
| 官方**未**定义 `file:` 形式、未定义离线模式 | 子代理检索结论（包内文档无对应条目） |

### 2.3 "有主"是硬前提

- owner 由 **npm 配置的 prefix + 已安装启动器**推断；自定义 prefix（如 `~/.npm-global`）受支持 `[文档]` `docs/cli/update.md:20-24`。
- prefix 配置不一致时的官方兜底写法：`NPM_CONFIG_PREFIX="$(npm prefix -g)" openclaw update` `[文档]` `docs/cli/update.md:29-31`。
- **无主 = 不升级**：记录 skipped、退出 0、Gateway 继续跑，提示"用原始方法重装" `[文档]` `docs/cli/update.md:33-37`。
- `[实测]` 在 macOS 上把 CLI 装进 `/tmp/oc95`、而 npm 全局 prefix 仍是 `~/.local` 时，实际升级被拒：
  `global-install-foreign-destination — Selected npm destination … is occupied by another OpenClaw installation… No installation was attempted.`
  把 `NPM_CONFIG_PREFIX` 对齐到该树后，同一命令 `--dry-run` 输出计划：`Tag/spec: …`、`Run global package manager update with spec …`。

### 2.4 失败是非破坏性的

- "a refusal or pre-mutation failure … leaves the installed package and serving Gateway in place." `[文档]` `docs/cli/update.md:204-205`；同类表述另见 `how-updates-run.md:418`、`update-methods.md:17`、`install/updating.md:272-273`。
- Windows 文件占用：对 `EPERM`/`EBUSY`/`EACCES` 重试 16 次、最多约 57.75s；仍失败则报错并**保留**原安装 `[文档]` `docs/cli/update.md:190-196`。

### 2.5 2026.9.5 专属约束（正对本次升级）

| 约束 | 出处 |
| --- | --- |
| 9.5 的 Gateway 没有 installation-replacement watcher；第一跳必须由前台进程所有者停掉 Gateway、等它退出，再 update，再启动 | `[文档]` `docs/cli/update/how-updates-run.md:848-852` |
| Windows 上计划任务自启动会挂起到候选 finalizer 激活为止；旧驱动停在 recovery pending 时用 `openclaw update repair` | `[文档]` `docs/cli/update/how-updates-run.md:495-501` |
| 9.5 resident 保留旧启动预算，第一次停走"短/未知预算"路径 | `[文档]` `docs/cli/update/how-updates-run.md:68-70` |
| 第一跳受旧驱动 settlement 检查限制 | `[文档]` `docs/install/updating/rollback-and-recovery.md:247-248` |

### 2.6 服务（用户级计划任务）

- `openclaw daemon …` 与 `openclaw gateway …` 是同一套服务控制命令 `[文档]` `docs/cli/daemon.md:11`。
- **升级后的官方动作**：`openclaw gateway install --force` 重新生成 launcher/任务 `[文档]` `docs/platforms/windows.md:170-171`、`docs/gateway/doctor/gateway-and-services.md:210`。
- 但 Windows 上 updater **不会**重绑服务定义（`--no-restart` 也不会）`[文档]` `docs/install/node.md:82-88` → 必须显式执行上一条。
- 重启用 `gateway restart`，不要 stop+start 串联 `[文档]` `docs/cli/gateway/service.md:220`；重启成功需通过监听检查（最长 3 分钟），否则 `gateway restart --force` `[文档]` `docs/cli/gateway/restart-and-supervision.md:95-103`。
- Windows 任务名 `OpenClaw Gateway` / `OpenClaw Gateway (<profile>)`；任务被拒时回退到"用户启动文件夹"登录项（仍然无需管理员）`[文档]` `docs/platforms/windows.md:156-159`、`docs/gateway/index.md:299-300`。
- 停止：`schtasks /end /tn "OpenClaw Gateway"` 或 `Stop-ScheduledTask` `[文档]` `docs/platforms/windows.md:168-170`。

### 2.7 配置与状态迁移归 Doctor，不归安装

- "Plugin-registry and operator-state migration belong to Doctor, not package installation." `[文档]` `docs/install/updating/update-methods.md:420-422`。
- 启动**不**改写旧配置键，只打印 `openclaw doctor --fix` 提示 `[文档]` `docs/gateway/doctor/config-migrations.md:296`；普通 doctor（含 `--non-interactive`）可自动规范化旧的单文件配置 `[文档]` `:292`。
- 改写前保留 `openclaw.json.bak` / `.bak.1`…`.bak.4` 五槽备份环 `[文档]` `:296`。
- **迁移窗口约 2 个月**；更老的键已无迁移路径、直接校验失败；官方对"更老安装"的建议是**先升到 2026.9.5 并跑其 Doctor 迁移，再装最新版** `[文档]` `docs/gateway/doctor/config-migrations.md:316-341`。→ 我们正处在 9.5，这一步天然满足。
- 升级后专用检查：`openclaw doctor --post-upgrade`（可配 `--fix`）`[文档]` `docs/cli/doctor/running.md:226-243`。

### 2.8 数据库与 schema

- 前向迁移单向；启动遇到更新 schema 会**退出码 78**；`openclaw update` 也会拒绝"声明 schema 支持比磁盘数据库更旧"的目标 `[文档]` `docs/reference/database-schemas/versioning.md:17,19`。
- 迁移不可逆，且"降级包不会回退已迁移的状态" `[文档]` `docs/reference/database-schemas/integrity-and-recovery.md:516`。
- 升级/回滚前的推荐动作：由 supervisor 生成**无 sidecar 的 WAL 一致快照**，再用目标版本的 `openclaw database preflight <snapshot> --json` 判定（`exact` / `startup-repairable` / `migration-required` / `incompatible` / `indeterminate`）`[文档]` `docs/cli/gateway/restart-and-supervision.md:178`、`docs/reference/database-schemas/storage-changes.md:2016-2051`。
- 不要只拷主 `.sqlite`（WAL）`[文档]` `docs/install/updating/rollback-and-recovery.md:78-81`；不要手改 `user_version` / `schema_meta.schema_version` `[文档]` `docs/reference/database-schemas/integrity-and-recovery.md:580-582`。

**本次升级（9.5 → 9.9）已实证跨 schema 迁移** `[实测]`：

| 观测 | 结果 |
| --- | --- |
| 9.5 包内 `openclaw.schemaVersions` | `{ state: 17, agent: 21 }` |
| 9.9 包内 `openclaw.schemaVersions` | `{ state: 19, agent: 24 }` |
| 9.5 建库后 state 库 `PRAGMA user_version` | `17` |
| 用 9.9 打开同一状态目录后 | `19`（迁移已发生） |
| 再用 9.5 打开 | 被拒：`uses newer schema version 19; this build supports 17`，并提示 `To use an older build, restore your pre-update backup created with openclaw backup create.`（CLI 退出码 1；doctor JSON 退出码 2） |

结论：**升级后旧包无法启动**，`openclaw update --tag 2026.9.5` 这类降级同样会被 updater 拒绝（目标声明的 schema 支持比磁盘库旧 `[文档]` `docs/reference/database-schemas/versioning.md:17`）。回滚 = 恢复升级前备份，且该归档必须放在状态目录之外。

### 2.9 备份与回滚

- 官方升级前配方 `[文档]` `docs/install/updating/rollback-and-recovery.md:280-283`：
  ```
  openclaw backup create --output <dir> --verify
  ```
- `backup restore` **从不就地**、无 `--force`，目标是空目录/不存在；激活要停 Gateway、指向恢复出的状态目录、先跑 doctor `[文档]` `docs/cli/backup.md:71-92`、`docs/install/backups.md:351-423`。
- 自动回滚仅在**无 schema 迁移**时可用（恢复包、命令 shim、服务定义、激活前配置字节），命令仍返回非 0 `[文档]` `docs/install/updating/rollback-and-recovery.md:150-195`。
- 手工降级：`openclaw update --tag <known-good-version>`（通道为 extended-stable 时需加 `--channel stable`）`[文档]` `:45-58`。
- 已跨 schema 迁移时：唯一受支持的恢复是"恢复升级前的已验证备份 + 匹配版本" `[文档]` `:16-19`。
- `openclaw update cleanup` 会永久放弃回滚原件，默认确认 No，自动化需 `--yes` `[文档]` `docs/install/updating.md:739-762`。

### 2.10 通道与自动更新

- `stable`=npm `latest`（现 9.9）；`extended-stable`=月度支持线（现 2026.8.35，永不自动）；`beta`；`dev`=git main `[文档]` `docs/install/development-channels.md:13-23`。
- `--channel` 成功后持久化到 `update.channel`；`--tag` 是一次性、不改持久通道 `[文档]` `:38-39`、`82-96`；extended-stable 拒绝 `--tag` `[文档]` `docs/install/updating.md:381`；降级需确认（`--yes` 跳过）`[文档]` `docs/install/development-channels.md:113-114`。
- 配置块 `[文档]` `docs/gateway/config-runtime.md:125-141`：
  ```json5
  { update: { channel: "stable", checkOnStart: true, auto: { enabled: false } } }
  ```
- `checkOnStart: false` 或 `OPENCLAW_NO_AUTO_UPDATE=1` 可关闭全部自动更新请求与统计 `[文档]` `:140`；`auto.enabled` 默认 false `[文档]` `:141`。
- 故障恢复期建议设 `OPENCLAW_NO_AUTO_UPDATE=1`，避免自动更新器立刻把新版装回来 `[文档]` `docs/install/updating/rollback-and-recovery.md:91-93`。
- `[实测]` 本机已跑通两个将写进脚本的动作：`openclaw config set update.checkOnStart false` 生效（`config get update` → `{"checkOnStart": false}`，`config validate` 通过）；`openclaw backup create --output <已存在目录> --verify` 输出 `Archive verification: passed`，归档为 `<目录>\<时间戳>-openclaw-backup.tar.gz`。

### 2.11 Node

- 9.5 与 9.9 的 engines 相同；下限由 2026.9.3 引入 `[文档]` `docs/install/node-compatibility.md:21,89`。
- 门禁是能力检测而非只比版本：会用内存库探 `node:sqlite` 绑定，版本合规但探针失败也会被拒 `[文档]` `:25`。
- update 时若当前 Node 跑不了目标版本，updater 会挑一个已装的兼容 Node，或**悄悄安装私有 Node 运行时** `[文档]` `docs/install/node.md:68-73` → 气隙机上必须避免走到这一步（保持 PATH 上的 Node 合规），失败码 `node-runtime-preflight` `[文档]` `docs/install/updating.md:266-269`。

---

## 3. 现状与官方路径的差距

| # | 差距 | 证据 |
| --- | --- | --- |
| 1 | `C:\OpenClaw\app` 是 robocopy 来的全局 prefix，npm 的全局 prefix 在别处 → updater 可能判为无主/异地 | `[实测]` `global-install-foreign-destination`；`[文档]` `docs/cli/update.md:20-24,33-37` |
| 2 | 无随包 npm cache → 本地 tarball 装不齐 ~63 个传递依赖 | `[实测]` tarball 只自带 3 个包 |
| 3 | 无升级入口；现有 `install.cmd` 走 `-Force` 整树重装，会重跑 `onboard`（改写 provider 配置风险） | 本仓库 [Install-OpenClawOffline.ps1](Install-OpenClawOffline.ps1) |
| 4 | 未关 `update.checkOnStart` → 气隙机上每次启动都有失败的出网请求 | `[文档]` `docs/gateway/config-runtime.md:140` |
| 5 | 升级前无恢复点、无停服骨架、未处理 9.5 第一跳与 Windows 服务重绑 | `[文档]` §2.5、§2.6 |

`[实测]` 附带的两个事实（供体积与残留判断）：

- 5. 暖缓存 + `--offline` 条件下把 9.5 树原地升到 9.9 成功：`added 20 packages, removed 6 packages, and changed 323 packages`，版本变为 `OpenClaw 2026.9.9 (bcfc888)`；文件数 `41,406`、体积 `730M`，与全新 9.9 树（`41,406` / `729M`）一致 → **不残留旧版文件**。
- 6. 完整 app 树实际约 **600–730MB**（9.5 是 574M/37,226 文件，9.9 是 730M/41,406 文件）。README 里此前写的"~390MB"是 npm 包的 `unpackedSize`，不是完整树 —— 需修正。

---

## 4. 已定决策

| 项 | 决定 |
| --- | --- |
| 通道 | `stable`，本次升到 **2026.9.9** |
| 升级包形态 | **tarball + 为新版本预热的 npm cache**，另附完整整树作为救援/重装（**不能用于回滚**：跨 schema 后旧包起不来，见 §2.8） |
| 目标机 npm | **允许执行**，但仅限升级脚本内部，且必须走随包 cache + 离线变量 |
| 主路径 | 官方 `openclaw update --tag <本地 tarball 路径>` |
| 升级前 | 必须 `backup create --verify`（**本次是唯一回滚路径**，归档要放在状态目录之外）；必须停 Gateway 并等退出（9.5 第一跳） |
| dry-run 阶段 | 必须验证 owner 判定与依赖走缓存；`database preflight` 改为可选留证（schema 迁移已确认，见 §2.8） |

---

## 5. 升级流程（逐步）

来源标注：`[文档]` 为官方要求；`[工程补充]` 为官方未定义、由本仓库补上；`[必验]` 为本方案落地前必须在真机确认的判定点。

```
# 0) 前置（由新的安装流程保证，只需一次）
#    首次安装即写入 update.checkOnStart=false            [文档] config-runtime.md:140
#    并让安装树"有主"：NPM_CONFIG_PREFIX=<InstallRoot>\app [文档] cli/update.md:20-31

# 1) 恢复点（⚠ --output 指向已存在目录才会在里面生成带时间戳的 .tar.gz；
#    指向不存在的路径会被当成归档文件本身 —— 所以必须先建目录，官方配方亦如此）[实测]
New-Item -ItemType Directory -Force -Path C:\Backups\openclaw | Out-Null
openclaw backup create --output C:\Backups\openclaw --verify          [文档] rollback-and-recovery.md:280-283

# 2) 停 Gateway 并等它完全退出（9.5 第一跳的硬性要求）
openclaw gateway stop                          # 必要时 --force
#   或 schtasks /end /tn "OpenClaw Gateway"                          [文档] platforms/windows.md:168-170
#   注意：9.5 第一次停走"短/未知预算"路径，退出可能不优雅  [文档] how-updates-run.md:68-70

# 3) 预演 + 判定
$env:NPM_CONFIG_PREFIX = '<InstallRoot>\app'                          [文档] cli/update.md:29-31
openclaw update --dry-run --yes --no-restart --tag D:\bundle\openclaw-2026.9.9.tgz
#   可选留证（已确认本次跨 schema 迁移，故不再是判定项）:
openclaw database preflight <WAL一致快照>.sqlite --json               [文档] restart-and-supervision.md:178

#    离线依赖解析所需的两个变量（官方未定义，属工程补充）        [工程补充]
$env:npm_config_cache   = 'D:\bundle\npm-cache'
$env:npm_config_offline = 'true'

# 4) 正式升级（不加 --no-restart，让 updater 处理重启阶段）
openclaw update --yes --tag D:\bundle\openclaw-2026.9.9.tgz

# 5) Windows 收尾
openclaw gateway install --force               # 重新生成计划任务 launcher  [文档] platforms/windows.md:170-171
openclaw gateway restart                       # 不要 stop+start 串联        [文档] gateway/service.md:220
openclaw doctor --post-upgrade                 # 升级后专用检查              [文档] cli/doctor/running.md:226-243
openclaw health
openclaw gateway status --deep --json
openclaw doctor --lint --json

# 6) 异常处置
openclaw update repair --yes --json            # 停在 recovery pending 时    [文档] how-updates-run.md:495-501
openclaw backup restore <archive> --target <空目录>   # 回滚：本次唯一路径（跨 schema 迁移，见 §2.8）
```

`--dry-run` 阶段的三条硬性检查（失败即停止升级）：**owner 判定通过**、**依赖能走缓存解析**（无出网需求）、**升级前备份已 `--verify` 通过**（本次是唯一回滚路径，见 §2.8）。
`database preflight` 从"判定项"降级为"留证项"：schema 迁移已确认，做的价值是留存升级前后 `user_version` 的证据（17 → 19）。
降级命令 `openclaw update --tag 2026.9.5` **在本次升级后不可用**（updater 会因目标声明 schema 支持比磁盘库旧而拒绝）——回滚一律走 `backup restore`。

**路径约束**：tarball 文件名与父目录**不能含逗号**（npm 12）`[文档]` `docs/install/installer.md:23`。另：`--tag` 用**路径**写法（官方示例 `./openclaw.tgz`），不要用 `file:` URL。

---

## 6. 产物与脚本改动清单

### 6.1 Make 侧（构建）

| 改动 | 说明 |
| --- | --- |
| 新增 `npm pack openclaw@<ver>` | 产出 `openclaw-<ver>.tgz`，记录 SHA256 进 manifest（`packagedTarball` / `tarballSha256`） |
| 新增"预热 cache" | 构建时以同一 `--cache` 目录安装目标版本，天然含全部传递依赖；升级包携带该 cache |
| 保留整树产物 | 作为救援/重装通道（**不含回滚**：跨 schema 后旧包无法启动，见 §2.8） |
| manifest `schemaVersion` 递增 | 新增 tarball 字段；老 bundle 仍可被新安装脚本读取 |
| 携带 `UPGRADE-BRIEF.md` | 把目标机 AI 交接说明放进包根，随 U 盘一起到目标机（无外网，必须自带背景） |
| README.txt | 增加"升级"段：tarball 路径、cache 路径、`update.checkOnStart=false` |

### 6.2 新增 `Upgrade-OpenClawOffline.ps1`

- 参数：`-BundleDir`、`-InstallRoot`（默认 `C:\OpenClaw`）、`-TargetVersion`/`-Tag`、`-RescueTree`（走整树替换）、`-Force`、`-DryRun`。
- 流程即 §5；内置"9.5 第一跳"分支（当前版本 < 9.6 时强制走"先停服并等待退出"）。
- 失败提示使用官方信号：`openclaw update status --json` 的 `registry.reason`（`selector_missing`/`selector_query_failed`/`exact_package_mismatch`/`unsupported_git_channel`）`[文档]` `docs/cli/update/status-and-history.md:82-86`。
- PowerShell 5.1 约束沿用现有脚本：不加 `Join-Path` 第三参、不做出网假设、`Invoke-Native` 包裹原生命令。

### 6.3 安装侧（一次性）

| 改动 | 说明 |
| --- | --- |
| 首次安装写入 `update.checkOnStart=false` | 气隙机不再做每日出网检查 |
| 让安装树"有主" | 用户级 `npm config set prefix <InstallRoot>\app`，或仅在升级调用时用 `NPM_CONFIG_PREFIX`（更小副作用，推荐后者） |
| 标注救援模式 | 现有 `-Force` 整树重装路径改称"救援/回滚"，不再作为常规升级方式 |

---

## 7. 失败模式与处置矩阵

| 症状 / 官方信号 | 含义 | 处置 |
| --- | --- | --- |
| `global-install-foreign-destination` / 无主 skipped | prefix 归属不匹配 | 用 `NPM_CONFIG_PREFIX=<InstallRoot>\app` 重试（`[实测]` 已验证可解） |
| `ENOTCACHED` / 依赖解析失败 | 传递依赖不在随包 cache 里 | 重建升级包（用目标版本预热 cache）；确认未改 registry（改 registry 会让缓存键失配 —— `[实测]` 踩过） |
| 停在 recovery pending | 9.5 旧驱动未完成交接 | `openclaw update repair --yes --json` |
| Windows 重命名失败（EPERM/EBUSY/EACCES） | 有进程占用文件 | updater 已重试 ~57.75s；仍失败则先 `gateway stop --force` 再重试 |
| 启动退出码 78 / `newer schema version`（本次升级后必然出现） | 磁盘数据库 schema 19 比旧构建支持的 17 新 | 降级解决不了；唯一路径是 `openclaw backup restore` 升级前归档 |
| 升级后想回退到 9.5 | 已跨 schema 迁移（§2.8） | 换回旧整树无效（旧包会拒绝启动）；只能恢复归档 |
| `node-runtime-preflight` | 目标版本跑不了当前 Node | 保持在 engines 窗口内（9.9 与 9.5 相同），避免触发私有 Node 下载 |
| 服务指向旧路径 | Windows 上 updater 不重绑 | `openclaw gateway install --force` |

---

## 8. 待验证与未决

**必须真机确认的三件事**（决定主路径能否落地）：

1. **owner 判定**：设 `NPM_CONFIG_PREFIX=C:\OpenClaw\app` 后 `openclaw update --dry-run --tag <tgz>` 是否通过。macOS 端到端无法复现（沙箱禁用 `ps`，darwin 的 handoff 身份校验必失败；Windows 走独立的原生实现，不受此影响），只能真机验。
2. **依赖真走缓存**：气隙机上 `npm_config_offline=true` + 随包 cache 能否把 ~63 个传递依赖装齐。
3. **原生依赖**：目标机 npm 若为 12（默认拒绝依赖脚本），koffi / tree-sitter-bash / esbuild 的安装脚本是否被跳过 —— 这也是保留整树救援通道的价值所在。

**未决 / 风险**：

- ~~9.5 的 `schemaVersions` 未知~~ → **已解决**：9.5 = `state 17 / agent 21`，9.9 = `state 19 / agent 24`，本次升级**确认跨 schema 迁移**，回滚只能靠升级前备份（§2.8 有实测证据）。`database preflight` 仍建议做，但已不再是"未知项判定"，而是留证。
- 升级期间磁盘峰值：官方是"stage 到临时 prefix 再 swap" `[文档]` `how-updates-run.md:1088-1096`，加上救援整树，峰值可能达 ~1.5GB；目标机余量需登记。
- `openclaw update` 是否尊重 `npm_config_*` 环境变量属 `[工程补充]` 推断（子进程继承环境），需真机验证。
- 9.6–9.8 的变更集在包内**无 CHANGELOG 记录**（9.9 的 CHANGELOG 只有 `## 2026.9.9` 一节），跳版本升级的中间变更不可查。
- 9.9 的 CHANGELOG 明确 "No intentional capability changes"，未声明破坏性/配置/引擎变化 `[文档]` `package/CHANGELOG.md:15`。

---

## 9. 附录：如何复现本文的官方出处

```bash
# 下载包（构建侧联网机器或任意可访问 npm 的机器）
npm pack openclaw@2026.9.9            # -> openclaw-2026.9.9.tgz

# 提取文档与 CHANGELOG
tar xzf openclaw-2026.9.9.tgz package/docs package/CHANGELOG.md package/package.json
# 本文引用形如 docs/cli/update.md:202，即 openclaw-2026.9.9 包内 package/docs/cli/update.md 第 202 行
```

关键入口文件：`docs/cli/update.md`、`docs/cli/update/how-updates-run.md`、`docs/cli/update/status-and-history.md`、`docs/cli/update/repair-and-recovery.md`、`docs/install/updating/update-methods.md`、`docs/install/updating/rollback-and-recovery.md`、`docs/install/updating/automatic-updates.md`、`docs/gateway/doctor/config-migrations.md`、`docs/cli/backup.md`、`docs/cli/gateway/service.md`、`docs/platforms/windows.md`、`docs/install/node-compatibility.md`。
