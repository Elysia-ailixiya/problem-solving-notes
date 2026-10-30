# ChatGPT Windows App 反复重连：`os error 10061`（Clash Verge 代理端口不一致）排查与修复

> 记录日期：2026-10-30  
> 环境：Windows + ChatGPT Windows App（普通对话与 Codex）+ Clash Verge（System / 系统代理模式）  
> 结果：按本次排查建议调整代理相关配置并重新启动后，用户确认 **ChatGPT Windows App 已恢复正常使用**。  
> 说明：保留本次实际使用的本地 IP、端口和 PowerShell 路径，不做脱敏。

## 1. 故障现象

ChatGPT Windows App 在生成回答期间断开连接，反复显示：

```text
stream disconnected before completion: 由于目标计算机积极拒绝，无法连接。(os error 10061)
Reconnecting... waiting for network
```

表现为：

- 普通 ChatGPT 对话和 Codex 功能**均会出现**；
- 应用不断重试，回答无法正常完成；
- 同一台电脑中通过浏览器使用 ChatGPT **正常**；
- 代理软件为 **Clash Verge**，使用 **System / 系统代理**模式。

Windows Socket 错误 `10061`（`WSAECONNREFUSED`）表示 TCP 连接被目标端拒绝；它**不代表一定是 OpenAI 服务器拒绝连接**。如果应用连接的是没有服务监听的本机代理端口，也会出现这类错误。

## 2. 已观察到的系统配置

在 PowerShell 中执行：

### 2.1 Windows 系统代理（WinINET）

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
Select-Object ProxyEnable, ProxyServer, AutoConfigURL
```

实际结果：

```text
ProxyEnable ProxyServer    AutoConfigURL
----------- -----------    -------------
          1 127.0.0.1:7897
```

说明 Windows 当前用户的系统代理**已开启**，指定地址为：

```text
127.0.0.1:7897
```

### 2.2 代理环境变量

```powershell
Get-ChildItem Env:*PROXY*
```

实际结果：

```text
Name                           Value
----                           -----
HTTPS_PROXY                    http://127.0.0.1:7890
```

与系统代理的 `7897` 不同，`HTTPS_PROXY` 仍指向 `7890`。

### 2.3 WinHTTP 代理

```powershell
netsh winhttp show proxy
```

实际结果：

```text
当前的 WinHTTP 代理服务器设置:

    直接访问(没有代理服务器)。
```

**这条信息本身并不构成故障证据。** Windows 系统代理（WinINET）、WinHTTP 和进程环境变量并不总是使用同一套配置；不同应用组件可能读取不同来源。此案例无需仅因为 WinHTTP 显示“直接访问”就重置或修改它。

## 3. 关键疑点与原因分析

当时的配置存在明显不一致：

| 配置来源 | 地址 | 当时状态 |
| --- | --- | --- |
| Windows 系统代理 | `127.0.0.1:7897` | 已确认启用 |
| `HTTPS_PROXY` 环境变量 | `http://127.0.0.1:7890` | 已确认存在 |
| WinHTTP | 直接访问 | 已确认，不能单独判定异常 |
| 浏览器访问 ChatGPT | 正常 | 用户已确认 |
| ChatGPT Windows App / Codex | 重连、`10061` | 用户已确认 |

**最可能的原因**：Clash Verge 当前通过 `7897` 提供可用代理，而 ChatGPT App 的某些网络组件读取了仍指向 `7890` 的 `HTTPS_PROXY`。如果 `7890` 没有监听服务，连接该端口就可能报 `10061`。

这里应区分两个事实层级：

- **已验证**：系统代理 `7897` 与环境变量 `7890` 不一致；浏览器正常而 App 失败；按照排查建议处理后 App 恢复。
- **合理推断、尚未单独证实**：出错进程确实连接了 `7890`，且 `7890` 当时没有服务监听。本次对话未收到两端口 `Test-NetConnection` 的实际输出或进程级连接日志。

因此将“端口冲突 / 代理变量过期”记为**高度可信的原因判断**，不写成已经通过抓包完全证实的根因。

## 4. 排查与修复步骤

### 4.1 确认 Clash Verge 当前代理监听端口

在 Clash Verge 设置中查看 **Mixed Port / 混合端口** 或 HTTP 代理端口，以软件显示为准。Windows 当前系统代理为 `127.0.0.1:7897`，但仍应验证端口是否处于监听状态。

```powershell
Test-NetConnection 127.0.0.1 -Port 7897
Test-NetConnection 127.0.0.1 -Port 7890
```

观察各自的 `TcpTestSucceeded`：

- `7897 = True`：可建立到该本地端口的 TCP 连接；
- `7890 = False`：无法建立到该本地端口的 TCP 连接，强烈支持“旧端口失效”的判断；
- 两者均为 `True`：需进一步判断应用具体使用哪个代理，以及代理后面的链路是否有效。

**注意：以上是推荐的验证命令，不代表本案例已获得对应测试结果。**

还可直接测试 HTTP 代理访问（确保 `7897` 是 HTTP 或 Mixed Port，而非仅 SOCKS 端口）：

```powershell
curl.exe -I --max-time 15 --proxy http://127.0.0.1:7897 https://chatgpt.com/
```

能收到 HTTP 响应通常说明到站点的基础代理链路可用，但并不能单凭这一点确认 WebSocket 长连接必然正常。

