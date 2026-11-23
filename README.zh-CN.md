# 3dsmax-mcp
![3dsmax-mcp](https://raw.githubusercontent.com/vino3dx/3dsmax-mcp/old/3dsmax-mcp.jpg)

**让 AI 智能体直接驱动 Autodesk 3ds Max —— 建模、材质、绑定、动画、渲染、烘焙、导出。**

An MCP (Model Context Protocol) plugin that gives AI agents full control of Autodesk
3ds Max for modelling, shading, rigging, animation, rendering, baking and engine export.

---

## 目录

- [这是什么](#这是什么)
- [为什么不用 pymxs](#为什么不用-pymxs)
- [架构](#架构)
- [兼容性](#兼容性)
- [快速开始](#快速开始)
- [在 AI 客户端中使用](#在-ai-客户端中使用)
- [接入国产 AI 客户端](#接入国产-ai-客户端)
- [工具一览](#工具一览)
- [视觉反馈：让 AI 看到场景](#视觉反馈让-ai-看到场景)
- [工具档位](#工具档位)
- [中英双语切换](#中英双语切换)
- [配置](#配置)
- [故障排查](#故障排查)
- [项目结构](#项目结构)
- [开发](#开发)
- [许可](#许可)


---

## 这是什么

`3dsmax-mcp` 由两部分组成：

| 部分 | 运行位置 | 职责 |
| --- | --- | --- |
| **MCP 服务端** | 独立 Python 进程（stdlib-only） | 对 AI 客户端讲 MCP/JSON-RPC，对外暴露 **391 个工具** |
| **MAXScript 桥接** | 3ds Max 进程内（主线程） | 监听本地 TCP，执行真实场景操作 |

AI 客户端（Cursor / Claude Desktop / 任意 MCP 客户端）→ MCP 服务端 → 本地 TCP → 3ds Max 桥接 → 场景。

一句话：**装上之后，你对着 AI 说"给这个角色绑个骨骼并自动蒙皮"，它真的能在你的 Max 里做出来。**

---

## 为什么不用 pymxs

官方同类项目普遍依赖 3ds Max 内置的 **pymxs**（Python 桥）。这条路有三个硬伤：

1. **Python 版本地狱** —— 3ds Max 2020/2021 内置 Python 2.7，2022+ 才升到 Python 3。要写一份同时兼容的 pymxs 代码非常痛苦。
2. **主线程不安全** —— pymxs 从后台线程访问场景会崩溃。绕过它需要 `pymxs.runtime.execute` + 消息泵，复杂度高且脆弱。
3. **覆盖面窄** —— pymxs 并未暴露 Max 的全部功能，很多操作还是要回头写 MAXScript。

本项目**完全放弃 pymxs**，走纯 MAXScript 桥接：

- 只要求 Max 里有 **MAXScript**（2020 到 2027 都有）。
- 桥接的 TCP 监听用 `TcpListener` + `WinForms Timer` **在主线程泵**，天然没有跨线程问题。
- MAXScript 能碰到的东西，插件就能暴露 —— 覆盖率更高。

代价是 MAXScript 语言能力较弱（无 struct、无闭包），所以我们重写了一个纯 MAXScript 的 JSON 引擎，见 [`docs/BRIDGE_CONVENTIONS.md`](docs/BRIDGE_CONVENTIONS.md)。

---

## 架构

```
┌────────────────────┐   MCP / JSON-RPC 2.0    ┌──────────────────────────┐
│  AI client         │  ◀── stdio / HTTP ────▶ │  maxmcp (Python)         │
│  Cursor / Claude   │                         │  · catalog: 391 tools    │
│  WorkBuddy / Cline │                         │  · i18n: zh / en / auto  │
│  国产 AI 客户端     │                         │  · wire codec (ANSI)     │
└────────────────────┘                         └────────────┬─────────────┘
                     ├── stdio          （客户端拉起的本地进程）
                     ├── POST /mcp       （Streamable HTTP）
                     └── GET /sse        （旧版 HTTP+SSE）
                                                            │ TCP 127.0.0.1:8765
                                                            │ newline-delimited JSON
                                               ┌────────────▼─────────────┐
                                               │  mcp_bridge.ms           │
                                               │  TcpListener + WinForms  │
                                               │  Timer pump (main thread)│
                                               ├──────────────────────────┤
                                               │  mcp_json.ms   JSON 引擎 │
                                               │  mcp_core.ms   注册/派发 │
                                               │  mcp_net.ms    TCP 泵    │
                                               │  ... 16 个功能模块       │
                                               └────────────┬─────────────┘
                                                            │
                                                      3ds Max scene
```

### 线协议

- **ASCII-only**，换行分隔 JSON。所有非 ASCII 字符（中文、日文……）在 Python 侧用 **本地 ANSI 代码页字节**转义成 `\u00XX` 序列往返，避免任何编码歧义。
- Max 侧单字节解码，Python 侧用 `mbcs`（Windows）编码/解码。
- 每个工具调用自动包在 `theHold` 里（由调度器按注册表的 `undoable` 标志决定），所以 **AI 的每一步都可撤销**。

---

## 兼容性

| 项目 | 支持范围 |
| --- | --- |
| 3ds Max | **2020 – 2027+**（64-bit） |
| Max 语言版本 | ENU / CHS / CHT / JPN / KOR / DEU / FRA / ESP / ITA / PTB / RUS |
| Python（服务端） | **3.8+**，**纯标准库，零运行时依赖** |
| MCP 传输 | **stdio**、**Streamable HTTP**（`POST /mcp`）、**旧版 HTTP+SSE**（`GET /sse`） |
| MCP 协议 | `2025-06-18`（兼容 `2025-03-26`、`2024-11-05`） |
| 客户端 / 模型 | 不限。客户端支持 MCP 即可 —— Claude、GPT、**GLM、DeepSeek、Kimi、通义** 等都行 |
| 操作系统 | Windows 10 / 11 |

> **关于 pymxs**：不使用，所以 2020 的 Python 2.7 完全不是问题。

---

## 快速开始

### 1. 安装

```bash
cd 3dsmax-mcp
python scripts/install.py --yes
```

安装器会：

1. 扫描所有 3ds Max 用户脚本目录（`%LOCALAPPDATA%\Autodesk\3dsMax\<年份> - 64bit\<语言>\scripts`）。
2. 把 23 个 MAXScript 模块复制到 `<scripts>\3dsmax-mcp\`。
3. 写入启动自动加载器 `<scripts>\startup\3dsmax-mcp-bridge.ms` 与端口/语言配置 `<scripts>\3dsmax-mcp\3dsmax-mcp.ini`。
4. 把 Python 服务端复制到 `%LOCALAPPDATA%\3dsmax-mcp\maxmcp`。
5. 注册 MCP 客户端（Cursor / Claude Desktop）。
6. 写安装清单 `%LOCALAPPDATA%\3dsmax-mcp\install-manifest.json`（供诊断与卸载使用）。

常用参数：

```bash
python scripts/install.py --list              # 只看检测结果，不安装
python scripts/install.py --client workbuddy cursor cline --yes
python scripts/install.py --client print      # 只打印 JSON，贴到任何客户端
python scripts/install.py --port 9000 --language en --profile modeling
python scripts/install.py --http-port 8770    # 额外提供 HTTP 端点（云端客户端用）
python scripts/install.py --uninstall         # 卸载
```

### 2. 重启 3ds Max

自动加载器只在 **Max 启动时**扫描 `scripts\startup`。所以装完必须重启 Max。

重启后打开 **MAXScript Listener**，应看到类似横幅：

```
========================================================
  3ds Max MCP bridge
  ----------------------------------------------------
  Status      : listening
  Address     : 127.0.0.1:8765
  3ds Max     : 2020 (major 22)
  Commands    : 359
  Language    : zh
  Pump timer  : true
  ----------------------------------------------------
  Stop with   : mcpBridgeStop()
  Diagnose    : mcpSelfTest()
========================================================
```

> 不重启也行：在 Listener 里执行
> `fileIn @"C:\Users\<你>\AppData\Local\Autodesk\3dsMax\2020 - 64bit\ENU\scripts\3dsmax-mcp\mcp_bridge.ms"`

### 3. 自检

```bash
python scripts/doctor.py
```

逐环检查并给出结论：

```
-- environment
  [ok]   Python 3.13.14 at ...\python.exe
  [ok]   MCP server package (installed)
         391 tools (animation=59, context=6, files=8, modeling=83, objects=61, pipeline=54, scene=18, shading=69, system=33)
-- 3ds Max side
  [ok]   3ds Max 2020 [CHS]: 23 bridge modules + autoloader
  [ok]   3ds Max 2020 [ENU]: 23 bridge modules + autoloader
  [ok]   3ds Max is running
-- connectivity
  [ok]   Bridge listening on port 8765
  [ok]   Live handshake succeeded
         handlers=359  language=zh  3ds Max year=2020
  [ok]   Language: zh from Max UI 'CHS' (auto)
         The server follows this while its own language is 'auto'.
-- MCP clients
  [ok]   WorkBuddy: 3dsmax-mcp registered
  [ok]   Cursor: 3dsmax-mcp registered
  [ok]   Registered with 3 MCP client(s)
```

Max 未运行时对应的一行是 `[warn] No bridge listening on 8765, 8766, ...`，其余检查照常通过。
没装的客户端不会报警告，只有"装了但没注册"才会提示。

---

## 在 AI 客户端中使用

### Cursor

安装器会写入 `~\.cursor\mcp.json`：

```json
{
  "mcpServers": {
    "3dsmax-mcp": {
      "command": "C:\\Users\\<你>\\AppData\\Local\\Programs\\Python\\Python313\\python.exe",
      "args": ["-m", "maxmcp", "--port", "8765", "--language", "auto", "--profile", "full"],
      "env": {
        "PYTHONPATH": "C:\\Users\\<你>\\AppData\\Local\\3dsmax-mcp",
        "MAXMCP_PORT": "8765",
        "MAXMCP_LANGUAGE": "auto"
      }
    }
  }
}
```

重启 Cursor，在 **Settings → MCP** 里应看到 `3dsmax-mcp` 已连接、391 个工具。

### Claude Desktop

`%APPDATA%\Claude\claude_desktop_config.json`，结构同上。

### 任意其他 MCP 客户端

```bash
python -m maxmcp --no-stdio
```

stdio 上的 JSON-RPC 服务端，`initialize` → `tools/list` → `tools/call` 标准流程。
不限定模型：客户端用 Claude、GPT、GLM、DeepSeek 还是 Kimi 都一样。

### 可以这样跟 AI 说

> - 「创建一个 6 面盒子，加 3 级 TurboSmooth，然后转成可编辑多边形。」
> - 「给这个角色生成一套脊椎+四肢骨骼链，绑上 Skin 并自动权重。」
> - 「把这个高模的细节烘焙成法线贴图，输出 2048。」
> - 「布置一个三点布光，建一个物理相机，渲一张 1920×1080 的静帧到 D:\renders。」
> - 「把选中对象导出成 FBX，用 UE5 预设，单位改成厘米。」
> - 「把场景里所有以 `SM_` 开头的对象列出来，统计每个的面数。」

---

## 工具一览

共 **391 个工具**，分 9 类：

| 分类 | 数量 | 覆盖内容 |
| --- | ---: | --- |
| `system` | 33 | 桥接控制、握手、脚本逃逸仓、undo/redo 事务、单位与时间配置、内省 |
| `scene` | 18 | 场景新建/打开/保存/合并、图层、资源与丢失贴图重链 |
| `files` | 8 | 文本读写、目录列举、复制/删除、文件信息 |
| `objects` | 61 | 基础体与样条、变换/对齐/镜像/轴心、层级与父子、组、选择、隐藏冻结、克隆阵列、布尔/ProBoolean |
| `modeling` | 83 | 可编辑多边形（点/边/面全套操作）、修改器栈管理与 30+ 常用修改器、放样/扫掠/路径变形 |
| `shading` | 69 | 材质读写与赋给、PBR/Arnold/V-Ray/Corona/FStorm 材质、贴图节点、材质库、UVW 贴图与 Unwrap、灯光、相机、环境 |
| `animation` | 59 | 关键帧与曲线、控制器与表达式、约束、骨骼与 IK、蒙皮权重、Morpher |
| `pipeline` | 54 | 渲染引擎与设置、单帧/帧序列/批渲染、渲染元素、**视口截图（vision_capture / vision_views / vision_preview，直接返回图像）**、烘焙（AO/法线/光照/贴图）、导入导出（FBX/OBJ/glTF/USD/ABC/STL/3DS）与引擎预设 |
| `context` | 6 | **场景上下文**（`context_get` / `context_refresh` / `context_stats` / `context_events`）、内置面板（`client_ui` / `client_status`）

查看完整列表：

```bash
python -m maxmcp --list-tools
```

几个值得一提的：

- **`bridge_status` / `bridge_selftest`** —— 连接状态；Max 内 **13 项**自检（JSON 往返、中文往返、界面语言探测、对象创建、undo、TCP 监听）。
- **`execute_maxscript`** —— 逃逸仓。任何没被工具覆盖的操作，AI 可以直接写 MAXScript 执行（`asOneUndo` 包裹）。
- **`undo_last` / `begin_undo` / `end_undo` / `cancel_undo`** —— 显式事务，方便让 AI 把"一整套建模操作"合成**一步**撤销。
- **`bridge_capabilities`** —— 运行时报告桥接模块、命令数、当前语言、Max 版本，AI 可以自己发现能力边界。
- **`find_missing_assets` / `relink_assets`** —— 换机器打开工程时的贴图重链。
- **`workflow_run`** —— 把一串工具调用变成一条**可验证**的执行记录：每步都声明
  "做到什么算成功"（`verification`），跑完给出逐步状态、场景前后差异（`diff`）和目标是否达成
  （`expectation`）。内置 `basic_scene` / `model_processing` / `material_look` 三条标准工作流，
  也可以自己传 `steps`。**修改类操作失败后绝不自动重试**，只回一份"重新读过场景"的 `recovery`。
- **`scene_snapshot`** —— 拍一份场景快照并可对任意历史快照做 diff（新增/删除/变换/材质/
  修改器/选择集）。重命名不会被误报成"删了一个又建了一个"，证不出来的身份进 `identity_uncertain`。
  见 [`docs/SCENE_SNAPSHOT_DIFF.md`](docs/SCENE_SNAPSHOT_DIFF.md)。

---

## 场景工作流

Agent 做场景从来不是"一次调用"，而是十几步：读场景 → 确认对象身份 → 建几何 →
摆位置 → 转多边形 → 挤面 → 加修改器 → 上材质 → 截图确认 → 存盘。
`workflow_run` 把这条链路变成**可观察、可验证、可恢复**的一次执行：

```jsonc
// 跑内置工作流
{ "name": "workflow_run", "arguments": { "workflow": "basic_scene" } }

// 或者自己描述一套步骤
{ "name": "workflow_run", "arguments": {
    "steps": [
      { "id": "mk", "operation": "create_box", "arguments": { "name": "Cube" },
        "verification": { "kind": "exists", "objects": ["Cube"] } },
      { "id": "mv", "operation": "transform_object",
        "arguments": { "objects": ["Cube"], "operation": "move",
                       "mode": "absolute", "value": [0, 0, 25] },
        "verification": { "kind": "transform", "object": "Cube", "position": [0, 0, 25] },
        "depends_on": ["mk"] }
    ],
    "expect": { "added_includes": ["Cube"], "count_delta": 1 } } }
```

返回里每步都区分三件事：**执行成功**（`execution`）、**验证结果**
（`verification_passed` / `verification_failed` / `verification_unavailable`）、
**最终状态**（`success` / `verification_failed` / `failed` / `skipped` / `interrupted`）。
整体状态是 `success` / `partial` / `failed` / `interrupted` —— **部分成功永远不写成成功**。

详见 [`docs/WORKFLOW_EXECUTION_MODEL.md`](docs/WORKFLOW_EXECUTION_MODEL.md)、
[`docs/WORKFLOW_ACCEPTANCE.md`](docs/WORKFLOW_ACCEPTANCE.md)、
[`docs/AGENT_WORKFLOW_CAPABILITY.md`](docs/AGENT_WORKFLOW_CAPABILITY.md)。

---

## 视觉反馈：让 AI 看到场景

纯文本的工具结果只能告诉 AI「命令执行了」，不能告诉它「这一步到底做成了什么样」——
对象有没有翻面、材质是不是白的一片、模型有没有跑出画面，JSON 里都看不出来。
`pipeline` 类目下的三个视觉工具把画面**直接作为 MCP 图片内容块返回**给 AI，形成
「修改 → 截图 → 检查 → 再修改」的闭环。它们都是只读工具（不写场景）。

> **返回的是图片本身，不是本地路径。** 桥接端只能传 JSON 文本，所以 MAXScript 把
> 图片的 base64 放在结果的 `_images` 数组里；服务端收到后把每一项转成真正的 MCP
> `image` content block，文本部分只留下 `images` 描述（label / mimeType /
> base64Chars）。能显示图片的客户端会直接看到画面；不能显示图片的客户端至少保留
> 元数据，不会把像素弄丢。`vision_capture` 额外支持用 `path` 参数把图片另存一份到
> 本机磁盘，方便人自己打开看。

### vision_capture —— 当前视口截图

抓当前活动视口的一帧。参数（均为可选）：

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `max_edge` | integer | 800 | 图片长边像素上限，代码钳制在 64–2048 |
| `format` | string | `jpeg` | `jpeg`（默认，体积小）或 `png`（无损） |
| `redraw` | boolean | `true` | 抓图前强制重绘；关掉会拿到上一帧的旧画面 |
| `path` | string | 空 | 可选：同时把图片写到该绝对路径（会自动建目录） |

返回文本含 `width` / `height` / `mime` / `bytes`，图片块的 label 为 `active`；
写了 `path` 时还会带 `path`。抓图失败（视口无帧缓冲）返回错误，不会假装成功。

### vision_views —— 多视角截图

依次切到多个标准视图各抓一张，**每张都是独立图片块**，不拼成网格图（拼图会被整体
降采样，每格细节损失数倍）。参数（均为可选）：

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `views` | string[] | `["perspective","front","left","top"]` | 可选视角：`perspective` / `front` / `back` / `left` / `right` / `top` / `bottom` / `orthographic` / `user`；代码最多取前 6 个 |
| `max_edge` | integer | 800 | 每张长边像素，钳制 64–2048 |
| `format` | string | `jpeg` | `jpeg` 或 `png` |
| `fit` | boolean | `true` | 抓图前缩放视图到场景（有选择时缩放到选择） |
| `restore` | boolean | `true` | 抓完后恢复原视图类型与视角 |

返回文本含 `count`、`max_edge` 和 `views`（每张的 view / width / height），每张图片的
label 就是视角名。有选择集但没抓到任何一张时返回错误。

### vision_preview —— 渲染预览

低分辨率渲染一张预览图，**唯一一个参数**是 `max_edge`（integer，默认 640，钳制
64–1600，越大越慢）。视口截图不反映真实材质和灯光，确认灯光、材质、最终外观时用这个。
输出固定为 `image/jpeg`，图片块 label 为 `render`。场景改动后第一次渲染可能要几十秒
（着色器编译），这不是卡死。

### Agent 怎么用截图

AI 在一个操作回合里的典型闭环：

1. **动手前**先看一眼：`vision_capture` 确认当前状态，避免基于臆测修改。
2. **每步改动后**抓一张：改完几何体 / 材质 / 灯光就 `vision_capture`，看这一步实际
   做成了什么，而不是只信工具返回的 `ok`。
3. **看全貌**用 `vision_views`：判断比例、朝向、空间关系，或检查背面 / 顶部有没有问题。
4. **验收外观**用 `vision_preview`：材质和灯光的最终效果只有渲染图能确认。
5. **发现问题就回到第 2 步**：把截图发现的问题和预期对比，继续修改并重新截图，直到
   画面符合预期。

这样能发现纯文本工具发现不了的问题：模型翻面、材质丢失变白、对象出画、灯光过曝、
比例失真等。截图回灌不新增工具，只是把已有的三个视觉工具用进验证环节。

### 可复制的调用示例

```jsonc
// 当前视口截图，长边压到 640，另存一份到本机
{ "name": "vision_capture",
  "arguments": { "max_edge": 640, "format": "jpeg", "redraw": true,
                 "path": "D:/renders/check.png" } }

// 一次抓透视 + 前 + 顶三个独立视角
{ "name": "vision_views",
  "arguments": { "views": ["perspective", "front", "top"],
                 "max_edge": 800, "fit": true, "restore": true } }

// 渲染一张 640px 预览确认材质灯光
{ "name": "vision_preview", "arguments": { "max_edge": 640 } }
```

### 限制（以代码为准）

- **视口状态依赖**：`vision_capture` 抓的是当前活动视口；`redraw=false` 会拿到上一帧旧画面。
  视口被遮挡、最小化或无帧缓冲时抓取失败并返回错误。
- **多视角有上限**：`vision_views` 最多取前 6 个视角；每张图都要切视图 + 重绘，视角越多越慢。
- **渲染耗时**：`vision_preview` 场景改动后首次渲染可能数十秒（着色器编译）；它依赖当前
  渲染器，不同渲染器结果和耗时不同。
- **图片尺寸**：`vision_capture` / `vision_views` 的 `max_edge` 钳制在 64–2048，
  `vision_preview` 在 64–1600；`vision_preview` 按当前渲染宽高比算高，固定输出 jpeg。
- **上下文体积**：图片比文本占额度得多，`max_edge` 越大越清楚也越慢、越占上下文；按需调低。
- **纯文本客户端**：只能看到 `images` 元数据（label / mimeType / base64Chars），看不到画面。

---

## 工具档位

391 个工具全塞进上下文会明显占额度。用 `--profile` 按需裁剪：

| 档位 | 工具数 | 包含分类 |
| --- | ---: | --- |
| `core` | 60 | field-tested modeling loop and session essentials |
| `modeling` | 209 | core + modeling |
| `lookdev` | 195 | core + shading |
| `animation` | 185 | core + animation |
| `pipeline` | 180 | core + pipeline |
| `full` | **391** | 全部（默认） |

```bash
python -m maxmcp --profile modeling
# 或改配置持久化
python -m maxmcp --list-profiles
```

也可以在客户端配置的 `args` 里加 `"--profile", "lookdev"`。

---

## 中英双语切换

**两种语言同时生效，不需要重启，而且默认自动跟随 3ds Max 的界面语言。**

- 每个工具都带 `description_zh` 和 `description_en`。
- 参数描述内联为 `中文 | English`。
- `set_language("zh" | "en" | "auto")` 是**普通工具调用**，AI 自己就能切。

### 自动语言（默认）

安装时 `--language` 默认是 **`auto`**：服务端和桥接都会去读 3ds Max 的界面语言
（`ENU` / `CHS` / `CHT` / `JPN` …，从 Max 的用户配置目录名读出），然后自动选用中文或英文。

| 3ds Max 界面语言 | 插件使用 |
| --- | --- |
| `CHS`（简体中文） | 中文 |
| `CHT`（繁体中文） | 中文（给的是简体，比英文更可读） |
| `ENU`（英文） | English |
| 其他（`JPN` / `DEU` / `FRA` …） | English（没有对应词条，退回英文） |

所以一台中文 Max 的机器和一台英文 Max 的机器，**用同一份安装、同一份配置**，
各自看到自己语言的消息 —— 不需要任何手动设置。

```jsonc
// AI 也可以随时显式切换，或交回自动
{ "name": "set_language", "arguments": { "language": "en"   } }   // 固定英文
{ "name": "set_language", "arguments": { "language": "auto" } }   // 跟随 Max
```

**固定 vs 自动的规则：**

- 默认 `auto`。服务端在 `initialize` 时和首次成功调用后各探测一次桥接语言，采纳它。
- 一旦显式 `set_language("zh"|"en")`，就**固定下来**（写入 `config.json`），不再跟随。
- `set_language("auto")` 交回自动。

固定启动语言（不再跟随）：

```bash
python -m maxmcp --language en      # 或 zh
# 或环境变量 MAXMCP_LANGUAGE=en
# 或安装时 python scripts/install.py --language en
# 或改 %USERPROFILE%\.3dsmax-mcp\config.json 里的 "language"
```

桥接端自己的提示信息（Listener 横幅、错误文本）同样双语，由 `max\3dsmax-mcp.ini`
的 `language=` 控制（`auto` / `zh` / `en`）。横幅会直接告诉你它选了哪个：

```
  Language    : zh (auto: CHS)
  Language    : en (pinned)
```

---

## 接入国产 AI 客户端

**MCP 是"客户端能力"，不是"模型能力"。** 智谱 GLM、DeepSeek、Kimi、通义 都是模型；
真正挂载 MCP 工具的是**客户端**。所以只要客户端支持 MCP，用哪个模型都无所谓。

### 两种接入方式

| 方式 | 适用 | 传输 |
| --- | --- | --- |
| **客户端拉起本地进程** | WorkBuddy、Cursor、Claude Code、Cline、Roo Code、Windsurf、DeepSeek Harness（本地） | **stdio**（默认，无需额外配置） |
| **按 URL 注册** | 智谱 BigModel、阿里云百炼等**云端 Agent 平台**，以及任何跑在浏览器/云端的客户端 | **Streamable HTTP** 或 **HTTP+SSE** |

云端平台**不可能拉起你本机的进程**，所以它们只吃 HTTP。插件为此内置了 HTTP 传输。

### stdio 接入（推荐，零额外配置）

```bash
python scripts/install.py --client workbuddy cursor cline --yes
```

安装器会自动检测机器上装了哪些客户端并写入各自的配置。目前认识这些：

| 客户端 | 配置文件 |
| --- | --- |
| **WorkBuddy** | `~/.workbuddy/mcp.json` |
| Cursor | `~/.cursor/mcp.json` |
| Claude Desktop | `%APPDATA%\Claude\claude_desktop_config.json` |
| Claude Code | `~/.claude.json` |
| Cline (VS Code) | `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json` |
| Roo Code (VS Code) | `%APPDATA%\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |

写入是**合并**的（不动其他 server），并且每次写入前先备份成 `.bak`。

看看检测到什么：

```bash
python scripts/install.py --list
```

其他客户端（Cherry Studio、Chatbox、LobeChat、DeepSeek Harness…）拿现成的 JSON：

```bash
python scripts/install.py --client print
```

### HTTP 接入（云端平台 / 按 URL 注册）

```bash
python scripts/install.py --client print --http-port 8770
```

这会输出 URL 形式的配置，并生成一个启动器
`%LOCALAPPDATA%\3dsmax-mcp\start-http.bat`：

```json
{
  "mcpServers": {
    "3dsmax-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:8770/mcp"
    }
  }
}
```

**双开这个启动器（或它里面的命令）并保持窗口开着**，然后：

| 端点 | 用途 |
| --- | --- |
| `POST /mcp` | Streamable HTTP（2025-03-26+ 规范）。也支持批量请求 |
| `GET /sse` + `POST /messages?sessionId=…` | 旧版 HTTP+SSE（2024-11-05），老客户端和部分国产平台还在用 |
| `GET /health` | 探活，返回服务状态 |

手动启动：

```bash
python -m maxmcp --transport http --http-port 8770
python -m maxmcp --transport both                      # stdio + http 同进程

# 需要暴露到局域网/公网时，务必加令牌（否则启动会被拒绝）
python -m maxmcp --transport http --http-host 0.0.0.0 --http-token 你的密钥
```

> ⚠️ **安全**：HTTP 端点默认只绑 `127.0.0.1`（回环）。**改绑到非回环地址
> （`0.0.0.0`、`::`、局域网 IP）时必须同时提供 `--http-token`，否则服务端
> 会直接拒绝启动**（exit 2），不会因为疏忽而把接口暴露出去。客户端用
> `Authorization: Bearer <token>` 携带令牌。绑到非回环且带令牌时会打印醒目警告。

> 云端平台要访问你本机的 `127.0.0.1`，需要自己做端口转发（frp / ngrok / 反向代理）。
> 这属于网络暴露，风险自负 —— 建议只在内网使用。

### 安全边界（发布部署前必读）

这个 MCP 服务把 3ds Max 的**场景操作能力**暴露给 AI 客户端。理解下面几类工具的权限边界，
只在**你信任的客户端与环境**中使用：

| 工具 / 通道 | 能力 | 风险含义 |
| --- | --- | --- |
| `execute_maxscript` | 执行**任意 MAXScript** | 等价于在 Max 里手敲脚本：可读写场景、调用文件 I/O、改配置。仅在可信 Agent 下启用 |
| `execute_python` | 执行**任意 Python**（经 Max 内 pymxs） | 同上，且能访问本机 Python 可见资源 |
| `write_text_file` / `delete_file` / `copy_file` | 读写/删除**本机任意路径** | 参数里的路径没有沙箱白名单，AI 可写到任意可访问位置 |
| `scene_open` / `scene_save_as` | 打开/覆盖 `.max` 文件 | 覆盖已有工程前请自行备份；不要让不可信输入决定路径 |
| 导出类工具（`export_*` / `bake_render`） | 写文件到指定路径 | 同上，路径由调用方给出 |

**网络暴露**：TCP 桥接（`8765`）默认只监听 `127.0.0.1`，**没有认证**，且工具参数无法把它
改成非回环地址 —— 不要把该端口做端口转发或暴露到局域网/公网。比桥接更敏感的是 HTTP 端点：
能访问它且持有令牌的人即可远程执行上面的任意代码工具。令牌**不是**防火墙的替代品，
暴露部署时请同时用系统防火墙 / 安全组限制来源 IP。回环监听带有 Host 头校验（防 DNS rebinding），
非回环监听不发 `Access-Control-Allow-Origin: *`。

**降低权限面**：用工具档位和分类禁用收敛暴露给 AI 的能力：

```bash
python -m maxmcp --profile core          # 只暴露核心只读 + 常用工具子集
```

```json
// config.json —— 禁用整类高危工具（例如禁止脚本执行）
{ "disabled_categories": ["system"] }
```

`execute_maxscript` / `execute_python` 属于 `system` 类；在多人共享或生产机上建议禁用。
注意：档位与分类过滤只影响**工具列表的呈现**，网关/传输层本身不按此鉴权 —— 它不是安全沙箱，
真正的边界是"只连本机 + 可信客户端"。

### 工具名长度

部分客户端会把工具名规范成 `mcp__<服务器名>__<工具名>` 并按 64 字符截断。
本插件最长的工具名是 28 字符，加前缀后 48 字符，在截断线以内。

---

## 配置

优先级：**环境变量 > 用户配置 > 内置默认**。

用户配置：`%USERPROFILE%\.3dsmax-mcp\config.json`（可用 `MAXMCP_HOME` 改目录）。

```json
{
  "host": "127.0.0.1",
  "port": 8765,
  "port_scan": 10,
  "timeout_s": 120.0,
  "connect_timeout_s": 2.0,
  "language": "auto",
  "bilingual": true,
  "tool_profile": "full",
  "max_response_chars": 200000,
  "disabled_categories": [],
  "transport": "stdio",
  "http_host": "127.0.0.1",
  "http_port": 8770,
  "http_token": "",
  "http_path": "/mcp"
}
```

| 环境变量 | 说明 |
| --- | --- |
| `MAXMCP_PORT` | 桥接端口，默认 `8765` |
| `MAXMCP_LANGUAGE` | `auto`（默认）/ `zh` / `en` |
| `MAXMCP_PROFILE` | 工具档位 |
| `MAXMCP_BILINGUAL` | `1`/`true` 输出双语描述 |
| `MAXMCP_TIMEOUT` | 单次调用超时（秒） |
| `MAXMCP_HOST` | 默认 `127.0.0.1` |
| `MAXMCP_HOME` | 配置目录 |
| `MAXMCP_TRANSPORT` | `stdio`（默认）/ `http` / `both` |
| `MAXMCP_HTTP_HOST` / `MAXMCP_HTTP_PORT` | HTTP 绑定地址与端口 |
| `MAXMCP_HTTP_TOKEN` | HTTP 访问令牌（`Authorization: Bearer`） |
| `MAXMCP_HTTP_PATH` | HTTP 端点路径，默认 `/mcp` |

`port_scan` 让服务端在 8765 被占用时自动往后试 8766…8774。

> **端口必须两边一致。** 桥接从 `3dsmax-mcp.ini` 读端口，服务端从 `config.json` 读端口。
> 两者不一致时服务端会在错误的端口上找桥接，每次调用都报"没有桥接在监听"。
> 安装器是唯一同时知道两边的地方，所以它会自动同步 `port` / `language` / `tool_profile`
> 到 `config.json`（其余键保持不动）。手动改端口后重跑一次 `install.py` 即可。
>
> 另外，运行时的 `--port` / `--profile` 是**一次性的**，不会被写回配置文件 —— 只有
> `set_language` 会持久化，且只持久化语言本身。

---

## 示例

[`examples/`](examples/) 里有：

- [`prompts.md`](examples/prompts.md) —— 16 条可直接粘给 AI 的提示词（建模 / 材质 / 灯光 / 动画 / 绑定 / 烘焙 / 导出 / 场景整理），每条都注明预期调用的工具。
- [`mcp-config.samples.json`](examples/mcp-config.samples.json) —— Cursor 与 Claude Desktop 的配置样例。
- [`python/direct_bridge.py`](examples/python/direct_bridge.py) —— 绕过 MCP，直接用 Python 跟桥接对话，适合调试和批处理。
- [`maxscript/listener_cheatsheet.ms`](examples/maxscript/listener_cheatsheet.ms) —— Max Listener 可用的函数速查（`mcpSelfTest()`、`mcpNetStatus()`、编码自检等）。

---

## 故障排查

先跑诊断：

```bash
python scripts/doctor.py
```

| 症状 | 原因与处理 |
| --- | --- |
| `No bridge listening on 8765...` | Max 没开，或装完没重启 Max。重启，或在 Listener 里手动 `fileIn` 桥接脚本。 |
| 工具调用超时 | 桥接的 `WinForms Timer` 泵被一个长阻塞操作（比如大场景批渲染）卡住。调大 `MAXMCP_TIMEOUT`。 |
| 中文变成 `?` 或乱码 | 服务端与 Max 的 ANSI 代码页不一致。跑 `bridge_selftest` 看"中文往返"一项。 |
| 语言不对（该中文却出英文） | 跑 `bridge_status` 看 `language` / `maxLanguage` / `languagePinned`。若之前显式 `set_language` 过就是被固定了，调 `set_language("auto")` 交回自动。 |
| `No module named maxmcp` | `PYTHONPATH` 没指到安装目录。重跑 `install.py`。 |
| 端口被占用 | 改 `--port`，或让 `port_scan` 自动跳。 |
| 工具太多、上下文爆 | 换小档位 `--profile lookdev` 等。 |
| HTTP 客户端连不上（`Connection refused`） | HTTP 端点不是常驻服务，得先跑 `start-http.bat` 或 `python -m maxmcp --transport http`。 |
| HTTP 返回 401 | 服务端设了 `--http-token`，客户端要带 `Authorization: Bearer <token>`。 |
| HTTP 启动报 `REFUSED to start` | 绑定了非回环地址却没给 `--http-token`。改回 `--http-host 127.0.0.1`，或补上令牌。 |
| HTTP 返回 403（Host forbidden） | 回环无令牌模式下，请求的 `Host` 头不是本机地址（可能是 DNS rebinding）。用 `127.0.0.1` / `localhost` 访问。 |
| 国产平台（智谱/百炼）加不上 | 它们按 URL 注册，只吃 HTTP/SSE，且**访问不到你本机的 127.0.0.1**。需要端口转发把端点暴露出去。 |
| Max 重启后语言变了 | 若 `3dsmax-mcp.ini` 里是 `auto`，这是预期行为（跟随 Max）。想固定就重装带 `--language zh`。 |

Max 内自检：连上之后让 AI 调 `bridge_selftest`，或在 Listener 里

```maxscript
mcpSelfTest()
```

---

## 项目结构

```
3dsmax-mcp/
├── src/
│   ├── python/maxmcp/         # Python MCP 服务端（stdlib-only，部署到 %LOCALAPPDATA%\3dsmax-mcp）
│   │   ├── server.py          #   JSON-RPC 分发、tools/list、tools/call、自动语言、图像块拆分
│   │   ├── http_transport.py  #   Streamable HTTP (/mcp) + 旧版 HTTP+SSE (/sse)
│   │   ├── bridge.py          #   TCP 客户端与错误类型
│   │   ├── protocol.py        #   无依赖 JSON-RPC + stdio 传输 + image content block
│   │   ├── wire.py            #   ANSI 线编解码（中文往返的关键）
│   │   ├── i18n.py            #   双语消息层 + Max 语言码映射
│   │   ├── config.py          #   配置加载
│   │   └── catalog/           #   391 个工具定义
│   │       ├── schema.py      #     Tool 类 + 档位 + DSL
│   │       ├── core.py        #     system / scene / files
│   │       ├── objects.py     #     objects
│   │       ├── modeling.py    #     modeling（含修改器栈扩展）
│   │       ├── shading.py     #     shading
│   │       ├── animation.py   #     animation
│   │       └── pipeline.py    #     pipeline（渲染/烘焙/导入导出 + vision 截图）
│   └── ms/                    # MAXScript 桥接（字节级部署到 Max 用户脚本目录）
│       ├── mcp_bridge.ms      #   入口：加载 22 个模块、启停桥接、语言解析
│       ├── mcp_json.ms        #   纯 MAXScript JSON 引擎
│       ├── mcp_core.ms        #   命令注册表、消息表、节点解析、语言探测
│       ├── mcp_domains.ms     #   每个命令写脏哪些 context 域（生成文件，勿手改）
│       ├── mcp_net.ms         #   TCP 监听 + 主线程 Timer 泵 + 调度
│       ├── mcp_system.ms      #   系统 / undo / 单位 / 脚本逃逸仓
│       ├── mcp_objects.ms     #   对象与样条
│       ├── mcp_poly.ms        #   可编辑多边形
│       ├── mcp_modifiers.ms   #   修改器栈与修改器
│       ├── mcp_modeling_ext.ms#   修改器开关/塌陷 + 多边形选择查询扩展
│       ├── mcp_shading.ms     #   材质 / 贴图 / UVW
│       ├── mcp_lights.ms      #   灯光 / 相机 / 环境
│       ├── mcp_animation.ms   #   动画 / 控制器 / 约束
│       ├── mcp_rigging.ms     #   骨骼 / IK / 蒙皮 / Morpher
│       ├── mcp_render.ms      #   渲染
│       ├── mcp_bake.ms        #   烘焙
│       ├── mcp_export.ms      #   导入导出
│       ├── mcp_scene.ms       #   场景 / 图层 / 资源
│       ├── mcp_vision.ms      #   视口截图（base64 图像回传）
│       ├── mcp_selftest.ms    #   Max 内 13 项自检
│       └── 3dsmax-mcp.ini     #   端口 / 语言 / autostart（安装时按参数重写）
├── scripts/
│   ├── install.py             # 安装 / 卸载 / 客户端注册（7 种客户端），字节级部署
│   ├── doctor.py              # 逐环诊断
│   ├── max_health.py          # 启动崩溃体检 / launch-watch 监视
│   ├── verify.py              # 静态完整性校验（括号、禁用构造、工具↔handler、速查表符号、文档统计对齐）
│   └── test_e2e.py            # 端到端 MCP 测试（stdio + HTTP + SSE + 自动语言）
├── test/
│   ├── static/                # 无 Max 静态门禁（全部可在 CI 跑）
│   │   ├── ms_check.py        #   MAXScript 编码 / 括号 / 方法链 / 未定义符号
│   │   ├── registration_sync_test.py # Python catalog ↔ MAXScript 注册 ↔ 部署树漂移
│   │   ├── catalog_contract_test.py  # Python 层契约（第六关：schema/preset/强转/门禁）
│   │   ├── doc_alignment_audit.py    # 文档统计 ↔ 代码真相对齐审计（verify.py 调用）
│   │   ├── offline_lint_helper.py    # 源码离线 lint + 工具定义审计（第七关）
│   │   └── mock_bridge.py     #   无 Max 的 TCP 模拟桥接
│   ├── live/                  # 需要真实 Max 桥接监听（127.0.0.1:8765）
│   │   ├── bridge_contract_test.py / bridge_pipeline_test.py / bridge_restart_test.py
│   │   ├── modeling_ext_test.py      # 建模扩展实机回归（6+6 组）
│   │   ├── live_matrix.py            # catalog 驱动的活体验证矩阵 runner
│   │   └── live_cases/        #   矩阵用例（5 个 JSON，43 例）
│   ├── diagnostics/           # 一次性探针（dump / TCP / batch / 窗口等）
│   └── logs/                  # 证据与日志，按日期归档（gitignored）
├── docs/
│   ├── BRIDGE_CONVENTIONS.md  # 桥接契约与编码规范
│   ├── LIVE_MATRIX.md         # 391 工具 × 实机状态矩阵（生成物）
│   ├── OFFLINE_LINT_GUIDE.md  # 离线门禁使用指南
│   ├── P0_ENV.md              # Max 启动崩溃调查环境记录
│   ├── TOOL_PROFILES_PROPOSAL.md
│   ├── CHANGELOG.md           # 变更日志
│   ├── graphite-capability-matrix.md
│   ├── reports/               # 时间点报告（DELIVERY / PLAN / OVERNIGHT）
│   └── tools.txt              # 全部工具名一览（生成物）
├── skills/3dsmax-mcp-dev/     # 给 AI 智能体用的开发 skill
│   └── SKILL.md
├── examples/
│   ├── prompts.md             # 16 条可直接使用的提示词
│   ├── mcp-config.samples.json
│   ├── python/direct_bridge.py
│   └── maxscript/listener_cheatsheet.ms
├── backup/                    # 历次改动前的快照（约定：改动前先备份到这里）
├── pyproject.toml
└── LICENSE
```

> **仓库即唯一真相**：`src/ms` 与 `src/python/maxmcp` 保存的就是在现场运行的字节
> （行结尾混合且都经过实战验证），`install.py` 字节级部署，
> `test/static/registration_sync_test.py` 会检查部署树是否与仓库漂移。改了已安装目录里的
> `.ms` 而不改仓库，等于没改。

---

## 开发

服务端**零第三方依赖**，直接跑：

```bash
git clone git@github.com:vino3dx/3dsmax-ai-mcp.git && cd 3dsmax-mcp

# 命令行
python -m maxmcp --help              # 全部参数
python -m maxmcp --list-tools        # 当前档位暴露的工具
python -m maxmcp --list-profiles     # 各档位规模

# 静态校验：括号平衡、禁用构造、工具↔handler 一一对应、模块加载列表、
#           Listener 速查表引用的桥接符号是否仍存在、README/docs 统计与代码对齐、
#           Python/MAXScript 源码与 catalog 工具定义的离线 lint（第七关）
python scripts/verify.py

# 服务端自检：catalog 完整性 + 双语描述 + 线编解码往返（含中文）
PYTHONPATH=src/python python -m maxmcp --selftest-python

# MAXScript 静态检查：编码（BOM/ANSI）、括号、方法链取成员、未定义符号
python test/static/ms_check.py src/ms

# 注册一致性：catalog ↔ mcpRegister ↔ 部署树（ENU/CHS）是否漂移
python test/static/registration_sync_test.py

# Python 层契约（第六关）：全部工具的 schema / preset / 必填校验 / 类型强转 /
#         危险工具门禁，MockBridge 顶替 Max，不连 8765
python test/static/catalog_contract_test.py            # 人读输出
python test/static/catalog_contract_test.py --list     # 只列用例清单，不启任何服务
python test/static/catalog_contract_test.py --json     # 机器可读报告

# 离线源码 lint（第七关）：Python 语法/编码/未定义名/硬编码路径 + MAXScript 编码/括号
#         + catalog 工具定义审计（双语描述/参数类型/默认值类型），纯文本分析无需 Max
python test/static/offline_lint_helper.py              # 人读输出
python test/static/offline_lint_helper.py --json       # 机器可读报告

# 写操作 → context 域契约：每个注册命令都必须声明 mutates（generated/mcp_domains.ms），
#         非只读工具声明缺失、只读工具声明非空、生成文件与 catalog 不一致都会失败
python test/static/tool_domain_contract_test.py        # 人读输出
python test/static/tool_domain_contract_test.py --json # 机器可读报告
python scripts/gen_tool_domains.py                     # 改了工具名/域规则后重新生成

# 实机验证矩阵（需要 Max 桥接在听）：--list 可无 Max 只看清单
python test/live/live_matrix.py --list

# 实机验证：写操作是否真的把域标脏、since 增量是否重发、失败是否不推进 revision
python test/live/write_tracking_test.py --port 8765            # 只打印计划
python test/live/write_tracking_test.py --port 8765 --yes      # 真机执行（可逆）

# 端到端：用 MockBridge 顶替 Max，验证 initialize / tools/list / tools/call /
#         中文往返 / 错误透传 / 语言切换 / 配置持久化
PYTHONPATH=src/python python scripts/test_e2e.py
```

### 修改 MAXScript 时的硬约束

MAXScript 在本机无法用批处理可靠验证（`3dsmaxbatch.exe` 在本环境不执行脚本），所以我们**主动禁用了一批无法静态验证的语法**，全部由 `verify.py` 强制：

- ❌ `struct`
- ❌ lambda / closure
- ❌ `fn = (...)` 形式的函数赋值
- ❌ 行尾反斜杠续行
- ❌ `.NET` 泛型集合
- ❌ 手动 `theHold`（仅 `mcp_core.ms` 例外，由它统一包裹）

新增工具时：

1. 在 `src/ms/mcp_*.ms` 里 `mcpRegister <命令名> <handler> undoable:<bool> label:<string>`
2. 在 `src/python/maxmcp/catalog/*.py` 里用 `tool(...)` 定义同名工具（中英双语描述 + schema）
3. 跑 `python scripts/verify.py` —— 它会检查两边**一一对应**

细节见 [`docs/BRIDGE_CONVENTIONS.md`](docs/BRIDGE_CONVENTIONS.md)。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
