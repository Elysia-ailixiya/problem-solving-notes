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


## 9. 后续改进：取消固定端口，跟随 Windows 系统代理

> 执行日期：2026-10-30。以下为本次已执行的修改与检查；不再只是推荐步骤。端口与本机路径按实际情况保留。

### 9.1 为什么继续调整

前面的修复将旧端口 `7890` 调整为当前可用的 `7897`，恢复了连接，但仍依赖固定端口。以后换用其他代理软件或修改监听端口，环境变量可能再次过期。

早期远程控制排查曾手动写入用户级 `HTTPS_PROXY=http://127.0.0.1:7890`。这是让当时的后台显式使用已有的 Clash 端口，并不是将 Clash 的监听端口改成 `7890`。

本次改为：清除用户级固定代理变量，让支持的 ChatGPT/Codex 原生网络组件跟随 Windows 当前系统代理。**这不是完全恢复所有默认设置**：系统代理跟随选项默认关闭，本次明确将其开启。

### 9.2 修改前实际检查结果

| 项目 | 实际状态 |
| --- | --- |
| Windows 系统代理 | `ProxyEnable=1`，`ProxyServer=127.0.0.1:7897`，无 PAC 地址 |
| 用户级 `HTTP_PROXY` | `http://127.0.0.1:7897` |
| 用户级 `HTTPS_PROXY` | `http://127.0.0.1:7897` |
| 本次检查进程中的上述两个变量 | 均为 `http://127.0.0.1:7897` |
| 机器级代理变量 | 本次检查的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 未发现非空值 |
| `respect_system_proxy` | 当前版本支持，修改前未开启 |
| 后台版本 | `codex-cli 0.166.0-alpha.5.1` |
| 本次调用的后台程序 | `C:\Users\29489\AppData\Local\OpenAI\Codex\bin\22cfb1d302613eae\codex.exe` |

对当前 CUA Node runtime 和当前 browser 插件 scripts 中的 JS/MJS 进行了定向搜索，未发现 `127.0.0.1:7890`、`127.0.0.1:7897` 或之前补丁使用的 `setGlobalProxyFromEnv` 匹配；未修改这些组件。该检查不等于对所有历史版本及文件做过完整审计。

### 9.3 先临时验证，再保存配置

先在单独的检查进程中清除固定代理环境变量，并临时开启系统代理跟随：

```powershell
Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY -ErrorAction SilentlyContinue
& 'C:/Users/29489/AppData/Local/OpenAI/Codex/bin/22cfb1d302613eae/codex.exe' -c features.respect_system_proxy=true doctor --network-only --json
```

临时检查的 HTTP 与 WebSocket 均通过，之后才保存下列修改。

**修改一：** 在 `C:\Users\29489\.codex\config.toml` 现有的 `[features]` 表中增加：

```toml
[features]
respect_system_proxy = true
```

实际保留了现有表中的其他设置；不要重复新增同名表或覆盖整个配置文件。

**修改二：** 删除两项用户级固定代理变量：

```powershell
[Environment]::SetEnvironmentVariable('HTTP_PROXY', $null, 'User')
[Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'User')
```

Windows 系统代理仍保持 `127.0.0.1:7897`，未更改 Clash Verge 的监听端口、WinHTTP 或机器级环境变量。

### 9.4 保存后的实际验证

保存后，在移除了固定代理变量的检查进程中执行诊断，**不再传入临时的功能覆盖参数**：

```powershell
Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY -ErrorAction SilentlyContinue
& 'C:/Users/29489/AppData/Local/OpenAI/Codex/bin/22cfb1d302613eae/codex.exe' doctor --network-only --json
```

实际关键结果：

```text
config.toml parse: ok
proxy env vars: none
respect system proxy: enabled

network.provider_reachability: ok
active provider endpoints are reachable over HTTP
ChatGPT inference URL: reachable (HTTP 405)

network.websocket_reachability: ok
Responses WebSocket handshake succeeded
handshake result: HTTP 101 Switching Protocols
```

这里的 HTTP `405` 是诊断探测收到的响应，不是一次真实对话生成成功的证明；WebSocket 的 `101` 表明本次握手成功。

总体诊断为 `warning`，原因是已有配置项 `computer_use.windows.always_allowed_app_ids` 不被当前版本识别；该项未在本次修改范围内。网络检查全部为 `ok`，不能把总体 warning 写成网络失败，也不能写成诊断完全无警告。

### 9.5 重启与适用范围

保存用户级环境变量和配置，不会自动更新已经运行的 ChatGPT 及其父进程的环境。因此仍需：

1. 保持当前代理正常运行并开启 Windows 系统代理。
2. 完整退出 ChatGPT，包括托盘进程，再重新打开。
3. 若启动后仍继承旧环境，注销 Windows 后重新登录。
4. 分别测试普通对话、Codex、远程控制和浏览器控制。

本次已验证：**无固定代理环境变量的独立后台检查进程，可加载已保存配置，并完成 HTTP 可达性检查和 Responses WebSocket 握手。**

本次未验证：完整重启后的所有 App 功能、实际切换 Clash/Clash Verge/其他代理软件的效果、远程控制专用通道，以及 Chrome/CUA 等独立组件的全部请求。

后续切换代理软件时，应让新软件正确接管 Windows 系统代理；为避免争抢配置，通常只让当前使用的软件接管。若运行中切换后连接仍使用旧路径，先重启 App。本设置只适用于支持它的 Codex 原生网络客户端，不能保证所有插件、Node 进程、命令行工具自动跟随系统代理。

### 9.6 本机备份与回滚

修改前已在本机备份：

```text
C:\Users\29489\AppData\Local\OpenAI\ProxySettingsBackups\20261030-201827\config.toml.bak
C:\Users\29489\AppData\Local\OpenAI\ProxySettingsBackups\20261030-201827\user-proxy-before.json
C:\Users\29489\AppData\Local\OpenAI\ProxySettingsBackups\20261030-201827\Restore-PreviousProxy.ps1
```

备份中的两个用户级变量原值均为 `http://127.0.0.1:7897`。需要撤销本次修改时，可在本机执行：

```powershell
& 'C:/Users/29489/AppData/Local/OpenAI/ProxySettingsBackups/20261030-201827/Restore-PreviousProxy.ps1'
```

该脚本恢复这两个用户级变量，并移除本次新增的 `respect_system_proxy = true` 行；然后仍需完整重启 App，必要时注销重登。上述文件是本机备份，不随仓库分发；未上传完整个人配置文件。

### 9.7 官方依据

- [OpenAI：Use the system proxy for native client requests](https://learn.chatgpt.com/docs/enterprise/managed-configuration#use-the-system-proxy-for-native-client-requests)

官方说明该选项适用于 ChatGPT desktop / Codex 使用的原生 Codex runtime，默认关闭，Windows 支持系统代理发现；其范围不涵盖所有桌面请求、插件、浏览器请求和 shell 命令。
