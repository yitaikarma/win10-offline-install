# 构建运行手册（openclaw 离线包）

> 面向**构建机**（有网）。目标机侧请读 `UPGRADE-BRIEF.md` 与 `docs/OFFLINE-CAPABILITIES.md`。
> 本文所有数值都是实测值：`2026.9.5` / `2026.9.9` / `2026.10.3`。

## 0. 一分钟版

| 我要什么 | 在哪台机器 | 命令 |
| --- | --- | --- |
| **app 包**（推荐交付：整树 + cache + tarball，也是升级失败的救援包） | **联网 Windows x64** | `powershell -ExecutionPolicy Bypass -File .\Make-OpenClawOfflineBundle.ps1` |
| **npmcache 包**（只有 cache + tarball，体积小；依赖脚本留给目标机跑） | 任意平台（Windows / macOS / Linux 都行） | `powershell -ExecutionPolicy Bypass -File .\Make-OpenClawOfflineBundle.ps1 -Mode npmcache`<br>（macOS/Linux 把 `powershell` 换成 `pwsh`，路径分隔符用 `/`） |

**两条命令都不需要别的参数**：

- 版本省略 = 取 npm `latest`（当前 `2026.10.3`）；要固定版本才加 `-OpenClawVersion`。
- 输出省略 = 落在**本包目录**下的 `openclaw-offline-bundle\`（跟着脚本走，与当前目录无关），已在 `.gitignore` 中，不会污染 git。
- 出包前必做：`Test-OpenClawOfflineScripts.ps1` **全绿**（只读，不装任何东西）。交付前按 §4 核对产物。

## 1. 前置条件

| 项 | 要求 | 说明 |
| --- | --- | --- |
| 目标平台 | **win32-x64**（脚本钉死 `$TargetPlatform`） | 目标机是气隙 Win10 x64 |
| 构建机（app 模式） | **Windows x64**（Windows on ARM 会被拒绝） | 原生依赖架构绑定，无法在其他平台解析 |
| 构建机（npmcache 模式） | 任意平台 | 用 `--os win32 --cpu x64 --force --ignore-scripts` 交叉预热 |
| Node（构建机） | `>=24.16 <25` 或 `>=26.1`（脚本硬校验，实测 `26.7.0` 可用） | 这是 openclaw 的 `engines.node`。**并且最好与目标机装同一个 Node 版本**：原生依赖的预编译二进制是按「平台+ABI」选的，构建机用什么 Node，目标机就该用什么 Node（脚本会在构建时打印这条提醒）。升级 Node 后要**重开 shell** 让 PATH 生效 |
| npm | 随 Node 即可；11.x / 12.x 都支持 | 脚本会解析 npm 的"未放行脚本"清单并自动补跑一次全量 `--allow-scripts` |
| PowerShell | Windows：**5.1**；macOS/Linux：`pwsh` 7 | 脚本只用 PS 5.1 语法面，两边都能跑 |
| 网络 | `registry.npmjs.org`（必需）；`nodejs.org`（仅 `-IncludeNode`） | 全程只读上游，不写任何 registry |
| 磁盘 | **≥3 GB 空闲**（app 树 ~730 MB + cache ~320 MB + tarball ~100 MB + docs 20 MB + 下载/解包临时） | 升级期间目标机峰值另算，见目标机文档 |
| 输出目录 | 默认 = 本包目录下的 `openclaw-offline-bundle\`（跟着脚本走，已 git 忽略），无需指定 | 只有想放别处才加 `-OutDir`：**用短路径**（如 `D:\oc-bundle`）。npm 11 的嵌套 `node_modules` 路径很深，长路径会踩 MAX_PATH；脚本会拒绝盘根 |

## 2. 步骤 A：Windows x64 出 **app 包**（推荐）

```powershell
cd <仓库>\openclaw-offline

# (1) 可选：核对上游契约（换版本时做一次，见 §7）
npm view openclaw version engines bin openclaw --json

# (2) 交付前预检（只读；必须全绿）
powershell -ExecutionPolicy Bypass -File .\Test-OpenClawOfflineScripts.ps1

# (3) 构建（无参数：版本取 npm latest，输出到本包目录下的 openclaw-offline-bundle\）
powershell -ExecutionPolicy Bypass -File .\Make-OpenClawOfflineBundle.ps1

