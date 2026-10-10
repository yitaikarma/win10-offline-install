# 离线能力边界（dsh web）

> 目标机：气隙 Windows 10 x64，普通用户，无管理员，内网可达。
> 本文件随离线包交付，是目标机上唯一的权威说明——目标机读不到仓库、也读不到官网。
>
> 标注约定：**实测** = 在构建侧（macOS + Node 26.7.0 + `@deepseek-ai/dsh@0.2.0-rc.2`）验证过；
> **未验证** = 尚未在真实 Win10 气隙机上复核，属推断。

## 1. 前提

| 项 | 要求 | 依据 |
| --- | --- | --- |
| 系统 | Windows 10 x64（安装脚本硬校验 `PROCESSOR_ARCHITECTURE=AMD64`） | 脚本 |
| Shell | Windows PowerShell 5.1（脚本刻意只用 5.1 语法面） | 脚本 |
| Node | **>= 22.19.0**；登记的已知良好窗口 `>=24.16 <25` 或 `>=26.1` | 依赖树 engines（`@deepseek-ai/libreoffice-kit`、`@earendil-works/pi-ai` 均声明 `>=22.19.0`） |
| npm | 随 Node；`>=11.16` 需要显式放行安装脚本，`npm 12` 起默认拒绝 | 见第 4 节 |
| 网络 | 安装、启动均**不需要**外网；模型推理走内网端点 | **实测**（构建侧断网环境代理指向关闭端口仍可启动并渲染 UI） |
| 权限 | 全程用户级：不写 HKLM、不装服务、PATH 只改用户级 | 脚本 |

## 2. 能做什么

