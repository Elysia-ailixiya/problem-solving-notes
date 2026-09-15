# ChatGPT 无法读取/控制 Chrome 标签页：`nodeRepl.fetch request failed` 排查与修复

> 记录日期：2026-09-15  
> 环境：Windows + ChatGPT Windows 客户端 + Chrome 扩展 + Clash for Windows  
> 现象：ChatGPT 能识别 Chrome 扩展，但无法读取或控制 Chrome 标签页，最终报 `nodeRepl.fetch request failed`。

## 1. 问题现象

当时已确认：

- Chrome 扩展权限已开启，并允许访问所有网站；
- Chrome 页面和招聘网站可以正常打开；
- ChatGPT 能识别 Chrome 扩展；
- 但读取标签页时持续失败；
- 重启 Chrome、刷新页面、重新启用扩展、重置浏览器控制会话后仍无效；
- 典型报错为 `nodeRepl.fetch request failed`。

这说明问题并不在网页本身，也不像普通的 Chrome 网站权限问题，而更像是 ChatGPT/Codex 的浏览器控制后端没有正常联网。

## 2. 排查思路

### 2.1 先测试 OpenAI 浏览器控制相关接口

在 PowerShell 中执行：

```powershell
curl.exe -I --max-time 10 https://chatgpt.com/backend-api/aura/identity
```

结果：

```text
curl: (28) Connection timed out after 10014 milliseconds
```

即：**直接访问超时**。

随后明确指定 Clash 本地代理（本机端口为 7890）：

```powershell
curl.exe -I --max-time 10 --proxy http://127.0.0.1:7890 https://chatgpt.com/backend-api/aura/identity
```

结果立即返回：

```text
HTTP/1.1 200 Connection established
HTTP/1.1 403 Forbidden
```

这里的 `403` 并不代表代理失败。由于 curl 没有携带 ChatGPT 登录凭据，服务器拒绝请求是正常的。关键在于：**通过 127.0.0.1:7890 后可以立即收到 HTTP 响应**。

由此得到第一个关键结论：

```text
直接连接 chatgpt.com     -> 超时
显式指定 Clash 7890     -> 立即有 HTTP 响应
```

因此问题高度指向：**ChatGPT 浏览器控制所使用的 Node/CUA 运行时没有正确继承本机 Clash 代理。**

## 3. 定位 ChatGPT 实际使用的 CUA Node runtime

先查找实际运行时中的 `browser-service.mjs`：

```powershell
$runtimeRoot = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"

Get-ChildItem $runtimeRoot -Recurse -Filter "browser-service.mjs" -File -ErrorAction SilentlyContinue |
Where-Object {
    $_.FullName -like "*\node_modules\@oai\browser-desktop\scripts\browser-service.mjs"
} |
Select-Object FullName, Length, LastWriteTime
```

实际运行文件位于类似：

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<runtime-hash>\bin\node_modules\@oai\browser-desktop\scripts\browser-service.mjs
```

之后继续找到 CUA 的启动入口：

```powershell
Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" `
-Recurse -Filter "cua-repl.mjs" -File -ErrorAction SilentlyContinue |
Select-Object FullName,Length,LastWriteTime
```

路径形式为：

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<runtime-hash>\bin\node_modules\@oai\cua-repl\bin\cua-repl.mjs
```

原始文件内容非常简单，本质上是导入 `@oai/cua-repl` 后执行：

```javascript
await cua_repl.launch();
```

## 4. 用 ChatGPT 自带的 Node runtime 复现问题

为了避免只用系统 curl 推断，直接使用 ChatGPT/Codex 实际运行的 `node.exe` 测试。

先找到 runtime 中的 Node：

```powershell
$node = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\<runtime-hash>\bin\node.exe"
```

不设置代理时：

```powershell
& $node -e "fetch('https://chatgpt.com/backend-api/aura/identity',{signal:AbortSignal.timeout(10000)}).then(r=>console.log('HTTP',r.status)).catch(e=>console.error(e.name,e.message))"
```

结果：

```text
TimeoutError The operation was aborted due to timeout
```

然后在当前 PowerShell 会话临时设置：

```powershell
$env:NODE_USE_ENV_PROXY = "1"
$env:HTTP_PROXY  = "http://127.0.0.1:7890"
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
$env:NO_PROXY    = "localhost,127.0.0.1,::1"
```

再次执行同一请求：

```text
HTTP 403
```

至此，根因基本可以确认：

```text
CUA Node 直连 aura/identity -> 超时
同一个 CUA Node 显式使用 Clash 代理 -> 立即返回 HTTP
```

即 **CUA Node 运行时没有正确继承代理**，导致身份/请求头策略相关请求一直等待，进一步拖死 Chrome 标签页 RPC，最终表现为 `nodeRepl.fetch request failed`。

## 5. 修复方式

### 5.1 为什么不直接全局设置 Windows 代理环境变量

可以给整个 Windows 用户环境设置 `HTTP_PROXY` / `HTTPS_PROXY`，但这会同时影响 npm、Node、PI、DSH 等其他程序。

因此本次采用更局部的办法：**只修改 ChatGPT/Codex 的 CUA 启动入口**，让浏览器控制运行时使用 Clash 代理。

### 5.2 先验证 `setGlobalProxyFromEnv()`

Node 运行时支持：

