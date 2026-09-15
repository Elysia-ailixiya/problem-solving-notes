param(
    [ValidateSet("Install", "Check", "Restore")]
    [string]$Action = "Install",

    [string]$Proxy = "http://127.0.0.1:7890",

    [int]$TimeoutSeconds = 6
)

$ErrorActionPreference = "Stop"

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Get-CuaTarget {
    $root = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"

    if (-not (Test-Path $root)) {
        throw "未找到 CUA runtime 目录：$root"
    }

    $files = Get-ChildItem $root -Recurse -Filter "cua-repl.mjs" -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -like "*\bin\node_modules\@oai\cua-repl\bin\cua-repl.mjs"
        } |
        Sort-Object LastWriteTime -Descending

    if (-not $files) {
        throw "未找到 cua-repl.mjs。请先至少运行一次 ChatGPT 的 Chrome/Computer Use 功能后再重试。"
    }

    $target = $files[0].FullName

    $runtimeBase = $target
    1..6 | ForEach-Object { $runtimeBase = Split-Path $runtimeBase -Parent }

    $node = Join-Path $runtimeBase "bin\node.exe"
    if (-not (Test-Path $node)) {
        throw "找到 cua-repl.mjs，但未找到同一 runtime 下的 node.exe：$node"
    }

    [PSCustomObject]@{
        Root        = $root
        Target      = $target
        RuntimeBase = $runtimeBase
        Node        = $node
    }
}

function Get-ProxyParts([string]$ProxyUrl) {
    try {
        $uri = [Uri]$ProxyUrl
    }
    catch {
        throw "Proxy 参数不是有效 URL：$ProxyUrl"
    }

    if (-not $uri.Host -or -not $uri.Port) {
        throw "Proxy 参数必须包含主机和端口，例如：http://127.0.0.1:7890"
    }

    [PSCustomObject]@{
        Uri  = $uri
        Host = $uri.Host
        Port = $uri.Port
    }
}