# (3b) 要连便携 Node 一起打包（目标机上没有 Node 时用）：
# powershell -ExecutionPolicy Bypass -File .\Make-OpenClawOfflineBundle.ps1 -IncludeNode
```

> 只有需要**固定版本**或**换输出目录**时才加参数，例如固定到保守线并放到 D 盘：
> `powershell -ExecutionPolicy Bypass -File .\Make-OpenClawOfflineBundle.ps1 -OpenClawVersion 2026.9.33 -OutDir D:\oc-bundle`

构建过程依次做：解析版本 → 建 staging → `npm install -g openclaw@<版本>`（**app 模式在构建机上跑完依赖安装脚本**）→ 探测启动器 → `npm pack` 出 tarball → 拷文档 → 平台包扫描 → 写 manifest → 残留检查。
**exit 0 + 末尾打印 "Bundle ready" 才算成功。**

## 3. 步骤 B：任意平台出 **npmcache 包**

```powershell
# Windows（PowerShell 5.1）
powershell -ExecutionPolicy Bypass -File .\Make-OpenClawOfflineBundle.ps1 -Mode npmcache

# macOS / Linux（pwsh 7）
pwsh -File ./Make-OpenClawOfflineBundle.ps1 -Mode npmcache
```

与 app 模式的差别：
- 依赖**只下载不执行**（`--ignore-scripts`），安装脚本由**目标机**执行（目标机 npm 11 只告警、12 默认拒绝，安装脚本会自行补跑全量放行）。
- **不创建 `app\`**（否则安装侧的模式推断会误判）；临时 `_cachewarm\` 在扫描完平台包后自动删除。
- 磁盘峰值比 app 模式高（多一份 `_cachewarm`）。

## 4. 产物核对清单（交付前逐项确认）

| # | 检查 | 期望（2026.10.3 实测） |
| --- | --- | --- |
| 1 | `bundle-manifest.json` 存在且 `schemaVersion: 4` | 安装/升级脚本会拒绝更新的 schema |
| 2 | `mode` | `app` 或 `npmcache`，与你要的形态一致 |
| 3 | `targetPlatform` | `win32-x64` |
| 4 | `openClawVersion` | 你指定的版本（不是 `latest`） |
| 5 | `schemaVersions` | **非 null**（10.3 = `{state:20, agent:24}`）；为 null 说明 staging 元数据没读到，别交付 |
| 6 | `nativePackages` | **非空**，且每项都是 `*-win32-x64*` / `*-windows-x64*`；10.3 实测 7 个：`@esbuild/win32-x64`、`@koromix/koffi-win32-x64`、`@lydell/node-pty-win32-x64`、`@openclaw/fs-safe-win32-x64-msvc`、`@trycua/cua-driver-win32-x64-msvc`、`@ubjs/node-win32-x64-msvc`、`sqlite-vec-windows-x64` |
| 7 | `packagedTarball` / `tarballSha256` | 文件名是 `openclaw-<版本>.tgz`；用 `Get-FileHash -Algorithm SHA256` 核对一致 |
| 8 | `appFileCount` / `appBytes`（仅 app 模式） | 与磁盘实际一致（目标机复制后也会比对这两个值）。**Windows 实测**：2026.10.3 = **42,080 文件 / 482.1 MB**（9.9 的 41,406 / 730 MB 是 **macOS** 树，与 win32 树不可直接比） |
| 9 | `docs\` | 有 `docs_map.md`；10.3 抽出 **1296 篇 markdown**（npmcache 模式从 tarball 解出） |
| 10 | 自包含 | 包根有 `install.cmd` / `Install-OpenClawOffline.ps1` / `upgrade.cmd` / `Upgrade-OpenClawOffline.ps1` / `UPGRADE.md` / `UPGRADE-BRIEF.md` |
| 11 | 没有中间产物 | 没有 `_download\`、没有 `_cachewarm\`、没有 `.app-complete`（npmcache 模式） |
| 12 | 整包体积 | npmcache 439 MB（cache 320 + tarball 98 + docs 20）；app 模式 ≈ app 树（10.3 实测 482 MB）+ cache + tarball + docs |
| 13 | **冒烟测试：在构建机上真的跑一遍整树** | 见 §4.1 —— 交付前唯一能证明"原生依赖真的可用"的检查 |

### 4.1 构建机冒烟测试（app 模式强烈建议）

构建机与目标机同为 win32-x64、Node 版本也一致时，这一步的结论可以直接外推到目标机：

```powershell
cd F:\win10-offline-install\openclaw-offline\openclaw-offline-bundle
.\app\openclaw.cmd --version                            # 期望输出 2026.10.3
cd app
node -e "require('koffi'); console.log('koffi ok')"        # 原生模块能被加载
(Get-ChildItem .\node_modules -Recurse -Include *.node,*.dll -ErrorAction SilentlyContinue).Count   # 期望 > 0
```

任何一条抛 `Cannot find module` / `was compiled against a different Node.js version` /
`is not a valid Win32 application` 都**不要交付**：说明依赖安装脚本没跑到，或 Node 版本/ABI 不符，
目标机上一样会挂。

> 注：`openclaw --version` 可能在构建机上创建 `%USERPROFILE%\.openclaw`（构建机是自己的机器，无妨；
> 末尾的残留检查会如实报告）。

**上面这些项 = 一条命令**。`Verify-OpenClawBundle.ps1` 会逐项打印 OK / FAIL，任何一项失败就以非 0 退出（它随包交付，构建机和目标机都能跑）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Verify-OpenClawBundle.ps1
```

