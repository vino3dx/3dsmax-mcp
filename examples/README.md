# 示例 / Examples

| 文件 | 用途 |
| --- | --- |
| [`prompts.md`](prompts.md) | 直接粘给 AI 客户端的提示词，覆盖建模 / 材质 / 绑定 / 渲染 / 导出 |
| [`mcp-config.samples.json`](mcp-config.samples.json) | MCP 配置样例：`A_stdio`（WorkBuddy / Cursor / Claude Desktop / Claude Code / Cline / DeepSeek Harness）+ `B_http`（Streamable HTTP / 旧版 SSE / 带 token / 云端可达性） |
| [`python/direct_bridge.py`](python/direct_bridge.py) | 绕过 MCP，直接用 Python 跟桥接对话（调试 / 批处理脚本） |
| [`maxscript/listener_cheatsheet.ms`](maxscript/listener_cheatsheet.ms) | Max 内可用函数速查（Listener 直接跑） |

---

## 30 秒上手

```bash
# 1. 安装（默认语言 auto：跟随启动的 Max 界面语言）
python scripts/install.py --yes

# 2. 重启 3ds Max（自动加载器只在启动时扫描）

# 3. 确认桥接在线
python scripts/doctor.py
```

然后让 AI 说：

> 「在 0,0,0 建一个半径 20 的球体，给它一个红色哑光材质，然后渲一张 800×600 的图到 D:\renders\test.png。」

---

## 接入国产 / 云端 AI 客户端

**MCP 是客户端的能力，不是模型的能力** —— 智谱 GLM、DeepSeek、Kimi、通义只是模型；
能否调工具取决于挂着它们的客户端是否支持 MCP。两条接入路径：

| 路径 | 适用 | 怎么做 |
| --- | --- | --- |
| **stdio**（默认） | 本地客户端（WorkBuddy、Cursor、Cline、DeepSeek Harness…） | 客户端自己拉起 `python -m maxmcp`，配置见 `mcp-config.samples.json` 的 `A_stdio` |
| **HTTP**（`--http-port 8790`） | 云端 MCP 市场（智谱 BigModel 等）按 URL 注册，拉不起本地进程 | 跑 `--http-port` 生成的 `start-http.bat`，把 `http://127.0.0.1:8790/mcp` 填进去 |

```bash
# 生成 HTTP 启动器（同时也会写好 stdio 配置）
python scripts/install.py --yes --client workbuddy --http-port 8790
```

- Streamable HTTP 端点：`POST http://127.0.0.1:8790/mcp`
- 旧版 SSE 端点：`GET http://127.0.0.1:8790/sse` + `POST /messages`
- 探活：`GET http://127.0.0.1:8790/health`

> ⚠️ 默认只绑 `127.0.0.1`。云端平台通常**无法访问你本机的回环地址**，需要内网穿透 / 端口转发。
> 一旦对外暴露，**必须**加 `--http-token <随机串>`，非回环绑定不加 token 会被拒绝启动。

---

## 中英双语与自动跟随

插件默认 `language=auto`：桥接从 **Max 用户配置目录名**（`ENU`→英文，`CHS`/`CHT`→中文）
判断界面语言，服务端在 `initialize` 时同步。英文 Max 出英文工具说明，中文 Max 出中文说明，
无需手动切换、无需重启。

想固定在某个语言：

> 「把语言固定成英文」→ 调用 `set_language("en")`（持久化，胜过后面的自动检测）

> 「改回自动跟随 Max 界面」→ 调用 `set_language("auto")`

---

## 直接用 Python 跟桥接对话

不需要 MCP 客户端，也不需要服务端，适合调试和批处理：

```bash
# 先确认 Max 已启动并且桥接在线
PYTHONPATH=src python examples/python/direct_bridge.py
```

见 [`python/direct_bridge.py`](python/direct_bridge.py)。
