# 把 dsh 指向内网模型端点（离线可做）

> 本包**不含任何模型**。不配置端点，Web UI 能打开、会话能建，但 agent 无法回答。
> 全程不需要外网：下面两种方式都只改本机配置文件。

## 0. 先确认端点

| 项 | 例子 | 说明 |
| --- | --- | --- |
| BaseUrl | `http://10.0.0.20:8000/v1` | OpenAI 兼容端点通常**带版本段** `/v1` |
| ModelId | `qwen3-32b` | 必须与端点 `GET <BaseUrl>/models` 返回的 id 完全一致 |
| Key | 需要时用环境变量名，如 `LLM_KEY` | 不要把 key 写进配置文件 |

探活（可选，失败不代表端点不可用——并非所有服务都暴露 `/models`）：

```powershell
curl.exe http://10.0.0.20:8000/v1/models
```

## 1. 方式 A：Web UI 设置页（推荐先试这个）

1. 用 activation URL 打开 Web UI（见 `WEB-SURFACE.md`）。
2. 进 Settings → 模型/Provider，新增一条路由：
   - 协议 `openai-completions`
   - BaseURL 填上表的 BaseUrl
   - 模型 id 填 ModelId
   - 凭据选择“环境变量”，填变量名（如 `LLM_KEY`）
3. 保存后在下拉里选该路由。

设置页写回的就是下面那个 patch 文件；两者等价。

## 2. 方式 B：直接写 profile patch（可脚本化）

文件：`%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml`
（`$env:DSH_HOME` 被设置时，换成 `%DSH_HOME%\profiles\web\cordis.patch.yml`。）

**这是 dsh 的组合层**：顶层是一个 YAML 数组，`- id: <行 id>` 表示“改这一行”，没有 id 的条目表示“插入新行”。
`dsh-base` 已经挂载了 `llm-pi-ai` 这一行（默认没有 providers），所以**只覆盖它的 config，不要新插一个同名插件**。

把整份文件写成下面这样（`dsh-base` 自带的 `llm-pi-ai` 行 id 就是 `llm-pi-ai`）：

```yaml
- id: llm-pi-ai
  config:
    providers:
      lan:
        displayName: LAN gateway
        apiKeyEnv: LLM_KEY
        api: openai-completions
        baseURL: http://10.0.0.20:8000/v1
        models:
          - id: qwen3-32b
            name: qwen3-32b
            contextWindow: 32768
```

上面这份配置**已在构建侧实测**：`dsh --profile web --dump-config` 会把 providers 原样组合进树里。

字段含义（摘自 `@deepseek-ai/dsh-llm-pi-ai` 自带 README）：

| 字段 | 说明 |
| --- | --- |
| `api` | 线上协议；自定义路由必须写。内网 OpenAI 兼容服务用 `openai-completions` |
| `baseURL` | 该路由所有模型的端点 |
| `apiKeyEnv` | 凭据引用，**按请求解析**；解析不到会以 `MISSING_CREDENTIAL` 失败。端点不需要 key 就**删掉这一行** |
| `models` | 会**整体替换**该路由的内置目录；自建路由必须给非空列表 |
| `contextWindow` | 容量兜底；不写则用路由默认 262,144。内网小模型建议显式写小一点 |
| `compat` | 端点不被识别时的线上兼容开关（如 `thinkingFormat`）；先用默认，出问题再调 |
| `retryPolicy` | 默认 normal / 5 次重试 |

- 不要把 `apiKey` 明文写进 patch：`apiKeyEnv` 是唯一推荐的凭据入口。
- 改完 patch 后**不需要重启**：pi-ai 路由按请求解析配置，保存即生效（README 明确说明）。
- 语法自检（不启动服务、不联网）：

```powershell
dsh --profile web --dump-config | Select-String -Context 0,12 "llm-pi-ai"
```

## 3. Key 怎么给

用户级环境变量（新开的 shell / 重新登录后生效）：

```powershell
[Environment]::SetEnvironmentVariable('LLM_KEY', '<你的key>', 'User')
```

或只对本次启动生效（改 `%InstallRoot%\bin\start-web.cmd`，在调 `dsh` 前加一行）：

```bat
set "LLM_KEY=<你的key>"
```

注意：如果 Web UI 由**计划任务**启动，环境变量必须是**用户级**的——计划任务不会读你当前 shell 的临时变量。

## 4. 出错时看什么

| 症状 | 含义 | 处理 |
| --- | --- | --- |
| `MISSING_CREDENTIAL` | `apiKeyEnv` 指向的变量没解析到 | 检查用户级环境变量名与拼写 |
| `INVALID_CREDENTIAL` | key 被端点拒绝 | 换 key |
| `UNKNOWN_MODEL` | 请求的模型不在该路由的 `models` 里 | 补齐 `models` 或改选模型 |
| 请求超时 | 端点不可达/需代理 | `curl.exe <BaseUrl>/models` 自查；必要时配 `HTTP(S)_PROXY` |
| 配置不生效 | patch 没被读到 | 用 `--dump-config` 确认组合结果；确认改的是 **web** profile 的 patch |

## 5. 边界

- 只支持内网可达的端点；公网 provider（含 DeepSeek 官方）在气隙机上不可用。
- 模型发现（Models 页）对**自定义路由**会真的发一次 `GET {baseURL}/models`；端点没这个路由就手工填 `models`。
- 端点协议不是 OpenAI 兼容（比如只提供 Anthropic Messages）时，改用 `@deepseek-ai/dsh-llm-deepseek-api-key` 的
  `baseURL`（Messages 兼容网关），或给 pi-ai 路由加 `compat` 开关。**未验证**。