脚本在组件目录里、要核对刚出的包时，加一个参数指到包目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\Verify-OpenClawBundle.ps1 -BundleDir .\openclaw-offline-bundle
```

- 覆盖：manifest 字段 → tarball 哈希 → app 树文件数/字节数 → npm cache/app\ 模式一致性 → 记录的原生包是否都在位 → docs → 自包含清单 → **冒烟测试**（仅 app 模式 + win32-x64）。
- `-SkipSmoke` 跳过冒烟测试（它会启动包内 CLI，可能在本机创建 `%USERPROFILE%\.openclaw`）。

## 5. 拷贝到 U 盘并交付

1. **拷整个 bundle 目录**（不要只拷 `app\` 或 `npm-cache\`）：脚本、文档、manifest 都要在。
2. 拷到 U 盘上的一个文件夹，例如 `E:\openclaw-offline-bundle\`。
3. **不要拷**构建侧文件：`_download\`（下载/解包中间产物，若存在）、`_cachewarm\`（npmcache 模式的预热树，正常已删）、`.app-complete`（构建续跑标记，目标机不用）。这三者只在构建机有意义。
4. 目标机插入 U 盘后：
   ```powershell
   cd E:\openclaw-offline-bundle
   Get-ChildItem -Recurse | Unblock-File      # 解除 MOTW，否则脚本/二进制可能拒绝执行
   ```
5. 首次安装双击 `install.cmd`；升级双击 `upgrade.cmd`（升级先 `Upgrade-OpenClawOffline.ps1 -DryRun`，零副作用）。
6. **不要**把 tarball 放在含**逗号**的文件名或父目录下（npm 12 限制）。

## 6. 构建侧常见失败与处置

| 症状 | 原因 | 处置 |
| --- | --- | --- |
| `Mode app must run on Windows` / `must be built on Windows x64` | 在非 Windows 或 ARM 上跑 app 模式 | 换 Windows x64，或改用 `-Mode npmcache` |
| `Refusing to use a drive root as -OutDir` | `-OutDir` 指到盘根 | 换成子目录，如 `D:\oc-bundle` |
| `... already exists ... and is not a previous bundle` | 输出目录里有别的东西 | 换目录，或确认可删后加 `-Force` |
| `The staged tree resolved packages for the wrong platform` | 解析出了非 win32 的包 | 用 Windows x64 出 app 包；npmcache 用 `--os/--cpu` 钉平台（脚本已带） |
| `No win32-x64 platform package was found under ...`（!! 提示） | 交叉预热没拉到可选依赖，或 prefix 布局异常 | 不要交付；检查网络/缓存后重跑。若持续出现，用 Windows x64 出 app 包 |
| `npm install failed with exit code N` | 网络抖动/代理/registry 不可达 | 脚本已自动重试 3 次（退避 5/10s）；仍失败看 npm 原始输出（`DEPTH_ZERO_SELF_SIGNED_CERT` = TLS 中间人，换网络或给 npm 配好 CA） |
| `EPERM` 且路径是 `~/.npm` | 构建机 npm 默认 cache 被 root 占过（陷阱 19） | 设 `$env:npm_config_cache = 'D:\npmcache-tmp'` 后重跑；**不要** `sudo chown` 用户目录 |
| `Could not resolve the latest openclaw version from npm (npm exit 1)` | 同上：解析 `latest` 调的 `npm view` 走的是 npm **默认** cache（此时包内 cache 还不存在） | 与上一行同样处置；或干脆 `-OpenClawVersion <版本>` 固定版本（脚本对 `npm view` 的输出做了版本号形状校验，不会再拿报错文本当版本） |
| `Split-Path : 无法将参数绑定到参数"Path"，因为该参数为空字符串`（或任何 `$PSScriptRoot`/`Join-Path` 空参报错） | 某些 Windows PowerShell 宿主里 `$PSScriptRoot` 在 `param()` 默认值 / 脚本块里会绑成**空串**，`Split-Path` 因而拒绝 | 已修（四个脚本统一改为在**正文**里解析 `$scriptDir`：`$PSScriptRoot` → `$MyInvocation.MyCommand.Path` → 当前目录）。若你的副本仍在报：`git pull` 或重新拷贝这四个脚本 |
| `Cannot read the staged package metadata ...` | staging 树不完整（上次中断） | 重跑（可续跑）；仍失败加 `-Force` 清空重建 |
| `Staged tree drifted: requested X but ... Y` | npm 落盘的版本与请求不一致 | 检查 `-OpenClawVersion` 写对；必要时清空重建 |
| `Expand-Archive`/Node 相关失败（仅 `-IncludeNode`） | Node zip 下载不完整 | 删掉该 zip 重跑（断点续传），或省略 `-IncludeNode` |
| 预检报锚点漂移（`README anchor 'Make:..' no longer points at ...`） | 你改过被 README 链接的脚本行号 | `Select-String -Path README.md -Pattern 'Make:\d+'` 找到旧标签 → 用 `Select-String` 在脚本里定位标记行 → 更新 README 里的标签/`#L` 锚点 **和** `Test-OpenClawOfflineScripts.ps1` 的 `$anchorExpectations` 键 |

