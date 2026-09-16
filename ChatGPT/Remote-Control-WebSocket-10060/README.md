# ChatGPT Windows 无法启用远程控制：WebSocket `10060` 超时排查与修复

> 记录日期：2026-09-16
>
> 环境：Windows 11 + ChatGPT Windows 客户端 + Clash for Windows 0.20.24
>
> 现象：在“设置 → 连接 → 控制此电脑”中点击“允许”后，界面提示“无法启用远程控制，请重试”。

## 1. 问题现象

在 ChatGPT Windows 客户端中进入：

```text
设置 → 连接 → 控制此电脑
```

点击“允许”后无法进入二维码配对阶段，界面直接显示：

```text
无法启用远程控制。请重试
```

最初已经确认：

- ChatGPT 可以正常登录和使用；
- Clash 系统代理已开启，地址为 `127.0.0.1:7890`；
- Clash 已切换到全局模式；
- Clash 界面中的 TUN Mode 开关已打开；
- 重试“允许”仍然失败。

由于失败发生在二维码出现之前，因此问题不在手机扫码、移动端版本或设备配对步骤，而是在 Windows 主机建立远程控制通道的阶段。

## 2. 官方要求与排障基线

OpenAI 的远程连接文档要求：

- 主机运行最新版 ChatGPT 桌面应用；
- 主机保持在线、唤醒；
- 手机和主机使用同一 ChatGPT 账户及工作空间；
- 工作空间管理员没有禁用远程控制；
- 启用或添加设备时报错时，先完整重启桌面应用再试。

官方文档：

- <https://learn.chatgpt.com/zh-Hans/docs/remote-connections>

本次故障发生在主机建立远程控制 WebSocket 时，进一步排查需要查看本地网络和 Codex 日志。

## 3. 从日志定位失败点

ChatGPT/Codex 的日志数据库位于：

```text
%USERPROFILE%\.codex\logs_2.sqlite
```

日志中反复出现：

```text
failed to connect to app-server remote control websocket
wss://chatgpt.com/backend-api/wham/remote/control/server
IO error: connection attempt failed (os error 10060)
```

同时日志包含：

```text
has_enrollment=true
```

这两个信息非常关键：

- `has_enrollment=true` 表明账户已经完成远程控制服务登记，功能资格和登录状态不是主要阻塞点；
- Windows `10060` 表示连接超时，故障集中在本机到远程控制 WebSocket 的网络链路。

## 4. 验证直连与代理链路

### 4.1 Windows 系统代理

检查后发现 Windows 系统代理已经开启：

```text
127.0.0.1:7890
```

端口由 Clash 的 `clash-win64.exe` 监听。

### 4.2 直连失败

直接访问 ChatGPT：

```powershell
curl.exe -I --noproxy "*" --connect-timeout 8 https://chatgpt.com/
```

结果为连接超时。

即使手动指定可信 DNS 返回的 Cloudflare IP，直连仍然超时，说明问题不只是 DNS 解析错误，当前网络也阻断了到 ChatGPT 的直接连接。

### 4.3 显式指定 Clash 后可达

```powershell
curl.exe -I `
  --proxy http://127.0.0.1:7890 `
  --connect-timeout 8 `
  https://chatgpt.com/backend-api/wham/remote/control/server
```

可以立即收到服务器的 HTTP 响应。未携带 ChatGPT 登录凭据时返回 `400`、`401` 或 `403` 都不代表代理失败；关键是请求不再超时。

由此确认：

```text
直接访问远程控制 WebSocket  -> 超时
显式通过 Clash 7890          -> 服务器立即响应
```

## 5. 为什么开启 TUN 后仍然无效

虽然 Clash 界面中的 TUN Mode 开关已打开，但 Windows 中没有出现 Clash/Wintun 虚拟网卡，也没有安装或运行 Clash Core Service。

Clash 日志给出了明确原因：

```text
[Inbound] start failed
Error creating interface: Access is denied.
type=TUN
```

因此实际状态是：

```text
TUN 界面开关开启
        ↓
创建虚拟网卡时权限不足
        ↓
TUN 启动失败
        ↓
ChatGPT 后台仍然直接连接
        ↓
WebSocket 10060 超时
```

这也是为什么“全局模式 + TUN Mode”看起来都已开启，但问题没有变化。

如果希望继续使用 TUN，需要以管理员权限正确安装 Clash Core Service/Service Mode，再确认 Windows 中实际出现并启用 TUN 虚拟网卡。只看开关状态不足以证明 TUN 已生效。

## 6. 无需管理员权限的修复方式

Codex 的网络诊断显示：

```text
respect system proxy: disabled
```

