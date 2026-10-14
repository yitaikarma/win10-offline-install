# 离线能力边界（openclaw）

> 目标机：气隙 Windows 10 x64，普通用户，无管理员，内网可达。
> 本文件随离线包交付，是目标机上唯一的权威说明——目标机读不到仓库、也读不到官网。
>
> 标注约定：**实测** = 在构建侧（macOS + Node 26.7.0 + npm 11.19.0 + 真实 `openclaw@2026.9.5` /
> `2026.9.9` / `2026.10.3` 包）验证过；**未验证** = 尚未在真实 Win10 气隙机上复核，属推断。
> 版本以包内 `bundle-manifest.json` 的 `openClawVersion` 为准（本文示例 **2026.10.3**）。方案与出处见
> `UPGRADE.md`，目标机执行步骤见 `UPGRADE-BRIEF.md`。

## 1. 前提

| 项 | 要求 | 依据 |
| --- | --- | --- |
| 系统 | Windows 10 x64（安装脚本硬校验 `PROCESSOR_ARCHITECTURE=AMD64`） | 脚本 |
| Shell | Windows PowerShell 5.1（脚本刻意只用 5.1 语法面） | 脚本 |
| Node | **>=24.16 且 <25，或 >=26.1**（示例 `26.7.0`，由 nvm-windows 管理） | `openclaw` 包 `engines.node`，9.5 与 9.9 相同 **实测** |
| npm | 随 Node 提供；**11.16+ 引入 `--allow-scripts`，11.x 默认只警告、依赖脚本仍会执行；默认拒绝是 npm 12.0.0 起** | **实测**（npm 11.19 上未列入的包脚本仍执行并告警） |
| 网络 | 安装、启动、升级都**不需要**外网；模型推理走内网 OpenAI 兼容端点 | 脚本与设计 |
| 权限 | 全程用户级：不写 HKLM、不装 Windows 服务（用用户级计划任务）、PATH 只改用户级 | 脚本 |
| 磁盘 | 预构建 app 树 **574 MB（2026.9.5）/ 730 MB（2026.9.9）**；`npmcache` 包 **439 MB**（cache 320 + tarball 98 + docs 20，2026.10.3 实测）；升级峰值（stage + 救援整树）可能到 ~1.5 GB | **实测** |

## 2. 能做什么

- **CLI**：`openclaw --version`、`doctor --lint`、`config get/set/patch/validate`、`gateway install/status/restart`、
  `qr --setup-code-only`、`devices`/`nodes` 审批命令；均不触网。**实测**。
- **Gateway**：以**用户级计划任务**常驻（Windows 下任务名 `OpenClaw Gateway`），绑 **loopback**
  `ws://127.0.0.1:18789`。**实测**（CLI 行为）/ **未验证**（该机计划任务实际注册）。
- **Control UI**：浏览器打开 `http://127.0.0.1:18789`。**未验证**（未在目标机浏览器上复核）。
- **模型推理**：内网 OpenAI 兼容端点，`onboard --auth-choice custom-api-key --custom-base-url ...`
  或零参数安装后自行 `config patch`。密钥可走 SecretRef（`{source:"env",provider:"default",id:"LLM_KEY"}`）不落明文。**实测**（构建侧跑通配置与 `config validate`）。
- **本地会话与状态**：全部落在 `%USERPROFILE%\.openclaw`（`openclaw.json`、凭据、会话、SQLite、日志）。**实测**。
- **备份/恢复**：`openclaw backup create --output <已存在目录> --verify` / `backup restore <归档> --target <空目录>`。**实测**（创建与校验通过）。
- **离线升级**：从新 bundle 走官方 updater + 本地 artifact（`openclaw update --tag <本地 tgz>`），
  依赖由随包预热 cache 提供（`npm_config_offline=true`）。**实测**（构建侧用 9.5 树 + 暖缓存完成 9.5→9.9 的等价落盘，
  版本与文件数均与全新树一致）。