## 7. 换版本时的核对清单（发新版只重打包，不改脚本）

上游发新版**不需要改脚本**：版本号、artifact、schema、原生包清单都是读出来的；只有"跨版本稳定"的契约被钉死，并由预检断言守住。每次换版本用真实包核一遍这 7 条（范例：`UPGRADE.md` §3.2）：

```powershell
npm view openclaw version dist-tags engines bin openclaw --json
```

| 契约 | 期望 | 变了怎么办 |
| --- | --- | --- |
| `engines.node` | 仍是 `>=24.16.0 <25 \|\| >=26.1.0` | 改 Make/Install 的 `$NodeFloor`/`$NodeCeiling`/`$NodeAltFloor` **和**预检里的三条断言 |
| `bin` | 仍是 `openclaw` → `openclaw.mjs` | 改 Make 的启动器探测（`$launcher` 条件） |
| `openclaw.updateAdmissionProtocol` | 仍是 1 | 升级流程的 first-hop 判定要重读官方文档 |
| `openclaw.schemaVersions` | 会逐版递增（10.3 = state 20 / agent 24） | 无需改代码；更新 `UPGRADE.md` §2.8/§3.2 与目标机文档里的数字，并提醒"回滚只能靠备份" |
| `docs/` 仍随包发布 | 有 `docs/docs_map.md` | 若不再随包发布，npmcache 模式的文档抽取要换来源 |
| 脚本用到的 CLI 参数 | `--tag/--dry-run/--yes/--no-restart`、`backup create --output/--verify`、`config set`、`gateway install --force`、`doctor --post-upgrade`、`qr --setup-code-only`、`onboard --*` 等 | 缺哪个就改对应脚本与 `UPGRADE.md` |
| CHANGELOG 无破坏性变更/配置迁移 | 读包内 `CHANGELOG.md` 最新一节 | 有破坏性变更时按官方说明改流程 |

## 8. 交付前最后一遍

1. `Test-OpenClawOfflineScripts.ps1` → `All checks passed.`
2. §4 核对清单全过（尤其第 5、6、7、11 项）。
3. **在目标机上**（U 盘拷贝完成后、安装之前）跑一次随包交付的校验脚本——它证明"拷贝没坏"，一条命令：

   ```powershell
   cd E:\openclaw-offline-bundle
   Get-ChildItem -Recurse | Unblock-File
   powershell -ExecutionPolicy Bypass -File .\Verify-OpenClawBundle.ps1
   ```

4. 记下本次交付的版本与 tarball 哈希，连同 U 盘一起交接（目标机侧会把这行写进它的 `RECON.txt`）。