function Test-ProxyPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Invoke-NodeFetchTest(
    [string]$NodePath,
    [string]$ProxyUrl,
    [int]$TimeoutSec,
    [switch]$UseProxy
) {
    $timeoutMs = [Math]::Max(1000, $TimeoutSec * 1000)
    $endpoint = "https://chatgpt.com/backend-api/aura/identity"

    if ($UseProxy) {
        $proxyJs = $ProxyUrl.Replace("\", "\\").Replace("'", "\'")
        $code = @"
process.env.HTTP_PROXY='$proxyJs';
process.env.HTTPS_PROXY='$proxyJs';
process.env.http_proxy='$proxyJs';
process.env.https_proxy='$proxyJs';
process.env.NO_PROXY='localhost,127.0.0.1,::1';
process.env.no_proxy='localhost,127.0.0.1,::1';
const http=require('node:http');
if(typeof http.setGlobalProxyFromEnv!=='function'){
  console.error('NO_SET_GLOBAL_PROXY');
  process.exit(3);
}
http.setGlobalProxyFromEnv();
fetch('$endpoint',{signal:AbortSignal.timeout($timeoutMs)})
  .then(r=>{console.log('HTTP '+r.status); process.exit(0);})
  .catch(e=>{console.error(e.name+': '+e.message); process.exit(2);});
"@
    }
    else {
        $code = @"
fetch('$endpoint',{signal:AbortSignal.timeout($timeoutMs)})
  .then(r=>{console.log('HTTP '+r.status); process.exit(0);})
  .catch(e=>{console.error(e.name+': '+e.message); process.exit(2);});
"@
    }

    $output = & $NodePath -e $code 2>&1
    $exit = $LASTEXITCODE

    [PSCustomObject]@{
        ExitCode = $exit
        Output   = ($output -join [Environment]::NewLine)
    }
}

function Get-PatchContent([string]$ProxyUrl) {
    @"
#!/usr/bin/env node

// ChatGPT CUA proxy patch
// This file may be replaced by a ChatGPT/Codex update.

import * as http from "node:http";

process.env.HTTP_PROXY = "$ProxyUrl";
process.env.HTTPS_PROXY = "$ProxyUrl";
process.env.http_proxy = "$ProxyUrl";
process.env.https_proxy = "$ProxyUrl";
process.env.NO_PROXY = "localhost,127.0.0.1,::1";
process.env.no_proxy = "localhost,127.0.0.1,::1";

if (typeof http.setGlobalProxyFromEnv !== "function") {
  throw new Error("Current Node runtime does not support http.setGlobalProxyFromEnv().");
}

http.setGlobalProxyFromEnv();

const cua_repl = await import("@oai/cua-repl");

try {
  await cua_repl.launch();
} catch (error) {
  const error_message = error instanceof Error ? error.message : String(error);
  console.error(``cua_repl could not start: `${error_message}``);
  process.exitCode = 1;
}
"@
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Show-TargetInfo($Info, [string]$ProxyUrl) {
    Write-Host "Runtime: $($Info.RuntimeBase)"
    Write-Host "Target : $($Info.Target)"
    Write-Host "Node   : $($Info.Node)"
    Write-Host "Proxy  : $ProxyUrl"
    try {
        $nodeVersion = & $Info.Node --version
        Write-Host "Node版本: $nodeVersion"
    }
    catch {}
}

$info = Get-CuaTarget
$proxyParts = Get-ProxyParts $Proxy

switch ($Action) {
    "Check" {
        Write-Section "当前环境"
        Show-TargetInfo $info $Proxy

        $raw = [System.IO.File]::ReadAllText($info.Target)
        $patched = $raw.Contains("ChatGPT CUA proxy patch") -and $raw.Contains("setGlobalProxyFromEnv")
        Write-Host ("补丁状态: " + $(if ($patched) { "已检测到补丁" } else { "未检测到补丁" }))

        $portOk = Test-ProxyPort $proxyParts.Host $proxyParts.Port
        Write-Host ("代理端口: " + $(if ($portOk) { "可连接" } else { "不可连接" }))

        Write-Section "Node 直连测试"
        $direct = Invoke-NodeFetchTest -NodePath $info.Node -ProxyUrl $Proxy -TimeoutSec $TimeoutSeconds
        Write-Host $direct.Output
        if ($direct.ExitCode -eq 0) {
            Write-Host "直连可以收到 HTTP 响应。" -ForegroundColor Green
        }
        else {
            Write-Host "直连未成功（这在需要代理的网络环境中可能是正常现象）。" -ForegroundColor Yellow
        }

        Write-Section "Node 显式代理测试"
        $proxied = Invoke-NodeFetchTest -NodePath $info.Node -ProxyUrl $Proxy -TimeoutSec $TimeoutSeconds -UseProxy
        Write-Host $proxied.Output
        if ($proxied.ExitCode -eq 0) {
            Write-Host "显式代理可用。HTTP 401/403 也算连通成功，因为测试请求没有 ChatGPT 登录凭据。" -ForegroundColor Green
        }
        else {
            Write-Host "显式代理测试失败。请检查 Clash 是否运行、端口是否正确。" -ForegroundColor Red
            exit 2
        }

        Write-Section "语法检查"
        & $info.Node --check $info.Target
        if ($LASTEXITCODE -eq 0) {
            Write-Host "cua-repl.mjs 语法正常。" -ForegroundColor Green
        }
        else {
            Write-Host "cua-repl.mjs 语法检查失败。" -ForegroundColor Red
            exit 3
        }
    }

    "Install" {
        Write-Section "准备安装代理补丁"
        Show-TargetInfo $info $Proxy

        if (-not (Test-ProxyPort $proxyParts.Host $proxyParts.Port)) {
            Write-Host "警告：当前无法连接代理 $Proxy。" -ForegroundColor Yellow
            Write-Host "请确认 Clash 已启动且端口正确。脚本仍可继续写入补丁。"
        }

        $current = [System.IO.File]::ReadAllText($info.Target)
        $desired = Get-PatchContent $Proxy

        if ($current.Contains("ChatGPT CUA proxy patch") -and $current.Contains("setGlobalProxyFromEnv")) {
            if ($current.Contains($Proxy)) {
                Write-Host "当前 runtime 已经安装相同代理补丁，无需重复修改。" -ForegroundColor Green
                & $info.Node --check $info.Target
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "但当前文件语法检查失败，请使用 -Action Restore 恢复。" -ForegroundColor Red
                    exit 3
                }
                exit 0
            }
            else {
                Write-Host "检测到已有补丁，但代理地址不同；将备份后更新。" -ForegroundColor Yellow
            }
        }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backup = "$($info.Target).bak-$stamp"
        Copy-Item $info.Target $backup -Force
        Write-Host "已备份：$backup"

        try {
            Write-Utf8NoBom -Path $info.Target -Text $desired

            & $info.Node --check $info.Target
            if ($LASTEXITCODE -ne 0) {
                throw "修改后的 cua-repl.mjs 语法检查失败。"
            }

            Write-Host "语法检查通过。" -ForegroundColor Green

            Write-Section "代理连通性验证"
            $test = Invoke-NodeFetchTest -NodePath $info.Node -ProxyUrl $Proxy -TimeoutSec $TimeoutSeconds -UseProxy
            Write-Host $test.Output

            if ($test.ExitCode -eq 0) {
                Write-Host "代理链路正常。HTTP 401/403 也表示已成功到达 chatgpt.com。" -ForegroundColor Green
            }
            else {
                Write-Host "补丁已写入且语法正常，但当前代理连通测试失败。" -ForegroundColor Yellow
                Write-Host "请检查 Clash/代理端口后再启动 ChatGPT。"
            }

            Write-Section "完成"
            Write-Host "补丁已安装。" -ForegroundColor Green
            Write-Host "现在请："
            Write-Host "1. 完全退出 ChatGPT（包括托盘进程）。"
            Write-Host "2. 保持 Clash 运行。"
            Write-Host "3. 重新启动 ChatGPT。"
            Write-Host "4. 在 Chrome 打开 https://example.com"
            Write-Host "5. 测试：读取当前 Chrome 标签页，并告诉我 example.com 页面的标题。"
            Write-Host ""
            Write-Host "注意：ChatGPT/Codex 更新后可能生成新的 cua_node runtime，需要重新运行本脚本。"
        }
        catch {
            Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host "正在自动恢复备份……" -ForegroundColor Yellow
            Copy-Item $backup $info.Target -Force
            throw
        }
    }

    "Restore" {
        Write-Section "恢复原文件"
        Show-TargetInfo $info $Proxy

        $dir = Split-Path $info.Target -Parent
        $name = Split-Path $info.Target -Leaf

        $backups = Get-ChildItem $dir -Filter "$name.bak-*" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

        if (-not $backups) {
            throw "当前 runtime 目录下没有找到备份文件：$name.bak-*"
        }

        $backup = $backups[0].FullName
        Write-Host "将恢复最新备份：$backup"

        Copy-Item $backup $info.Target -Force

        & $info.Node --check $info.Target
        if ($LASTEXITCODE -ne 0) {
            throw "恢复后语法检查仍失败，请手工检查备份文件。"
        }

        Write-Host "恢复完成，语法检查通过。" -ForegroundColor Green
        Write-Host "请完全退出并重新启动 ChatGPT。"
    }
}
