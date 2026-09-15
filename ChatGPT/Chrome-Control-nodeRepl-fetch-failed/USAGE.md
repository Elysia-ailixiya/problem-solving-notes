# `Fix-ChatGPTChromeProxy.ps1` 使用说明

## 适用场景

当 Windows 上出现以下情况时，可以使用本脚本：

- ChatGPT 能识别 Chrome 扩展；
- Chrome 扩展允许访问所有网站；
- Chrome 和目标网页本身可以正常打开；
- 但 ChatGPT 无法读取或控制 Chrome 标签页；
- 浏览器控制报 `nodeRepl.fetch request failed`；
- CUA Node 直接访问 `https://chatgpt.com/backend-api/aura/identity` 会超时；
- 通过 Clash 本地代理（如 `127.0.0.1:7890`）可以快速收到 HTTP 响应。

本脚本会给 ChatGPT/Codex 的 CUA Node 运行时加入局部代理配置，而不是永久修改整个 Windows 的用户级代理环境变量。

> 这属于本地 workaround，不是 OpenAI 官方长期修复。ChatGPT/Codex 更新后可能生成新的 runtime，需要重新运行脚本。

## 使用前准备

1. 启动 Clash for Windows；
2. 确认本地代理端口，例如 `7890`；
3. 建议开启系统代理；TUN 是否开启可按当前网络环境决定；
4. 在安装或恢复补丁前，建议完全退出 ChatGPT，包括托盘后台进程；
5. 不需要管理员权限。

## 运行方式

在 PowerShell 中进入脚本所在目录。例如：

```powershell
cd "$env:USERPROFILE\Downloads"
```

如果 PowerShell 阻止本地脚本运行，可以只对当前窗口临时放行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

关闭 PowerShell 后该设置即失效。

## 1. 检查环境

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Check
```

脚本会自动：

- 查找最新的 CUA runtime；
- 查找同一 runtime 的 `cua-repl.mjs` 和 `node.exe`；
- 检查补丁状态；
- 检查代理端口是否可连接；
- 测试 CUA Node 直连 `aura/identity`；
- 测试 CUA Node 显式走代理；
- 检查当前 `cua-repl.mjs` 的 JavaScript 语法。

如果显式代理测试返回：

```text
HTTP 403
```

或 `HTTP 401`、其他 HTTP 状态码，也代表已经成功连接到 `chatgpt.com`。测试请求没有 ChatGPT 登录凭据，因此 401/403 不表示代理失败。

## 2. 安装修复

默认代理地址：

```text
http://127.0.0.1:7890
```

直接运行：

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Install
```

脚本会自动：

1. 找到最新 CUA runtime；
2. 备份原始 `cua-repl.mjs`；
3. 写入局部代理设置；
4. 使用 UTF-8 无 BOM 写入，避免 Hashbang 语法错误；
5. 执行 `node --check`；
6. 如语法检查失败，自动恢复备份；
7. 测试代理链路。

备份文件形式类似：

```text
cua-repl.mjs.bak-20260915-174500
```

## 3. Clash 端口不是 7890

例如端口为 `7897`：

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Check -Proxy "http://127.0.0.1:7897"

.\Fix-ChatGPTChromeProxy.ps1 -Action Install -Proxy "http://127.0.0.1:7897"
```

## 4. 重启并验证

安装完成后：

1. 完全退出 ChatGPT，包括托盘后台进程；
2. 保持 Clash 运行；
3. 重新启动 ChatGPT；
4. 在 Chrome 打开 `https://example.com`；
5. 在 ChatGPT 的浏览器控制任务中输入：

```text
读取当前 Chrome 中打开的标签页，并告诉我 example.com 页面的标题。
```

正常应返回：

```text
Example Domain
```

如果可以正常读取，再测试真实页面正文读取和点击操作。

## 5. 恢复原文件

如需撤销：

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Restore
```

脚本会在当前最新 runtime 中寻找最近一次：

```text
cua-repl.mjs.bak-*
```

并恢复，然后执行语法检查。

恢复后请完全退出并重新启动 ChatGPT。

## 6. ChatGPT 更新后再次失效

ChatGPT/Codex 更新后可能生成新的：

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<新的哈希>\
```

新 runtime 不会继承旧 runtime 的修改。

如果再次遇到：

```text
nodeRepl.fetch request failed
```

优先运行：

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Check
```

如果显示新的 runtime 未安装补丁，再运行：

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Install
```

脚本会自动选择最新 runtime。

## 7. 常见结果判断

### 直连超时，显式代理返回 HTTP 403

典型结果：

```text
Node 直连测试
TimeoutError: The operation was aborted due to timeout

Node 显式代理测试
HTTP 403
```

这正是本脚本针对的典型场景，说明：

```text
CUA Node 直连失败
-> Clash 代理可访问 chatgpt.com
-> CUA 运行时需要显式使用代理
```

### 显式代理也超时

检查：

- Clash 是否已经启动；
- 代理端口是否正确；
- 当前节点是否可用；
- `-Proxy` 参数是否正确。

可以手工测试：

```powershell
curl.exe -I --max-time 10 --proxy http://127.0.0.1:7890 https://chatgpt.com/backend-api/aura/identity
```

只要快速收到 HTTP 响应（包括 401/403），代理链路就基本正常。

### 找不到 `cua-repl.mjs`

先启动 ChatGPT，并至少尝试一次 Chrome/Computer Use 功能，让客户端生成 CUA runtime。

然后再次执行：

```powershell
.\Fix-ChatGPTChromeProxy.ps1 -Action Check
```

## 8. 脚本实际修改的位置

目标文件形式为：

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<runtime-hash>\
bin\node_modules\@oai\cua-repl\bin\cua-repl.mjs
```

核心逻辑是：

```javascript
process.env.HTTP_PROXY = "http://127.0.0.1:7890";
process.env.HTTPS_PROXY = "http://127.0.0.1:7890";
process.env.NO_PROXY = "localhost,127.0.0.1,::1";

http.setGlobalProxyFromEnv();
```

随后才动态加载：

```javascript
const cua_repl = await import("@oai/cua-repl");
```

因此代理设置只作用于 ChatGPT/Codex 的 CUA 浏览器控制运行时，不会永久修改 Windows 用户级 `HTTP_PROXY` / `HTTPS_PROXY`。

## 9. 注意事项

- 保留脚本自动创建的 `.bak-*` 备份；
- ChatGPT/Codex 更新可能覆盖修复；
- Clash 端口变化后应重新运行 `Install` 并指定新的 `-Proxy`；
- 如果未来官方修复代理继承问题，可使用 `Restore` 恢复原文件；
- 不建议优先修改 `.codex\plugins\cache` 中的 `browser-service.mjs`，本脚本针对的是实际执行的 CUA runtime 入口。
