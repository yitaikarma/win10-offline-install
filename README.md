# win10-offline-install

**目标机器的离线交付中心。** 凡是要装到目标机上的东西——运行时、CLI、桌面应用、依赖包、文档——都在这里打包、固定版本、做完整性校验，产出一个可以直接拷 U 盘带过去的离线包。

本仓库以**目标机器的环境约束**为准绳：任何新包都必须先满足本文第 2 节的机器档案，再遵守第 3 节的交付规范。`openclaw-offline/` 只是这套流程的第一个产物（见第 5 节），不是本仓库的主题。

```
构建侧（联网）──打包──▶ 离线包 ──U 盘──▶ 目标机（气隙 Win10 x64）──本地安装──▶ 可用
```

> **术语：气隙机（air-gapped host）** —— 与互联网无任何链路、数据只能靠 U 盘搬运的机器。
> 本项目目标机属于此类，但**内网可达**（见 [2.3](#23-网络)），并非"完全无网络"：所以"气隙"只否决一切"安装时回源"的设计，不否决局域网内访问。

---

## 1. 两侧环境

| | 构建侧 | 目标机 |
| --- | --- | --- |
| 位置 | 联网机器，**必须是 Windows x64** | 气隙机器，**Windows 10 x64** |
| 网络 | 可访问外网（npm / GitHub / 微软 / nodejs.org） | **完全无外网**，仅内网可达 |
| 权限 | 无特殊要求 | **普通用户，无管理员** |
| 产出 | 离线包目录（见第 3 节布局） | 本机安装目录 + 用户级配置 |

构建侧被锁定为 Windows x64 是硬约束，原因见 [2.4](#24-运行时与工具的存在性) —— 应用树里有架构相关的原生依赖，异构构建出来的包在目标机上会缺文件。**本仓库当前检出在 macOS 上，因此只能做"准备工作"（写脚本、准备 npm cache 型包），app 型包必须拿到 Windows x64 上生成。**

---

## 2. 目标机器档案

> 以下均从已实现脚本的强制校验、注释与失败处理反推得出，属于**该包作者的既有结论**，尚未在真实机器上复核。带 ❓ 的项需要登记确认。

### 2.1 操作系统与 Shell

| 项 | 值 |
| --- | --- |
| 系统 | Windows 10，64 位 |
| 架构 | **x64 / AMD64 only**。安装脚本硬性校验 `PROCESSOR_ARCHITECTURE=AMD64`，其他架构直接 `throw`（[Install:176-177](openclaw-offline/Install-OpenClawOffline.ps1#L176-L177)） |
| Shell | **Windows PowerShell 5.1**（系统自带版本）。脚本刻意避开 PS7/.NET Core 专有 API，例如不用 `RuntimeInformation.OSArchitecture`（[Make:283-285](openclaw-offline/Make-OpenClawOfflineBundle.ps1#L283-L285)） |
| 具体 build 号 ❓ | 未锁定。脚本只校验 x64 + Win10 语义（`curl.exe` 需 1803+） |
| 语言/区域 ❓ | 未锁定。脚本所有输出与 `.cmd` 均为 ASCII，规避 OEM 代码页问题 |

### 2.2 权限模型（对交付形态影响最大的一条）

- **目标机用户没有管理员权限**，或至少所有交付物都不得要求提权。
- 由此确定的形态：
  - 常驻服务不用 Windows Service，改用 **用户级计划任务**（[Install:532](openclaw-offline/Install-OpenClawOffline.ps1#L532)）。
  - PATH 只改**用户级**：`[Environment]::SetEnvironmentVariable(..., 'User')`，不碰系统 PATH。
  - 不写 HKLM，不调用任何安装器级系统变更。

### 2.3 网络

- **无外网**。任何"安装时回源"的设计在此机器上都不成立：包必须自包含，包括文档。
- **内网可达**，且已明确存在一类资源：

| 资源 | 形态 | 示例 |
| --- | --- | --- |
| 局域网模型端点（OpenAI 兼容 HTTP） | `BaseUrl` 通常含版本段，可选 Bearer Key | `http://10.0.0.20:8000/v1`，模型 `qwen3-32b` |
| 其他内网服务 ❓ | 未知，需要时登记 | — |

- 端点探活方式：`GET <BaseUrl>/models`；**并非所有服务都暴露该路由，探测失败不视为安装失败**（[Install:443-457](openclaw-offline/Install-OpenClawOffline.ps1#L443-L457)）。
- 密钥处理：**不落明文配置**，走环境变量 + SecretRef（`{ source: "env", provider: "default", id: "LLM_KEY" }`）。

### 2.4 运行时与工具的存在性

| 组件 | 目标机上是否已存在 | 约束 |
| --- | --- | --- |
| Node.js | **已有**，由 **nvm-windows** 管理 | 版本必须落在 **>=24.16 且 <25，或 >=26.1**（示例 `26.7.0`）。安装前必须在本 shell 已 `nvm use`（[Install:211-226](openclaw-offline/Install-OpenClawOffline.ps1#L211-L226)） |
| npm | 随 Node 提供 | **11.16+ 出现 `--allow-scripts` 策略，但 11.x 默认只警告、依赖脚本仍会执行；默认拒绝是 npm 12.0.0 起**。脚本对两者都传 `--allow-scripts`，故 12.x 必需、11.x 无害（[Install:286](openclaw-offline/Install-OpenClawOffline.ps1#L286)） |
| `robocopy.exe` | 系统自带 | 可放心使用；**退出码 >= 8 才算失败** |
| `curl.exe` | 不保证 | 仅构建侧依赖（Win10 1803+ 自带） |

**原生依赖 = 架构绑定。** app 型包内含 `sqlite-vec-win32-x64`、`koffi`、`tree-sitter-bash` 等带原生二进制/安装脚本的依赖，只能在 Windows x64 上构建（[Make:20-22](openclaw-offline/Make-OpenClawOfflineBundle.ps1#L20-L22)）；**npm 12 起**这些依赖的安装脚本默认不执行（11.x 只是警告），必须显式放行并复查跳过清单。两条线各自的做法：

- **app 模式**（首选）：Windows x64 上构建，脚本在构建时跑完，整树带过去。构建脚本会**递归扫描平台包**，出现非 `win32-x64`/`windows-x64` 的包即构建失败（`openclaw-offline` 与 `dsh-web-offline` 都实现了）。
- **npmcache 模式**（可在 macOS 检出构建）：`npm --os=win32 --cpu=x64 --force --ignore-scripts` 只下载、把脚本留给目标机执行（理由见第 4 节陷阱 16）。
- **目标是升级路径的判定项**：目标机 npm 版本（11 vs 12）决定依赖脚本是否会执行，见 [openclaw-offline/UPGRADE.md](openclaw-offline/UPGRADE.md) §8。

**Node 版本窗口是逐包登记的**：上表是 openclaw 的窗口（由它的脚本强制）。新包必须自己声明下限，例如
`dsh-web-offline` 的硬下限是 **>= 22.19**（依赖树 `engines.node` 的最大值），并把上表窗口当作已知良好提示。

### 2.5 磁盘、介质与本地约定

- **安装根**：单一目录，默认 `C:\OpenClaw`；包内目录名固定（`app\`、`docs\`、`npm-cache\`），**不可重命名**。
- **配置与日志**：集中在用户目录，如 `%USERPROFILE%\.openclaw\openclaw.json`、`%USERPROFILE%\.openclaw\logs`。
- **监听约定**：本地服务默认绑 **loopback**，端口取高位（Gateway 用 `18789`，`ws://127.0.0.1:18789`）。
- **传输介质**：U 盘/移动硬盘。**文件会带 MOTW，安装前必须 `Get-ChildItem -Recurse | Unblock-File`**（[Make:738](openclaw-offline/Make-OpenClawOfflineBundle.ps1#L738)）。
- **体积敏感**：预构建 app 树实测 **574 MB（2026.9.5）/ 730 MB（2026.9.9）**；升级包另需 tarball（~114 MB）与预热 npm cache，升级期间磁盘峰值（stage + 救援整树）可能到 ~1.5 GB。拷贝前应能删掉 `_download\` 中间产物。
- 磁盘余量、内存、机器名/序列号 ❓ 未记录。

### 2.6 待登记项

以下字段目前无据可查，建议补进本表，避免每个新包都重新猜一遍：

- [ ] 目标机主机名 / 资产编号，以及是否不止一台
- [ ] Windows 10 具体版本与 build（决定 `curl.exe`、TLS 行为）
- [ ] 是否**永久**气隙，还是偶尔可接入内网/镜像源
- [ ] 内网模型端点的固定地址、模型清单、是否需 Key
- [ ] 是否确实无管理员权限（当前交付物都不需要提权，登记后可省去逐包判断）
- [ ] C: 可用空间与是否需要指定非系统盘安装根
- [ ] nvm-windows 是否确已安装、当前激活版本

---

## 3. 离线交付通用规范

所有包一律遵守，这是本仓库的核心资产：

### 3.1 包布局

```
<组件>-offline/
├── <组件>-offline-bundle/       离线包（构建侧产出，拷到目标机）
│   ├── app\                     预构建应用树
│   ├── npm-cache\               可选：npm 缓存，供目标机自行 --offline 安装
│   ├── node\                    可选：便携 Node win-x64
│   ├── <组件>-<版本>.tgz         可升级组件：升级用的 release artifact 本体
│   ├── docs\                    离线文档（必须！目标机读不到线上文档）
│   ├── bundle-manifest.json     版本 + SHA256 + 文件数/字节数（schemaVersion）
│   ├── UPGRADE.md / UPGRADE-BRIEF.md  可升级组件：方案与目标机执行说明
│   └── README.txt               面向目标机操作者的复制粘贴说明
├── Make-<组件>OfflineBundle.ps1 构建侧：联网打包（app 与 npmcache 两种模式）
├── Install-<组件>Offline.ps1    目标机：离线安装
├── install.cmd                  目标机：双击入口（纯 ASCII）
├── Upgrade-<组件>Offline.ps1    目标机：离线升级（可升级组件才有）
├── upgrade.cmd                  目标机：升级双击入口（纯 ASCII）
├── Test-<组件>Scripts.ps1       构建侧：交付前预检（语法/ASCII/CRLF/锚点/跨文件契约）
└── docs\OFFLINE-CAPABILITIES.md 组件：离线能力边界（构建时随 docs\ 进包）
```

> 组件目录与 bundle 目录是两处，但 **bundle 必须自包含**：两个包的构建脚本都会把 `install.cmd` /
> `Install-*.ps1` / `upgrade.cmd` / `Upgrade-*.ps1` / `UPGRADE.md` / `UPGRADE-BRIEF.md` 再拷一份进 bundle 根，
> 这样目标机上"打开 bundle 目录双击 `install.cmd`（或 `upgrade.cmd`）"就能零参数工作（脚本默认
> `BundleDir=$PSScriptRoot`）。脚本源头仍在组件目录，构建时复制，不存在两份手工维护的副本；预检脚本会断言这份携带清单。

### 3.2 硬性要求

1. **完整性**：每个外部下载物都记录 SHA256 并在安装前校验，不匹配即中止（Node zip 还必须比对官方 `SHASUMS256.txt`）。预构建应用树也必须在目标机复制后比对 manifest 的 `appFileCount`/`appBytes`——它是体积最大、最容易被 U 盘损坏的载荷。
2. **可续跑**：下载支持断点续传与重试；打包与安装都幂等，已完成的目录被识别复用，而不是重下或清空。
3. **不可误删**：清理逻辑必须能识别"这是我自己上次的产物"，否则拒绝执行，需显式 `-Force`；拒绝把盘根当输出目录（安装侧同样拒绝盘根与系统目录作为 `-InstallRoot`）。
4. **零残留**：除输出目录/安装目录外不得留下状态目录、全局 npm 前缀、计划任务；脚本自身做前后快照比对。
5. **可诊断**：`bundle-manifest.json` 记录版本、构建时间、构建架构、npm 版本、文件数与总字节数；可升级组件还要记录 release artifact 名与 SHA256、以及该构建声明的 DB schema 版本。
6. **边界声明**：明确写出"离线时会失败、属预期"的功能，避免被当成故障。
7. **面向人**：一个纯 ASCII 的 `.cmd` 双击入口，内置前置检查（如 node 是否在 PATH）与清晰错误提示；破坏性操作（升级）要有确认提示。
8. **可升级**：升级走官方 updater + 本地 artifact，包内必须同时带 **release tarball + 预热 npm cache**（tarball 不含传递依赖，官方也没有离线模式）；升级脚本必须"先备份、后停服、再预演"，并明确写出**回滚方式**。
9. **交付前预检**：`Test-<组件>Scripts.ps1` 必须全绿再打包——它检查 PS 5.1 语法面（含 `Join-Path` 参数个数）、脚本纯 ASCII + CRLF，以及 README 行号锚点是否仍然自洽；没有锚点的包则改为校验**跨文件契约**（manifest schema、包名、Node 下限、默认端口、安装脚本与原生包清单必须在 make/install/upgrade 之间一致，见 `dsh-web-offline` 的实现）。

### 3.3 两种打包模式（跨平台相关的分界）

| 模式 | 内容 | 能在哪构建 |
| --- | --- | --- |
| `app` | 预构建好的完整应用树 | **仅 Windows x64**（原生依赖架构绑定） |
| `npmcache` | 只带 npm 缓存，目标机跑 `npm install --offline` | 任意平台（含本 macOS 检出） |

安装脚本按 manifest 的 `mode` 字段分派，缺省时按是否存在 `app\` 推断（[Install:158-172](openclaw-offline/Install-OpenClawOffline.ps1#L158-L172)）。

---

## 4. 目标机环境的已知陷阱

在 Windows 10 + PowerShell 5.1 + 气隙 这套组合上踩过的坑，新包直接复用结论，不要重新踩：

| # | 陷阱 | 结论 |
| --- | --- | --- |
| 1 | PS 5.1 下原生命令写 stderr 会触发 `NativeCommandError`，配合 `$ErrorActionPreference='Stop'` 变成**终止性错误**（即使 `2>&1`） | 所有原生调用（node/npm/curl）必须包一层、临时放宽 preference 再取 `$LASTEXITCODE` |
| 2 | `Set-StrictMode -Version Latest` 下读不存在的属性 = 终止性错误 | 版本相关/可选 JSON 字段一律通过 `Get-Prop` 兜底读取 |
| 3 | WinPS 5.1 不默认协商 TLS 1.2，HTTPS 报 "Could not create SSL/TLS secure channel" | 启动时显式 `SecurityProtocol -bor Tls12` |
| 4 | WinPS 5.1 的 `Invoke-WebRequest` 忽略 `HTTP(S)_PROXY` 环境变量 | 解析一次代理并显式传 `-Proxy`（`curl.exe` 会自动读，但仍统一传 `-x`） |
| 5 | `Invoke-WebRequest` 不能续传，慢链路上等于失败 | 用 `curl.exe -C -` 续传；`curl` 退出码 33（拒绝 Range）时删文件重来；保留 `HttpWebRequest` 回退 |
| 6 | `RuntimeInformation.OSArchitecture` 在 PS 5.1 不存在 | 用 `PROCESSOR_ARCHITEW6432` → `PROCESSOR_ARCHITECTURE` 兜底 |
| 7 | npm >= 11.16 默认不跑依赖的安装脚本，原生依赖因此残缺 | 先 `--allow-scripts=<pkg>`，再从 npm 输出里解析被跳过的包名补一次全量放行，并复查是否仍有跳过 |
| 8 | `Start-Process -ArgumentList` 传数组时不做引号处理 | 需要引号的参数自己拼字符串 |
| 9 | `robocopy` 退出码 0–7 是成功，>= 8 才是失败 | 判定用 `-ge 8` |
| 10 | 从 U 盘拷来的文件带 MOTW，执行被拦 | 安装前 `Unblock-File` |
| 11 | `Join-Path` 传三个及以上位置参数（多段拼接） | 这是 PS 6.0+ 的 `-AdditionalChildPath`；PS 5.1 报"找不到接受实际参数…的位置形式参数"，在 `$ErrorActionPreference='Stop'` 下**直接终止脚本**。必须嵌套：`Join-Path (Join-Path $a 'b') $c` |
| 12 | 用户级 PATH 直接 `-notcontains` 去重 | 带尾分隔符/大小写不同的同一路径会被重复追加；应先 `TrimEnd('\')` 再比较（`-contains` 本身不区分大小写），并且没变化时不要回写 |
| 13 | 脚本用 LF-only 行尾交付 | `.cmd` 在 cmd.exe 下是已知风险，`.ps1` 也不该与仓库约定不一致；用 `.gitattributes`（`*.ps1`/`*.cmd` → `eol=crlf`）固定，并由预检脚本校验 |
| 14 | 升级/回滚当成"换回旧包" | 升级会把状态库 schema 前向迁移，旧构建随后**拒绝打开**（实测 9.5 的 17 → 9.9 的 19）。回滚只能靠升级前的 `openclaw backup create` 归档 |
| 15 | npm ≥11.19 的 `--allow-scripts` **只允许全局作用域**安装使用 | 不带 `-g` 的 `npm install --prefix <dir> --allow-scripts=...` 直接 `EALLOWSCRIPTS`（提示改用 package.json 的 `allowScripts` 或 `.npmrc`）。要放行依赖脚本就必须 `npm install -g <pkg> --prefix <dir>` |
| 16 | 跨平台预热 npm cache 时，依赖的安装脚本跑在**构建机平台**上 | `--os=win32 --cpu=x64` 在 macOS 上 warm 时 koffi 拿不到预编译二进制 → 回退 cmake 源码构建 → `fatal error: 'algorithm' file not found`，整个 install 失败（实测）。warm 阶段必须 `--ignore-scripts`，把脚本留给目标机执行 |
| 17 | npm 11 的全局安装把依赖树**嵌在包目录内** | 布局是 `<prefix>\node_modules\@deepseek-ai\dsh\node_modules\<pkg>`，不是 hoist 到 `<prefix>\node_modules\<pkg>`。按固定路径探测原生包会全部漏判，必须探测两种布局并留递归兜底 |
| 18 | dsh 的 Web 面有 browser-trust fence，`GET /` 正常返回 **401** | 无签名 cookie 时 `/` 回 401（"dsh web authentication required; reopen the URL printed by dsh web."）。必须先访问启动时打印的 activation URL（`http://127.0.0.1:<端口>/?token=...`）种下 cookie，`GET /` 才是 200。该 token **每次启动重铸**，只存在于服务控制台输出里——所以任何"探测 `http://host:port/` 是否 200"的冒烟测试都会误判，必须从输出里取回 URL（见 `dsh-web-offline/docs/WEB-SURFACE.md`） |
| 19 | 构建侧 `~/.npm` 可能含 root-owned 文件（npm 旧版 bug） | `npm view` / `npm install` 会 `EPERM`（本机实测）。不要 `sudo chown` 用户目录，改用 `--cache <私有目录>` 绕过 |
| 20 | 平台包**命名不统一**，按固定模式探测会漏判 | 实测到的四种写法都必须覆盖：`koffi-darwin-arm64`（后缀）、`@esbuild/darwin-arm64`（scoped、无前导横线）、`sqlite-vec-windows-x64`（**windows** 而非 `win32`）、`node-addon-require-builtin-win32-x64-msvc`（带 `-msvc` 后缀）。构建侧扫描须匹配 `(^\|[-/])(win32\|windows\|darwin\|linux\|…)-(x64\|arm64\|…)(-\|$)`，且必须**递归**（见陷阱 17） |
| 21 | `openclaw backup create --output <路径>` 的语义取决于该路径**是否已存在** | 指向已存在目录 → 在里面生成带时间戳的 `*.tar.gz`（官方配方先 `mkdir` 就是这个原因）；指向不存在的路径 → 该路径被当成**归档文件本身**（生成一个没有扩展名的文件）。且 `backup restore` **从不就地恢复**、目标必须是空目录 |

---

## 5. 现有离线包

| 包 | 覆盖内容 | 目标机入口 | 状态 |
| --- | --- | --- | --- |
| [openclaw-offline](openclaw-offline/) | OpenClaw CLI + Gateway（计划任务，端口 18789），可选便携 Node。不含桌面端与 WebView2，界面走浏览器 Control UI | 安装 [install.cmd](openclaw-offline/install.cmd) / 升级 [upgrade.cmd](openclaw-offline/upgrade.cmd) | 脚本完整；bundle 自包含；`app` 与 `npmcache` 两种模式；manifest schemaVersion 4（带 tarball/哈希/schemaVersions/原生包清单）；预检含跨文件契约。**未实机验证**：安装、升级、回滚、owner 判定。升级方案 [UPGRADE.md](openclaw-offline/UPGRADE.md)、目标机自决执行 [UPGRADE-BRIEF.md](openclaw-offline/UPGRADE-BRIEF.md)、预检 [Test-OpenClawOfflineScripts.ps1](openclaw-offline/Test-OpenClawOfflineScripts.ps1)、能力边界 [docs/OFFLINE-CAPABILITIES.md](openclaw-offline/docs/OFFLINE-CAPABILITIES.md) |
| [dsh-web-offline](dsh-web-offline/) | DeepSeek Harness **Web 版**（`dsh web`，默认 loopback 3080，用户级计划任务），内网 OpenAI 兼容端点配置。不含 Electron 桌面端 | 安装 [install.cmd](dsh-web-offline/install.cmd) / 升级 [upgrade.cmd](dsh-web-offline/upgrade.cmd) | 脚本完整；**版本化安装根**（`versions\<版本>` + `current.txt`）让回滚只改一行。npmcache 模式的 win32-x64 交叉预热 + 离线重装 + 离线 tgz 重装**已实测**；app 模式与实机安装**未验证**。升级方案 [UPGRADE.md](dsh-web-offline/UPGRADE.md)、目标机执行 [UPGRADE-BRIEF.md](dsh-web-offline/UPGRADE-BRIEF.md)、预检 [Test-DshWebOfflineScripts.ps1](dsh-web-offline/Test-DshWebOfflineScripts.ps1)、能力边界 [docs/OFFLINE-CAPABILITIES.md](dsh-web-offline/docs/OFFLINE-CAPABILITIES.md) |

`openclaw-offline` 的细节（参数、配对流程、provider 模板）见脚本头部注释；它是第 2、3、4 节规范的**参考实现**，新增包时可以照抄结构。可升级组件的完整模式（构建侧产物、目标机升级流程、失败与回滚矩阵）见 [UPGRADE.md](openclaw-offline/UPGRADE.md)。

`dsh-web-offline` 是第二个实现，覆盖 openclaw 那条线没遇到的三类问题：**没有官方 updater 的组件怎么升级**（版本化安装根 + 自动回滚）、**跨平台预热 npm cache**（`--os/--cpu` + `--ignore-scripts`）、以及**带认证围栏的 Web 面怎么做冒烟测试**（从服务输出里取回 activation URL，而不是拿 200 当健康判据）。它的构建侧实测记录写在 [UPGRADE.md](dsh-web-offline/UPGRADE.md) §4。

---

## 6. 新增一个离线包

1. 对照第 2 节确认机器约束是否有变化；新依赖若带原生二进制，先确认架构与 Node 版本窗口。
2. 建 `<组件>-offline/`，按 3.1 布局写 PowerShell 脚本 + 纯 ASCII `.cmd` 双击入口。
3. 全部下载物落 SHA256 进 manifest；安装前校验；预构建树还要在目标机复制后比对文件数与字节数，并记录/校验 `nativePackages`（架构绑定的包）。
4. 实现幂等与续跑：部分完成的目录要能被识别复用。
5. 把该组件在气隙下的**能力边界**写成 `docs\OFFLINE-CAPABILITIES.md`（构建时随 `docs\` 进包），并在安装脚本尾部输出摘要。
6. 若该组件需要升级：按 3.2 第 8 条带 release tarball + 预热 cache，写 `Upgrade-<组件>Offline.ps1` 与 `upgrade.cmd`，流程与回滚声明照 [UPGRADE.md](openclaw-offline/UPGRADE.md) 的模式；`-DryRun` 必须零副作用。
7. 让 bundle **自包含**：构建时把 `install.cmd` / `Install-*.ps1` / `upgrade.cmd` / `Upgrade-*.ps1` / `UPGRADE*.md` 拷进包根。
8. 跨平台构建（如 npmcache 模式）：`--os/--cpu/--force` 钉平台 + `--ignore-scripts`，并用跨平台 copy 派发（robocopy 不可用时就 `Copy-Item`）。
9. 写 `<组件>` 的预检脚本（可复制 `Test-OpenClawOfflineScripts.ps1` 的检查项：解析/5.1 语法面/ASCII/CRLF/锚点内容/**跨文件契约**），**全绿再打包**。
10. 补第 4 节表格里新踩到的坑。
11. 把新包登记进第 5 节表格。

> 未在本仓库做过实机验证的结论，请在文档里明确标注为推断，不要写成既成事实。
