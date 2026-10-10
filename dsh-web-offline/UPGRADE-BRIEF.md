# 目标机执行说明：离线升级 dsh web

> 给气隙 Win10 机器前的操作者。设计原理见 [UPGRADE.md](UPGRADE.md)；本文件只讲“怎么做”。
> 前提：这台机器已经用本包安装过（`C:\DshWeb\current.txt` 存在）。

## 0. 准备

把**新 bundle 整个文件夹**从 U 盘拷到本机（例：`D:\dsh-bundle-0.2.1\`），然后在 PowerShell 里：

```powershell
cd D:\dsh-bundle-0.2.1
Get-ChildItem -Recurse | Unblock-File      # 必须：U 盘来的文件带 MOTW，不解除会被拦
```

确认 Node 在 PATH 且够新（新版本可能抬高下限）：

```powershell
node -v                                    # 需要 >= 22.19，登记的已知良好窗口 >=24.16 <25 或 >=26.1
```

## 1. 先看计划（不改任何东西）

```powershell
powershell -ExecutionPolicy Bypass -File .\Upgrade-DshWebOffline.ps1 -DryRun
```

或者双击 `upgrade.cmd` 后再手动跑上面这条（`upgrade.cmd` 不带参数就是直接升级）。
`-DryRun` 会打印：当前版本 / 包内版本 / 是否降级 / 新版本目录 / 端口 / 状态大小 / 快照路径 / 安装步骤。
它**不备份、不停服、不改文件**。

## 2. 正式升级

双击 `upgrade.cmd`，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\Upgrade-DshWebOffline.ps1
```

脚本按固定顺序做 7 件事（顺序本身就是安全设计）：

1. 校验 bundle（manifest、release tarball 的 SHA256、Node 下限、cache 非空）
2. **备份** `%USERPROFILE%\.dsh` → `C:\DshWeb\backups\dsh-home-<时间戳>\`（备份为空则中止升级）
3. 停掉 Web UI（计划任务 + 端口占用进程），**等到端口真正释放**
4. 把新版本装进 `C:\DshWeb\versions\<新版本>\`（此步不动 `current.txt`）
5. 校验新树：版本号、win32-x64 原生包、启动器
6. 切换 `current.txt`
7. 启动 + 冒烟（`dsh --version` + HTTP 探测 + 取回 activation URL）

看到 `Upgraded to dsh <新版本>.` 即成功。成功输出里会有：

- `previous version`：旧版本号（**仍然装着**，是回滚点）
- `rollback`：回滚命令
- `state backup`：状态快照路径
- `activation URL`：这次启动的访问地址（token 每次启动重铸，见 `docs\WEB-SURFACE.md`）

## 3. 失败怎么办

- 第 4–7 步任一失败：脚本**自动**把 `current.txt` 改回旧版本并重启，然后以非 0 退出并打印原因。
  此时旧版本应该已经恢复服务；如果没起来，手工执行：

```powershell
C:\DshWeb\bin\stop-web.cmd
Set-Content C:\DshWeb\current.txt "0.2.0-rc.2"        # 换成旧版本号
C:\DshWeb\bin\start-web.cmd
```

- 报错信息里若出现 `Could not stop the Web UI on port 3080`：说明还有进程占着端口，脚本**拒绝**在
  旧服务活着时换安装树。先手工 `C:\DshWeb\bin\stop-web.cmd`，或
  `netstat -ano | findstr :3080` 找到 PID 后 `taskkill /pid <PID> /t /f`，再重跑。
- 报错 `App tree file count mismatch` / `hash mismatch`：bundle 或 U 盘介质损坏，**不要在
  这台机器上继续**，回构建侧重做一份。
- 报错里出现 `command failed` + `node ./cnoke.cjs ... --prebuild`（koffi 的安装脚本）：
  说明放行安装脚本后，原生依赖没能在本机就位。先确认 Node 版本在 manifest 的 `nodeFloor` 之上；
  仍失败就换 **app 模式**的 bundle（构建侧必须在 Windows x64 上打包），不要在这台机器上反复重试。
- 报错 `Offline npm install failed`：bundle 的 `npm-cache\` 与该 npm/Node 组合不匹配，
  或 cache 被删过。重建 bundle。

## 4. 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\Upgrade-DshWebOffline.ps1 -List      # 看装了哪些版本
powershell -ExecutionPolicy Bypass -File .\Upgrade-DshWebOffline.ps1 -Rollback  # 退回上一个版本
```

- `-Rollback` 默认退回 `last-known-good.txt` 记录的版本，否则退回另一个已装版本；
  也可以指定 `-RollbackTo 0.2.0-rc.2`。
- **二进制回滚 ≠ 状态回滚**。升级时新版本可能已把 `%USERPROFILE%\.dsh` 里的会话/设置前向迁移，
  旧构建随后可能打不开。要真正回到升级前的状态：

```powershell
C:\DshWeb\bin\stop-web.cmd
robocopy "C:\DshWeb\backups\dsh-home-20261009-221500" "$env:USERPROFILE\.dsh" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1
C:\DshWeb\bin\start-web.cmd
```

  每个快照目录里有 `BACKUP-INFO.txt`，写着来源版本、目标版本、时间和恢复命令。

- 插件不能离线降级：若新本体下某插件不兼容，编辑
  `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` 把该行 `disabled: true`（或回滚本体）。
- 旧版本目录不会自动删除。磁盘紧张时手工删 `C:\DshWeb\versions\<旧版本>`，
  但要清楚这等于放弃回滚点。

## 5. 升级后自检

```powershell
C:\DshWeb\bin\dsh.cmd --version                     # 新版本号
C:\DshWeb\bin\web-url.cmd                           # 取当前 activation URL
C:\DshWeb\bin\stop-web.cmd                          # 需要时停服
Get-Content "$env:USERPROFILE\.dsh\profiles\web\cordis.patch.yml"   # provider/插件配置是否还在
```

浏览器用 `web-url.cmd` 输出的地址打开一次，确认 UI 能渲染、模型路由还在、历史会话可读。

## 6. 升级前检查清单

- [ ] 新 bundle 完整（`bundle-manifest.json`、`app\` 或 `npm-cache\`、`dsh-*.tgz`、`docs\`）
- [ ] 已 `Unblock-File`
- [ ] `node -v` 满足 manifest 里的 `nodeFloor`（默认 22.19.0）
- [ ] C: 可用空间 ≥ 2 GB
- [ ] 已跑过 `-DryRun`
- [ ] 已知晓回滚命令与快照路径
