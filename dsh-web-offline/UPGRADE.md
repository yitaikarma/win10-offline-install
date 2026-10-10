# dsh-web-offline 升级方案

> 构建侧设计与回滚矩阵。目标机执行步骤见 [UPGRADE-BRIEF.md](UPGRADE-BRIEF.md)。
> 本文结论标注：**实测** = 构建侧（macOS + Node 26.7.0 + `@deepseek-ai/dsh@0.2.0-rc.2`）验证过；
> **未验证** = 尚未在真实 Win10 气隙机上复核。

## 1. 为什么没有“官方 updater”

dsh 与 openclaw 不同：**本体没有自更新命令**。`dsh --help` 暴露的只有 profile 启动族
（`dsh web` / `dsh plugin` / `--dump-config` 等），没有 `dsh update`。
上游对“更新本体”的定义就是**换一个包来源重新启动**（npx 换版本、全局 npm 前缀换版本、源码重构建）。

因此本包的升级 = **把新版本装到旧版本旁边，切换启动器，重启**。这对气隙环境反而更友好：
不需要任何“回源”能力，而且旧版本原地保留 → 回滚就是改一行 `current.txt`。

## 2. 两套独立体系，别混

| 层 | 内容 | 离线可升级？ |
| --- | --- | --- |
| 本体 | CLI + Web 界面 + 运行时（`@deepseek-ai/dsh` 及其依赖树） | **可以**，本包升级脚本负责 |
| 插件 | `%USERPROFILE%\.dsh\profiles\web\node_modules` 里的扩展 | **不可以**：`dsh plugin --profile web add/update` 把参数转发给 pnpm，需要 npm registry |

- 本体升级**不会**带着插件升，插件升级也**不会**改本体。
- 换新本体后如果某个插件与新版不兼容，表现为插件不激活（启动报告里 `N required plugins did not activate`
  之类的信息会进 `%USERPROFILE%\.dsh\logs\startup-*.log`）。离线处理办法：在
  `profiles\web\cordis.patch.yml` 里 `disabled: true` 掉该行，或者用 `upgrade.cmd -Rollback` 退回。
- 想让离线机的插件也升级：只能在构建侧把插件包与依赖树一起打进 bundle（本包暂不覆盖）。**未验证**。

## 3. 版本化安装根（本包的核心不变式）

```
<InstallRoot>\
  versions\0.2.0-rc.2\     已装版本，仍然可用
  versions\0.2.1\          新版本
  current.txt              当前生效版本（只有切换成功后才改）
  last-known-good.txt      -Rollback 的默认目标
  backups\dsh-home-<时间戳>\   升级前的状态快照
  bin\dsh.cmd              读 current.txt 的版本无关启动器（PATH 只加 bin）
```

不变式：