```powershell
& $node -e "process.env.HTTP_PROXY='http://127.0.0.1:7890';process.env.HTTPS_PROXY='http://127.0.0.1:7890';process.env.NO_PROXY='localhost,127.0.0.1,::1';const http=require('node:http');console.log('setGlobalProxyFromEnv:',typeof http.setGlobalProxyFromEnv);http.setGlobalProxyFromEnv();fetch('https://chatgpt.com/backend-api/aura/identity',{signal:AbortSignal.timeout(10000)}).then(r=>console.log('HTTP',r.status)).catch(e=>console.error(e.name,e.message))"
```

结果为：

```text
setGlobalProxyFromEnv: function
HTTP 403
```

说明可以在进程内显式启用代理。

### 5.3 修改 `cua-repl.mjs`

先备份原文件，然后把启动逻辑调整为：

```javascript
#!/usr/bin/env node

import * as http from "node:http";

process.env.HTTP_PROXY = "http://127.0.0.1:7890";
process.env.HTTPS_PROXY = "http://127.0.0.1:7890";
process.env.http_proxy = "http://127.0.0.1:7890";
process.env.https_proxy = "http://127.0.0.1:7890";
process.env.NO_PROXY = "localhost,127.0.0.1,::1";
process.env.no_proxy = "localhost,127.0.0.1,::1";

http.setGlobalProxyFromEnv();

const cua_repl = await import("@oai/cua-repl");

try {
  await cua_repl.launch();
} catch (error) {
  const error_message = error instanceof Error ? error.message : String(error);
  console.error(`cua_repl could not start: ${error_message}`);
  process.exitCode = 1;
}
```

这里采用动态：

```javascript
await import("@oai/cua-repl")
```

而不是文件开头直接静态 import，是为了保证顺序：

```text
设置代理环境变量
-> 启用 Node 全局代理
-> 再加载 @oai/cua-repl
-> 启动浏览器控制
```

## 6. 排查过程中遇到的 UTF-8 BOM 问题

第一次使用 Windows PowerShell 5.x：

```powershell
Set-Content $repl -Encoding UTF8
```

写入文件后，执行：

```powershell
& $node --check $repl
```

出现：

```text
#!/usr/bin/env node
^
SyntaxError: Invalid or unexpected token
```

原因是 Windows PowerShell 5.x 的 `-Encoding UTF8` 会写入 UTF-8 BOM，导致 Node 看到的文件实际上是：

```text
<BOM>#!/usr/bin/env node
```

Hashbang 不再处于第一个字节，因此报错。

修复方式：使用 UTF-8 无 BOM 重新保存：

```powershell
$text = [System.IO.File]::ReadAllText($repl)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($repl, $text, $utf8NoBom)
```

重新检查：

```powershell
& $node --check $repl
```

无输出，说明语法通过。

还可以确认前 4 个字节：

```powershell
Get-Content $repl -Encoding Byte -TotalCount 4
```

正常：

```text
35
33
47
117
```

对应 `#!/u`。

如果看到：

```text
239
187
191
```

则说明文件仍带 UTF-8 BOM。

## 7. 最终验证

完全退出 ChatGPT Windows 客户端（包括托盘进程），保持 Clash 运行后重新启动 ChatGPT。

Chrome 打开：

```text
https://example.com
```

在 ChatGPT 中执行：

```text
读取当前 Chrome 中打开的标签页，并告诉我 example.com 页面的标题。
```

最终成功返回：

```text
Example Domain
```

说明：

- Chrome 扩展发现正常；
- 标签页枚举恢复；
- CUA / Node 代理链路恢复；
- `nodeRepl.fetch request failed` 问题得到解决。

## 8. 最终结论

本次问题并不是：

- Chrome 扩展没有权限；
- Chrome 本身损坏；
- 招聘网站限制；
- 普通网页无法访问。

实际根因是：

> ChatGPT/Codex 的 CUA Node 浏览器控制运行时没有正确继承 Clash 代理，导致对 `chatgpt.com/backend-api/aura/identity` 的请求直连超时，进而阻塞 Chrome 标签页 RPC，并最终表现为 `nodeRepl.fetch request failed`。

最终解决方法是：

> 在 CUA 的 `cua-repl.mjs` 启动入口中显式设置 `HTTP_PROXY` / `HTTPS_PROXY`，调用 `http.setGlobalProxyFromEnv()`，然后再加载并启动 `@oai/cua-repl`。

## 9. 后续注意事项

- ChatGPT/Codex 更新后可能生成新的：

```text
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<新的 runtime-hash>
```

- 新 runtime 不会继承旧 runtime 的修改；
- 如果更新后再次出现 `nodeRepl.fetch request failed`，优先检查新的 CUA runtime，而不是重新折腾 Chrome 权限；
- 应保留 `.bak-*` 原文件备份；
- 本目录提供了自动检查/修复脚本 `Fix-ChatGPTChromeProxy.ps1`，可在更新后重新应用。

## 10. 相关文件

- [`Fix-ChatGPTChromeProxy.ps1`](./Fix-ChatGPTChromeProxy.ps1)：自动检查、安装与恢复代理补丁。
- [`USAGE.md`](./USAGE.md)：脚本详细使用说明。

## 11. 参考

本次排查过程中参考了 OpenAI Codex GitHub 中与 Windows Chrome Browser Control、代理继承和 `aura/identity` 阻塞相关的公开 issue，包括：

- https://github.com/openai/codex/issues/44364
- https://github.com/openai/codex/issues/45014

> 注：上述方案属于针对当前版本运行时行为的本地 workaround，并非 OpenAI 官方长期修复。