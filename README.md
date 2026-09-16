# problem-solving-notes

个人问题排查、解决方案与技术笔记。

## 已记录问题

### ChatGPT / Chrome

- [ChatGPT 无法读取/控制 Chrome 标签页：`nodeRepl.fetch request failed` 排查与修复](./ChatGPT/Chrome-Control-nodeRepl-fetch-failed/README.md)
  - 记录 Windows + ChatGPT Windows 客户端 + Chrome 扩展 + Clash 环境下的完整排查过程
  - 包含根因定位、CUA Node 代理验证、UTF-8 BOM 问题、最终修复方式
  - 附带自动检查/修复/恢复脚本和使用说明

### ChatGPT / 远程控制

- [ChatGPT Windows 无法启用远程控制：WebSocket `10060` 超时排查与修复](./ChatGPT/Remote-Control-WebSocket-10060/README.md)
  - 记录“无法启用远程控制，请重试”的完整定位过程
  - 说明为什么开启 Clash 全局模式和 TUN 开关后仍然无效
  - 包含 TUN 权限失败、DNS/直连验证、`HTTPS_PROXY` 修复及回滚方法