- **离线文档**：`docs\`（包内文档，与所装版本一致）＋ `docs\OFFLINE-CAPABILITIES.md`（本文件）。

## 3. 不能做什么（离线时的预期失败，不是故障）

- `openclaw docs`：检索**线上**站点，离线不可用；读 `docs\` 里的 markdown。
- 频道（channels）、skills 搜索、搜索 provider、插件市场/安装、更新通知：都需要外网，onboard 时用
  `--skip-channels --skip-search --skip-ui` 跳过。
- **自动更新检查**：默认 `update.checkOnStart=true` 会每 24h 请求 `telemetry.openclaw.ai`。安装脚本已写入
  `update.checkOnStart=false`；若被改回，失败属预期。
- **`openclaw update` 不带本地 artifact**：需要 registry 解析版本，气隙下必然失败（`selector_query_failed` /
  `ETARGET` 一类）。升级必须用 bundle 里的 tarball。
- 桌面端（OpenClaw Companion / Windows Hub）与 WebView2：**本包不含**，是设计决定。
- `openclaw uninstall` / `reset` / `update cleanup`：会删除状态或永久放弃回滚原件，**不要运行**。

## 4. 原生依赖与安装脚本（air-gap 下最脆的一环）

架构绑定的包必须在**目标平台**上解析。交叉预热（`--os win32 --cpu x64`）在 2026.10.3 上实际解析出的 win32-x64 包（**实测**，会写进 manifest 的 `nativePackages` 并在目标机逐个校验）：

```
@esbuild/win32-x64                    @koromix/koffi-win32-x64
@lydell/node-pty-win32-x64            @openclaw/fs-safe-win32-x64-msvc
@trycua/cua-driver-win32-x64-msvc     @ubjs/node-win32-x64-msvc
sqlite-vec-windows-x64
```

命名不统一（这正是构建侧扫描必须写成“平台名 + 架构”宽松模式的原因）：`koffi-darwin-arm64`（后缀）、
`@esbuild/darwin-arm64`（scoped、无前导横线）、`sqlite-vec-windows-x64`（**windows** 而非 `win32`）、
`@openclaw/fs-safe-win32-x64-msvc`（带 `-msvc`）。

- **app 模式**：在 Windows x64 上构建，依赖脚本在构建时就跑完，整树带过去。构建脚本会扫描树内
  平台包：出现非 `win32-x64`（或 `windows-x64`）的包即**构建失败**（**实测**：macOS 树上会抓出
  6–7 个 darwin 包）。安装脚本再按 manifest 记录的清单逐个校验在位。
- **npmcache 模式**：可在任意平台预热（`npm --os=win32 --cpu=x64 --force --ignore-scripts`），
  脚本留给**目标机**执行——在构建机平台上跑它们会失败（koffi 会回退 cmake 源码构建并报
  `fatal error: 'algorithm' file not found`，**实测**）。
- npm 版本决定脚本是否执行：11.x 只告警，12.x 默认拒绝。安装脚本会解析 npm 输出的"未放行"清单并
  **自动补跑一次全量 `--allow-scripts`**，仍被跳过则中止（**实测**，构建侧同款算法）。

## 5. 体积与磁盘

| 产物 | 体积 | 说明 |
| --- | --- | --- |
| `app\`（预构建树） | 574 MB（9.5）/ 730 MB（9.9）；10.3 的完整 win32 树未实测（其 npm 包 unpacked 257 MB，比 9.9 的 389 MB 小） | 41,406 文件（9.9） |
| `npmcache` 包（10.3 实测） | **439 MB**：`npm-cache` 320 + tarball 98 + `docs` 20 | 1296 篇文档 |
| `openclaw-<版本>.tgz` | ~114 MB | 升级用的 release artifact |
| `npm-cache\` | 百 MB 级 | 升级/离线安装的依赖来源 |
| 升级峰值 | ~1.5 GB | stage 到临时前缀 + 救援整树 + 状态快照 |

构建侧可在拷贝前删掉 `_download\`；npmcache 模式默认删除 `_cachewarm\`（`-KeepStaging` 可保留）。

## 6. 数据与状态

- 全部状态在 `%USERPROFILE%\.openclaw`：`openclaw.json`（+ `.bak`…`.bak.4` 备份环）、`credentials\`、
  `sessions\`、`state\openclaw.sqlite`、`agents\<id>\agent\openclaw-agent.sqlite`、`logs\`。
- **数据库 schema 是单向迁移的**：9.5 = `state 17 / agent 21` → 9.9 = `state 19 / agent 24` → **2026.10.3 = `state 20 / agent 24`**；
  9.5 建的库被 9.9 打开后 `user_version` 由 17 变 19，随后**9.5 拒绝打开**该库（**实测**）。
- 因此**升级后"换回旧包"救不回来**：回滚 = 恢复升级前的 `openclaw backup create` 归档（放在状态目录之外）。

## 7. 端口与安全

- 只绑 loopback；Gateway token 存在 `openclaw.json`（`gateway.auth.token`，明文，属上游设计）。
- provider 密钥建议用 `-ApiKeyEnv` + `config set ... --ref-*` 写成 SecretRef，不落明文。
- 计划任务为**用户级**、`InteractiveToken`，无需存密码；任务创建被拒时上游会回退到"启动文件夹"登录项。
- 全程不写 HKLM、不改系统 PATH。

## 8. 未验证项（不要当成既成事实）

- [ ] 未在真实 Win10 气隙机上跑过一次完整安装、升级与回滚。
- [ ] **升级的 owner 判定**（`NPM_CONFIG_PREFIX=<InstallRoot>\app` 让 updater 认领这棵树）只在 macOS 上
      以等价方式验证过；Windows 上的实际结果未验证——这正是升级脚本把 `--dry-run` 当闸门的原因。
- [ ] npmcache 模式在 Windows 目标机上执行依赖安装脚本的成功率（预编译二进制是否都在）。
- [ ] `-RescueTree`（整树镜像替换）未真实执行过。
- [ ] 普通用户下计划任务的实际注册成功率，以及 Control UI 在目标机浏览器上的表现。
- [ ] 跨大版本（例如 2026.9.x → 2026.10.x）的配置/状态迁移表现。