1. **`current.txt` 只在“新版本已装好且校验通过”之后才改写**；写之前任何失败都等于没发生。
2. **切换之后**的失败（起不来、冒烟失败）由脚本自动把 `current.txt` 改回旧版本并重启。
3. `bin\` 与用户 PATH 在升级过程中**不变**——所以升级不需要注销/重登，也不会有 PATH 残留。
4. 旧版本目录不自动删除：它是回滚点。磁盘紧张时手工 `Remove-Item versions\<旧版本>`，
   但要清楚这等于放弃二进制回滚。

## 4. 构建侧：两种包模式

| 模式 | 内容 | 能在哪构建 | 安装脚本干什么 |
| --- | --- | --- | --- |
| `app` | 预构建 win32-x64 树（`app\`） | **仅 Windows x64** | robocopy 到 `versions\<新版本>`，比对文件数/字节数 |
| `npmcache` | 预热的 npm cache + release tarball | 任意平台（本 macOS 检出即可） | 目标机自己跑 `npm install -g <artifact> --offline` |

**npmcache 模式的交叉预热必须用 `--ignore-scripts`。** 理由（**实测**）：
依赖的安装脚本在**构建机**平台上执行——macOS 上 warm `--os=win32 --cpu=x64` 时，`koffi` 找不到
（本机平台的）预编译二进制，回退到 cmake 源码构建，`fatal error: 'algorithm' file not found`，
整个 `npm install` 失败。所以：

- warm 阶段只**下载**：`--ignore-scripts`，把 win32-x64 的 optional 依赖（`@koromix/koffi-win32-x64`、
  `@img/sharp-win32-x64`、`@vscode/ripgrep-win32-x64`、`sherpa-onnx-win-x64`、
  `@deepseek-ai/libreoffice-kit-win32-x64`、`node-addon-require-builtin-win32-x64-msvc`）解析进 cache；
- 安装脚本**在目标机**执行，此时预编译二进制与平台匹配。

**实测验证链**（构建侧 macOS + Node 26.7.0 + npm 11.19.0，2026-10-09/10）：

1. 手工 warm：`npm install -g @deepseek-ai/dsh@0.2.0-rc.2 --os=win32 --cpu=x64 --ignore-scripts`
   → 成功，cache 282 MB（对照：同一命令**不加** `--ignore-scripts` 会在 koffi 处 cmake 构建失败）；
2. 干净前缀 + `--offline` 从同一 cache 再装一次 → 成功，树 531 MB / 26,582 文件；
3. 六个 win32-x64 原生包**全部到位**，且树里**没有任何** darwin/linux 平台包；
4. `npm pack` 出的 `deepseek-ai-dsh-0.2.0-rc.2.tgz` 用 `--offline` 安装 → 成功（升级路径）；
5. **整跑构建脚本**：`Make-DshWebOfflineBundle.ps1 -Mode npmcache` 在 macOS 上 exit 0，
   产出 bundle 293 MB（cache 287 MB / 2,333 文件、docs 6.6 MB / 568 页、tgz 的 SHA256 与 manifest 一致、
   `_cachewarm` 中间产物自动清理）；
6. **整跑目标机安装路径**：用 **bundle 自带的 `npm-cache`** 执行
   `npm install -g <bundle>/dsh-<版本>.tgz --offline --os win32 --cpu x64` → 成功，
   再用 `Install-DshWebOffline.ps1` 里的原生包校验逻辑复核该树 → 6/6 通过。

> 注意第 6 步里的 `--os win32 --cpu x64`：在 macOS 上**不加**这两个参数会按宿主平台解析出
> darwin 依赖（实测如此），所以本地复现目标机时必须显式带上。安装/升级脚本本身也显式带这两个参数，
> 使目标机的解析与 cache 预热完全一致，而不依赖宿主平台探测。

7. **整跑安装脚本**（在 macOS 上跑到 Windows 专有步骤为止）：`Install-DshWebOffline.ps1
   -BundleDir <bundle> -InstallRoot <dir>` 依次通过 bundle 校验（含 tgz 的 SHA256）→ Node 下限 →
   用 **bundle 自带的 cache** 离线落盘（536 包，12 s）→ **原生包校验 6/6 通过**，随后停在
   “No dsh launcher found” —— 这是宿主平台差异，不是缺陷：Windows 上 npm 会在前缀根生成
   `dsh.cmd`/`dsh.ps1`，而 macOS 上是 `bin/dsh`（无扩展名，与 openclaw 包相同的布局假设）。
   第 4–7 步里依赖 Windows 的部分（robocopy、计划任务、launcher、冒烟启动）仍未实机验证。

> 反向证据：把第 7 步里的 `npm_config_ignore_scripts` 去掉（即按脚本默认行为放行安装脚本）后，
> 安装会在 **koffi 的 `cnoke --prebuild`** 处失败——因为脚本在构建机平台上找不到预编译二进制，
> 回退 cmake 源码构建而失败。这既解释了 `--ignore-scripts` 的必要性，也说明 **npmcache 模式依赖
> 目标机自己跑通这些脚本**；目标机是 win32-x64，预编译在位（见第 4 节实测），但若目标机上仍失败，
> 就该改用 app 模式（在 Windows x64 上构建）。

**app 模式仍然是首选**：安装脚本零网络、零 npm 解析，且原生依赖是在目标平台上装好的。

## 5. 目标机流程（`Upgrade-DshWebOffline.ps1`）

1. **校验 bundle**：manifest schema、`mode`、release tarball 的 SHA256、Node 下限、npm cache 非空。
2. **先备份**：`robocopy %USERPROFILE%\.dsh` → `backups\dsh-home-<时间戳>`，写 `BACKUP-INFO.txt`（含恢复命令）。
   备份为空 → 直接中止（宁可升不了，也不要没退路）。`-SkipBackup` 显式跳过。
3. **停服**：`Stop-ScheduledTask DshWeb`，再杀掉仍监听端口的进程，**等到端口真正释放**（最多 30 s）；
   释放不了就中止——绝不在旧服务还活着时换安装树。
4. **装新版本**到 `versions\<新版本>`：app 用 robocopy + 计数校验；npmcache 用
   `npm install -g <tarball 或包名> --prefix versions\<新版本> --offline --cache <bundle>\npm-cache --allow-scripts=<manifest 列表>`，
   并检查 npm 是否仍报告跳过安装脚本（有则报错）。**此步不动 `current.txt`**。
5. **校验新树**：`@deepseek-ai/dsh` 版本号一致、win32-x64 原生包齐全、启动器在位。
6. **切换** `current.txt` → 新版本；写 `last-known-good.txt`。
7. **启动 + 冒烟**：`dsh --version`、HTTP 探测（401 视为“活着”，见 `docs/WEB-SURFACE.md`）、从
   `web-console.log` 取回 activation URL。

失败处理：第 4–7 步任一失败 → **自动把 `current.txt` 改回旧版本并重启**，然后抛出错误并给出
状态快照路径。`-DryRun` 只做校验 + 打印计划，不备份、不停服、不改动任何东西。

## 6. 回滚矩阵

| 想回滚什么 | 怎么做 | 能不能真的回滚 |
| --- | --- | --- |
| 本体二进制 | `upgrade.cmd -Rollback`（或 `-RollbackTo <版本>`） | **能**：旧版本目录还在，`current.txt` 一行切换 |
| 本体（升级失败中途） | 脚本自动做，无需人工 | **能** |
| 状态（`~/.dsh`：会话/设置/凭据/profile） | 停服后把 `backups\dsh-home-<时间戳>` 覆盖回 `~/.dsh` | **只能靠备份**：状态迁移是单向的，旧构建可能拒绝打开新状态 |
| 插件 | 装回旧本体后仍不兼容时，禁用该插件行 | 只能“禁用”，不能离线降级插件包 |
| npm cache / 包本体 | 直接删掉 bundle 或 `versions\<版本>` | 与运行状态无关 |

状态为什么只能靠备份：0.2.0 一代做了 **Session V4 迁移**与**设置迁入 profile 插件配置**
（`settings.yaml` → `profiles/web/cordis.patch.yml`），上游更新说明明确要求升级前备份 `~/.dsh`。
本包不重复实现迁移逻辑，只是把“备份”做成升级脚本的强制第 2 步。**未验证**（未在本包实机复现迁移）。

## 7. 升级前检查清单

- [ ] 目标机 Node ≥ 22.19（新版本可能抬高下限，脚本会按 manifest 的 `nodeFloor` 拦截）
- [ ] C: 至少 2 GB 可用空间（新树 ~531 MB + 旧树 + 状态快照）
- [ ] 新 bundle 里 `bundle-manifest.json`、`app\`（app 模式）或 `npm-cache\`（npmcache 模式）、`dsh-*.tgz` 齐全
- [ ] U 盘拷来的文件已 `Get-ChildItem -Recurse | Unblock-File`
- [ ] 先跑 `-DryRun` 看计划
- [ ] 记下 `-Rollback` 命令与快照路径，贴在工作单上

## 8. 未验证项

- [ ] 未在真实 Windows 10 气隙机上跑过一次完整升级与回滚。
- [ ] 计划任务在普通用户下的注册成功率（脚本有 Startup 文件夹回退，但未实测）。
- [ ] `npm 12` 默认拒绝安装脚本时，`--allow-scripts=<列表>` 是否覆盖全部必需包（脚本会检测并报错，
      但未在 npm 12 上实测）。
- [ ] 跨大版本（例如 0.2.x → 0.3.x）的状态迁移表现。