也就是说，远程控制后台不会自动继承 Windows 的 WinINET“系统代理”。但 Codex 支持标准的 `HTTPS_PROXY` 环境变量。

在临时设置以下变量后运行 Codex 官方诊断：

```powershell
$env:HTTPS_PROXY = "http://127.0.0.1:7890"

codex doctor --json
```

关键结果变为：

```text
network.provider_reachability: ok
network.websocket_reachability: ok
handshake result: HTTP 101 Switching Protocols
```

`101 Switching Protocols` 表明 WebSocket 握手成功，证明 `HTTPS_PROXY` 可以解决本次连接问题。

### 6.1 写入当前用户环境变量

执行：

```powershell
[Environment]::SetEnvironmentVariable(
    "HTTPS_PROXY",
    "http://127.0.0.1:7890",
    "User"
)
```

验证：

```powershell
[Environment]::GetEnvironmentVariable("HTTPS_PROXY", "User")
```

预期输出：

```text
http://127.0.0.1:7890
```

本次只设置 `HTTPS_PROXY`，没有额外设置全局 `HTTP_PROXY` 或 `ALL_PROXY`，以减少对其他命令行工具的影响。

## 7. 让修复生效

环境变量不会注入已经运行的 ChatGPT 进程。设置完成后必须：

1. 保持 Clash 运行，并确认 `127.0.0.1:7890` 正在监听；
2. 从系统托盘彻底退出 ChatGPT；
3. 在任务管理器中确认没有残留的 `ChatGPT.exe` 和对应 Codex 后台进程；
4. 重新启动 ChatGPT；
5. 再次进入“设置 → 连接 → 控制此电脑”；
6. 点击“允许”，检查是否进入二维码配对阶段。

如果重新启动 ChatGPT 后仍未继承变量，注销并重新登录 Windows，或重启电脑后再试。

## 8. 修复后的验证方法

### 8.1 使用 Codex Doctor

```powershell
codex doctor --json
```

重点查看：

```text
network.provider_reachability
network.websocket_reachability
```

理想结果：

```text
status: ok
Responses WebSocket handshake succeeded
HTTP 101 Switching Protocols
```

### 8.2 查看远程控制日志

如果安装了 `sqlite3`，可在 `logs_2.sqlite` 中搜索：

```sql
SELECT datetime(ts,'unixepoch','localtime'), level, feedback_log_body
FROM logs
WHERE target LIKE '%remote_control::websocket%'
ORDER BY ts DESC, ts_nanos DESC
LIMIT 20;
```

修复后不应继续出现新的：

```text
os error 10060
```

### 8.3 完成设备配对

主机成功启用远程控制后，界面会显示二维码。使用最新版 ChatGPT 手机应用扫描，并确认手机与主机使用同一账户和工作空间。

## 9. 回滚方法

如果需要删除本次新增的用户级代理变量：

```powershell
[Environment]::SetEnvironmentVariable(
    "HTTPS_PROXY",
    $null,
    "User"
)
```

删除后同样需要完整重启 ChatGPT，必要时注销 Windows。

## 10. 最终结论

本次问题不是：

- 手机无法扫码；
- Windows 桌面未解锁；
- ChatGPT 安装包损坏；
- 账户没有完成远程控制登记；
- 单纯的 DNS 解析错误。

实际根因是两个条件叠加：

1. 当前网络无法直接访问 ChatGPT 的远程控制 WebSocket；
2. Clash TUN 因权限不足没有真正启动，而 Codex 后台又不自动使用 Windows 系统代理。

有效修复路径是：

> 为当前 Windows 用户设置 `HTTPS_PROXY=http://127.0.0.1:7890`，保持 Clash 运行，然后完整重启 ChatGPT，使远程控制后台通过 Clash 建立 WebSocket。

如果希望依赖 TUN 而不是环境变量，应先正确安装 Clash Service Mode，并用虚拟网卡、路由表和 Clash 日志确认 TUN 确实已经运行。

## 11. 注意事项

- Clash 本地端口变化后，需要同步更新 `HTTPS_PROXY`；
- Clash 未启动时，设置了该变量的程序可能无法访问 HTTPS 网络；
- 企业或学校网络可能额外阻止 WebSocket、VPN 或代理流量；
- 如果使用 ChatGPT Enterprise/Edu 工作空间，还需确认管理员已启用远程控制；
- Windows 主机成功配对后，执行计算机使用任务时仍需保持会话解锁、联网和唤醒；
- 本文中的 `HTTPS_PROXY` 修复已经通过 `codex doctor` 的 HTTP 与 WebSocket 检查，但最终二维码配对仍应在完整重启 ChatGPT 后验证。
