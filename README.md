# problem-solving-notes

个人问题排查、解决方案与技术笔记。

## 已记录问题

### ChatGPT / Chrome

- [ChatGPT 无法读取/控制 Chrome 标签页：`nodeRepl.fetch request failed` 排查与修复](./ChatGPT/Chrome-Control-nodeRepl-fetch-failed/README.md)
  - 记录 Windows + ChatGPT Windows 客户端 + Chrome 扩展 + Clash 环境下的完整排查过程
  - 包含根因定位、CUA Node 代理验证、UTF-8 BOM 问题、最终修复方式
  - 附带自动检查/修复/恢复脚本和使用说明

### ChatGPT / Windows App 网络连接

- [ChatGPT Windows App 反复重连：`os error 10061`（Clash Verge 代理端口不一致）排查与修复](./ChatGPT/Windows-App-os-error-10061/README.md)
  - 记录普通对话与 Codex 同时断线、网页正常的故障现象及诊断命令
  - 对比 Windows 系统代理 `127.0.0.1:7897` 与旧 `HTTPS_PROXY=http://127.0.0.1:7890` 的差异
  - 包含环境变量调整、客户端重启、复发排查和回滚步骤；区分已验证事实与推断

### ChatGPT / 远程控制

- [ChatGPT Windows 无法启用远程控制：WebSocket `10060` 超时排查与修复](./ChatGPT/Remote-Control-WebSocket-10060/README.md)
  - 记录“无法启用远程控制，请重试”的完整定位过程
  - 说明为什么开启 Clash 全局模式和 TUN 开关后仍然无效
  - 包含 TUN 权限失败、DNS/直连验证、`HTTPS_PROXY` 修复及回滚方法

### Windows / iPad 局域网文件共享

- [Windows 笔记本与 iPad 通过 SMB 局域网共享文件：免密码访问配置与排查](./Windows-iPad/SMB-LAN-File-Sharing/README.md)
  - 记录自定义 `Share_file` 共享、iPad“文件”App 通过 Guest 连接与下载的操作
  - 涵盖用户名/密码无效、额外出现 `Users` 共享、关闭公用文件夹共享后无法访问等现象
  - 区分实际验证结果与可能原因，并说明匿名共享的安全边界