### 4.2 确认 `HTTPS_PROXY` 的来源

```powershell
[Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process')
[Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
[Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine')
```

如果用户级（`User`）变量指向旧端口 `7890`，而 Clash Verge 实际监听的 HTTP / Mixed Port 为 `7897`，可以将**用户级**变量调整为：

```powershell
[Environment]::SetEnvironmentVariable(
    'HTTPS_PROXY',
    'http://127.0.0.1:7897',
    'User'
)
```

如果 `HTTP_PROXY` 已存在并且同样指向过期端口，也应按实际用途与当前端口同步更新；若该变量原本不存在，则**不必为了修复 HTTPS 问题而强制新增**。需要时可执行：

```powershell
[Environment]::SetEnvironmentVariable(
    'HTTP_PROXY',
    'http://127.0.0.1:7897',
    'User'
)
```

验证用户级配置：

```powershell
[Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
[Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
```

预期配置（按实际设置的变量）：

```text
http://127.0.0.1:7897
```

如果旧值只存在于 `Machine` 或仅当前 `Process` 环境，先找出设置它的来源；**仅修改 User 变量未必会清理其他来源的旧值**。

### 4.3 完整退出并重启 ChatGPT App

写入用户级环境变量后，原有 App 进程不会自动继承新的值：

1. 保持 Clash Verge 运行，确认 System / 系统代理仍开启；
2. 退出 ChatGPT Windows App（包括托盘进程）；
3. 在任务管理器中检查残留的 ChatGPT / Codex 相关后台进程；
4. 必要时注销并重新登录 Windows，以刷新应用启动时继承的环境；
5. 再次打开 App，分别测试普通对话与 Codex。

### 4.4 本次结果

用户反馈：

> 按照上述处理，现在已经可以使用了。

所以**应用恢复正常**是本次已确认的最终结果。对话没有记录每条命令的最终执行输出，因此无法进一步断言是“仅修改 HTTPS_PROXY”还是“同时同步 HTTP_PROXY”、以及是否执行了注销重登；本文保留可复现的推荐修复步骤，而不虚构操作细节。

## 5. 下次再次出现 `10061` 时的快速检查

```powershell
# 1. 当前 Windows 系统代理
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
Select-Object ProxyEnable, ProxyServer, AutoConfigURL

# 2. 进程可见的代理环境变量
Get-ChildItem Env:*PROXY*

# 3. 用户级代理变量
[Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')

# 4. 测试 Clash Verge 新旧端口
Test-NetConnection 127.0.0.1 -Port 7897
Test-NetConnection 127.0.0.1 -Port 7890

# 5. 经由当前代理访问 ChatGPT
curl.exe -I --max-time 15 --proxy http://127.0.0.1:7897 https://chatgpt.com/
```

若两个端口都能连接、配置也已统一，但仍反复 `Reconnecting`，继续检查 Clash Verge 连接日志、代理节点、WebSocket 升级和长连接稳定性，而不要直接假设仍是端口不一致。

## 6. 回滚与注意事项

如需恢复先前的**用户级** `HTTPS_PROXY` 值：

```powershell
[Environment]::SetEnvironmentVariable(
    'HTTPS_PROXY',
    'http://127.0.0.1:7890',
    'User'
)
```

如果该环境变量不再需要，且已确认可以删除：

```powershell
[Environment]::SetEnvironmentVariable(
    'HTTPS_PROXY',
    $null,
    'User'
)
```

`HTTP_PROXY` 若是本次新增或修改的，也可按相同原则单独恢复。修改后应重新启动相关应用。

- `127.0.0.1` 是本机回环地址，不是家庭、学校或公司的公网 IP；
- 端口 `7890`、`7897` 是本次电脑上的配置，不保证适用于其他机器；
- Clash Verge 更新、重装、切换代理软件或更改 Mixed Port 后，要复核环境变量；
- 未确认监听端口及变量来源之前，不要盲目修改 WinHTTP、注册表或全局环境；
- 如果浏览器可用而 App 不可用，优先对照两者使用的代理配置。

## 7. 与仓库中其他记录的关系

仓库已有两篇较早的故障笔记，其中 `7890` **在当时是有效端口**；本文记录的是 **2026-10-30 Clash Verge / Windows 系统代理改为 `7897`，但 `HTTPS_PROXY` 仍保留旧 `7890`** 的新情形。不要把早期文档中的 `7890` 机械套用到当前环境。

- [ChatGPT 远程控制 WebSocket `10060` 超时](../Remote-Control-WebSocket-10060/README.md)
- [Chrome 标签页控制 `nodeRepl.fetch request failed`](../Chrome-Control-nodeRepl-fetch-failed/README.md)

## 8. 结论

> **故障表现：** ChatGPT Windows App 普通对话与 Codex 均出现 `stream disconnected before completion`、`os error 10061`、持续 `Reconnecting`。  
> **关键发现：** Windows 系统代理为 `127.0.0.1:7897`，但 `HTTPS_PROXY` 为 `http://127.0.0.1:7890`。  
> **有效处理方向：** 核对 Clash Verge 实际监听端口，将应用使用的代理环境变量与之匹配，并完整重启客户端。  
> **结果：** 用户确认恢复正常；具体失败连接的端口尚未通过进程日志单独验证。