- `dsh web`：把 Web UI 起在 **loopback**（默认 `127.0.0.1:3080`），用本机浏览器访问。**实测**：全新 `DSH_HOME` 首启即可渲染，`web` profile 的两个 bundle（`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app`）直接从**安装树**解析，**不需要 pnpm install、不需要 registry**。
- 本地会话：会话历史、附件、检查点全部落在 `%USERPROFILE%\.dsh`。**实测**（目录结构）。
- Windows 工具面：`dsh-base` 的 bundle 行按平台门控——win32 上 `dsh-pwsh-sandbox` / `dsh-tool-pwsh` 生效，`dsh-bash-sandbox` / `dsh-tool-bash` 被 `disabled`。**实测**（`--dump-config` 输出）。
- 模型推理：指向内网 OpenAI 兼容端点即可，配置**完全离线**（见 `LLM-ENDPOINT.md`）。**实测**（patch 组合成功）。
- CLI：`dsh --version`、`dsh --profile web --dump-config`、`dsh --profile web --help` 等本体命令不触网。**实测**。
- 离线文档：`docs\` 内含各官方包自带的 `README.md` / `README.zh.md`（与所装版本一致）。

## 3. 不能做什么（离线时的预期失败，不是故障）

| 功能 | 现象 | 原因 |
| --- | --- | --- |
| 插件市场 / `dsh plugin --profile web add <pkg>` | 失败 | 该命令把参数转发给 **pnpm**，需要 npm registry |
| 网页搜索、抓取页面 | 工具报错 | 需要外网 |
| 账号登录（OAuth）、云端遥测 | 失败或静默跳过 | 需要外网 |
| 公网 provider（OpenAI/Anthropic/DeepSeek 官方等） | 请求超时 | 需公网；只能用内网端点 |
| `dsh --profile desktop` | 直接被拒 | 桌面 profile 由 Electron 应用独占（`dsh` 显式 `rejectElectronProfile`） |
| 自动更新 | 无此命令 | dsh 本体不提供自更新（`dsh --help` 无 `update`），升级只能换包 |

## 4. 原生依赖与安装脚本（air-gap 下最脆的一环）

win32-x64 安装树里的架构绑定包：

| 包 | 大小（**实测**，win32 解析结果） |
| --- | --- |
| `@deepseek-ai/libreoffice-kit-win32-x64` | 189 MB |
| `sherpa-onnx-win-x64` | 23 MB |
| `@img/sharp-win32-x64` | 19 MB |
| `@vscode/ripgrep-win32-x64` | 5.7 MB |
| `@koromix/koffi-win32-x64` | 1.0 MB |
| `node-addon-require-builtin-win32-x64-msvc` | 0.35 MB |
| `node-pty` | 不另发包，tarball 内含 `prebuilds/win32-x64` |

必须真正执行安装脚本的包：`koffi`、`node-pty`、`protobufjs`、`@deepseek-ai/dsh-subprocess-local`。

- `npm >= 11.16`：只在 `--allow-scripts=<包名>` 里列出的包会跑脚本（其余只警告）；
  `npm 12` 起**默认拒绝**。安装脚本已按 manifest 的 `installScripts` 自动放行，并在结束后
  检查 npm 是否仍报告 `install-scripts ... skipped`，有则**直接报错中止**——半残的原生依赖不会静默通过。
- `node-pty` 的 `install` 脚本只做一件事：检查 `prebuilds/<platform>-<arch>` 目录是否存在，存在就退出 0，
  不存在才回退 `node-gyp rebuild`。**实测**：`prebuilds/win32-x64/` 里确实有
  `conpty.node`、`conpty_console_list.node`、`conpty` 等预编译产物 → 气隙机上无需编译器、无需下载。
- `koffi` 的 `install` 脚本用 `@koromix/koffi-win32-x64` 里的预编译二进制；拿不到预编译就会回退到
  cmake 源码构建，那在气隙机上必失败。**实测**：该包含 `win32_x64/koffi.node` → 预编译在位。
  也因此 **app 模式的包必须在 Windows x64 上构建**；npmcache 模式则由目标机自己跑这些脚本。
- `@deepseek-ai/dsh-subprocess-local` 的 `postinstall` 只是给 `prebuilds/<platform>/spawn-helper`
  补可执行位（**实测**：读脚本确认），Windows 上没有该文件 → 实际是无操作。
- 安装脚本在**目标机**执行，所以 `npm install` 显式带 `--os win32 --cpu x64`：与构建侧预热 cache 时
  用的平台完全一致，不依赖目标机 npm 的宿主平台探测。native 包清单校验是最后一道闸。
- **未验证**：以上脚本在真实 Windows 10 上的端到端执行结果（只验证了包内容、脚本逻辑，以及在
  macOS 上以 `--os=win32 --cpu=x64` 复现的完整解析与落盘链路）。
- **失败长什么样**：宿主平台与预编译不匹配时，koffi 的脚本会打印
  `Failed to load prebuilt binary, rebuilding from source` 然后以
  `fatal error: 'algorithm' file not found` 结束，整个 `npm install` 失败。
  在目标机（win32-x64）上不应出现；一旦出现，改用 app 模式 bundle（见 `UPGRADE-BRIEF.md`）。

## 5. 体积与磁盘

**实测**（在构建侧用 `--os=win32 --cpu=x64` 解析/落盘的 win32-x64 数据；作为量级参考，非 Windows 实机数字）：

| 项 | 大小 |
| --- | --- |
| 单个版本树（`versions\<版本>`） | ~534 MB / 26,582 文件 |
| 预热 npm cache（`npm-cache\`） | ~287 MB / 2,333 文件 |
| npmcache 模式整包（cache + tgz + docs） | **~293 MB**（其中 docs 6.6 MB / 568 页） |
| app 模式整包（树 + cache + tgz + docs） | ~820 MB |
| 两版本并存（升级后保留旧版以便回滚） | ~1.1 GB |

升级期间峰值 = 新版本树 + 旧版本树 + 状态备份，建议预留 **2 GB** 以上。拷 U 盘前可删掉包里的
`_download\`；`npm-cache\` 只在 npmcache 模式安装和离线升级时需要。

## 6. 数据与状态

| 路径 | 内容 | 升级时 |
| --- | --- | --- |
| `%USERPROFILE%\.dsh\profiles\web\` | profile 清单、patch 层、插件 | **迁移**：旧版本可能拒绝打开新版本迁移过的状态 |
| `%USERPROFILE%\.dsh\sessions\` | 会话历史（Session V4） | 同上 |
| `%USERPROFILE%\.dsh\.credentials.yaml` | 凭据（浏览器会话、provider key 引用） | 升级脚本会整体备份 |
| `%USERPROFILE%\.dsh\logs\` | 启动诊断 `startup-*.log` | — |
| `%InstallRoot%\web-logs\` | Web 服务控制台输出（含 activation URL） | — |
| `%InstallRoot%\backups\` | 升级前的状态快照 | 升级脚本第 2 步创建 |

`$env:DSH_HOME` 可覆盖 `.dsh` 位置，安装脚本也会尊重它。

## 7. 端口与安全

- 默认只绑 **loopback**（`127.0.0.1:3080`）。dsh **自身拒绝** `--host 0.0.0.0`，理由是那等于把
  具备本机读写/执行能力的 agent 运行时暴露给网络（源码注释原文：would expose remote code execution）。
- 浏览器访问受 **browser-trust fence** 保护：`GET /` 无有效签名 cookie 时返回 **401**（"dsh web
  authentication required; reopen the URL printed by dsh web."）。启动时打印的 activation URL
  （`http://127.0.0.1:3080/?token=<每次启动重铸>`）访问一次即种下 cookie。**实测**：401 → token URL
  303+Set-Cookie → 带 cookie 的 `GET /` = 200（34 KB，含 `__DSH_BOOT__`）。
- 如确需让内网其他机器访问：`--host <本机内网IP> --trusted-host <ip:port>`。**这是把 agent 暴露到
  局域网**，等同于把本机代码执行权交给网络上的任何人——除非该内网与目标机同等可信，否则不要做。
- 不落明文密钥：provider key 走环境变量引用（`apiKeyEnv`），见 `LLM-ENDPOINT.md`。

## 8. 未验证项（不要当成既成事实）

- [ ] 全部结论未在真实 Windows 10 气隙机复核；原生依赖、计划任务、notepad 渲染均属推断。
- [ ] koffi / node-pty 的安装脚本在 Windows 上的实际行为（只验证了逻辑与包内容）。
- [ ] 目标机 nvm-windows 的实际版本（必须 ≥ 22.19）。
- [ ] 内网模型端点的真实地址与模型清单。
- [ ] 内网是否需要代理访问该端点（dsh 支持 `HTTP(S)_PROXY`，但本包未配置）。
- [ ] 长时间运行下的内存/句柄占用。
