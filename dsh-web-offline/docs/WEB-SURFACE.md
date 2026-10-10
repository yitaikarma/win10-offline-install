# Web 服务的启动、访问与停服

安装根下与 Web 服务相关的文件（`<InstallRoot>` 默认 `C:\DshWeb`）：

```
bin\dsh.cmd        版本无关的 dsh 启动器（读 current.txt）
bin\start-web.cmd  前台启动 Web UI（host/port 已写死为安装时的取值）
bin\stop-web.cmd   停计划任务 + 杀掉仍占用端口的进程
bin\web-url.cmd    打印“当前这次启动”的 activation URL
web-logs\web-console.log   服务的控制台输出（含 activation URL）
current.txt        当前版本号
versions\<版本>\   npm 全局前缀（dsh.cmd + node_modules）
```

## 1. 访问：activation URL 是必需的

dsh 的 Web 面有一道 browser-trust fence：

- 直接开 `http://127.0.0.1:3080/` → **401** `dsh web authentication required; reopen the URL printed by dsh web.`
- 必须先用**启动时打印的 activation URL** 访问一次：
  `http://127.0.0.1:3080/?token=<一长串>` → 303 + 种下签名 cookie → 之后 `http://127.0.0.1:3080/` 正常。

**token 每次启动都会重铸**（实测同一 `DSH_HOME` 连续两次启动 token 不同），所以没有“固定网址”可以收藏。
拿当前 URL 的办法：

```powershell
C:\DshWeb\bin\web-url.cmd
```

它从 `web-logs\web-console.log` 里取最后一条 `?token=` 行。服务刚起来时日志可能还没写，稍等几秒再跑一次。

> 直接在窗口里跑 `bin\start-web.cmd` 时会话窗口就是控制台，URL 直接打在上面，不用查日志。

## 2. 启动 / 停止

| 目的 | 命令 |
| --- | --- |
| 现在启动（前台，看得到日志） | `C:\DshWeb\bin\start-web.cmd` |
| 换端口启动 | `C:\DshWeb\bin\start-web.cmd --port 3099`（临时；下次仍用默认端口） |
| 停止 | `C:\DshWeb\bin\stop-web.cmd` |
| 查开机自启任务 | `Get-ScheduledTask -TaskName DshWeb` |
| 立即启动任务 | `Start-ScheduledTask -TaskName DshWeb` |
| 删除开机自启 | `Unregister-ScheduledTask -TaskName DshWeb -Confirm:$false` |

安装脚本默认注册**用户级**计划任务 `DshWeb`（登录时启动，不需要管理员）。若注册失败会回退为
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\DshWeb.cmd`；用 `-NoService` 可以完全不要自启。

无论是任务还是回退入口，输出都重定向到 `web-logs\web-console.log`（每次启动覆盖写），
所以 `web-url.cmd` 总能拿到当前这次启动的 URL。

## 3. 只绑 loopback（默认，别轻易改）

- 默认 `--host 127.0.0.1`。dsh **自身拒绝** `--host 0.0.0.0`，因为那等于把具备本机读写/执行能力的
  agent 暴露给网络。
- 要让内网别的机器访问，只能显式指定本机内网地址，并放行浏览器信任围栏：

```powershell
C:\DshWeb\bin\start-web.cmd --host 10.0.0.5 --trusted-host 10.0.0.5:3080
```

  改完要在**同一台机器**上先用 activation URL 访问一次（cookie 与 authority 绑定）。
  安全提醒：这会让内网任何人拿到一个能执行本机命令的 agent，除非该内网与目标机同等可信，否则不要开。
- 需要固定下来时，把这两个参数写进 `bin\start-web.cmd`（安装脚本按 `-BindHost` / `-TrustedHost`
  生成，也可以手工改）。

## 4. 日志与诊断

| 路径 | 内容 |
| --- | --- |
| `<InstallRoot>\web-logs\web-console.log` | 服务控制台（activation URL、启动错误） |
| `<InstallRoot>\web-logs\boot-check.out.log` `.err.log` | 安装时那次冒烟启动的输出 |
| `<InstallRoot>\web-logs\config-dump.log` | profile 组合失败时的完整输出 |
| `%USERPROFILE%\.dsh\logs\startup-*.log` | 启动审计失败报告（插件加载错误等，可能含配置/凭据值，外发前先审） |

服务起不来时的排查顺序：

1. `bin\start-web.cmd` 在前台跑一次，看报错；
2. 检查 Node 是否在 PATH 且 ≥ 22.19（`node -v`）；
3. 检查端口是否被占（`netstat -ano | findstr :3080`）；
4. 看 `%USERPROFILE%\.dsh\logs\startup-*.log` 里是否有插件加载失败。

## 5. 浏览器

用本机自带的 Edge/Chrome 即可，不需要 WebView2、也不需要桌面端应用。UI 首次加载约 34 KB 的
壳页面（实测），其余资源由本地服务提供，全程不出网。
