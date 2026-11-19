# 3dsmax-mcp 项目全景与实机能力审计

| 项目   | 内容                                                                                                   |
| ---- | ---------------------------------------------------------------------------------------------------- |
| 审计日期 | 2026-11-19                                                                                           |
| 审计类型 | 只读审计（未修改任何源码、配置、文档；仅新增本文件）                                                                           |
| 仓库   | `D:\Workspace\Dev\3dsmax-mcp`                                                                        |
| HEAD | `2b8d43b T12: fix modifier reliability and update docs`（main，领先 `origin/main` 20 个提交，未 push；无任何 tag） |
| 审计视角 | 项目技术负责人 + 产品审计者                                                                                      |
| 目标版本 | v0.1.0 Public Beta                                                                                   |
| 实机环境 | Windows + 3ds Max 2022（`C:\Users\VINCE\AppData\Local\Autodesk\3dsMax\2022 - 64bit\ENU`），Python 3.13  |

**本次审计的可观测边界（必须先说清楚）**

- 审计开始时 **3ds Max 进程未运行**（`tasklist` 无 `3dsmax.exe`；`netstat` 无 8760–8779 监听）。本报告中的实机证据来自：① 2026-11-19 上午同一台机器、同一 Max 版本的验收轮（下文标 `A*`）；② 仓库内 `output/` 下的今日实机产物（标 `A`）；③ 源码注释中记录的历史实测值（标 `A-doc`）；④ 代码 / schema 静态分析（标 `C`）。
- 启动 Max 属于改变运行环境的动作，且本机有 `docs/P0_ENV.md` 记录的 `3dsmax.exe` 启动崩溃史（自 10-16 起 24 条 Event ID 1000），因此本次未启动 Max、未复跑任何会写场景的命令。
- **凡标记 `未测量` 的性能项，本报告不给数字。**

---

## 0. 结论速览

1. **它是什么**：一个把 3ds Max 变成"AI 可调用工具集"的桥。Python 侧对 AI 客户端讲 MCP，Max 侧用纯 MAXScript 在主线程执行，中间走本地 TCP。**389 个工具 / 9 个分类 / 358 个桥接命令 / 23 个 MAXScript 文件 / 17,390 行 MAXScript。**
2. **技术上最硬的部分确实做成了**：零第三方依赖的 MCP 实现（stdio + Streamable HTTP + legacy SSE）、纯 MAXScript 的 JSON 引擎、ANSI 字节级线编码、25 ms 主线程泵、`theHold` 事务包装、9 域增量场景上下文（revision + 脏域 + `since`）、base64 图像回灌成真实 MCP image block。这些不是 PPT，代码在、逻辑自洽、有针对性注释记录"为什么这么做"。
3. **但默认配置下，"AI 说做成了"不等于"真做成了"**：`runtime_verify` 默认关，且只有 `core` profile 会强制开启读回。默认 `full` profile 下 **303 个写工具没有任何场景读回校验**，成功与否完全依赖每个 handler 自己的返回值。今天验收轮已在真实 Max 上抓到 5 处 `P0`：修改器批量参数假成功、单参数不可用、`context_stats` 崩溃、`undo_last` 卡死 20+ 分钟。
4. **实机覆盖率是最大隐忧**：`docs/LIVE_MATRIX.md` 记录 **43 条实机用例覆盖 43 个工具**（42 通过 / 1 失败），即 384 个工具中 **341 个（89%）没有实机用例**；且该矩阵已过期（384 ≠ 389，生成于 2026-10-20）。更关键的是——**这 43 条用例绕过 Python 层，直接对桥发命令**（`test/live/live_matrix.py:215-262` 自己实现 preset 合并、不做 `_coerce`/`to_wire`/读回校验），所以它们验证的是 MAXScript 桥，不是"AI 用起来的那条端到端路径"。5 处 P0 中有 3 处正好落在 Python 层的强转语义上，因此对矩阵天然不可见。
5. **兼容性承诺超出证据**：README 声称 Max 2020–2027+。本机只有 2022 一个版本，全部实机证据只来自 2022；2020/2021/2023–2027 没有任何实机记录。
6. **安全模型是"信任边界在网络层，不在应用层"**：HTTP 端点做到了 fail-closed（非回环无 token 拒绝启动）、Host 头防 DNS rebinding、非回环不回 `*` CORS；但 TCP 桥（8765）**无任何认证**，本机任意进程可执行任意 MAXScript；`execute_maxscript` / `execute_python` / `files` 类工具是完整逃逸仓。
7. **安装器是脚本级可靠、体验级粗糙**：字节级部署 + 清单 + `doctor.py` 逐环诊断，本机复测仓库与安装目录 23/23 MAXScript、22/22 Python 全字节一致；但安装器不检测 Max 是否在跑、Python 探测只看 4 个固定路径（本机实测"未找到系统 Python"，回落到了 WorkBuddy 内置解释器）。
8. **文档体量大、漂移也实在**：README 859 行质量不低，但存量文中仍有 384/390/375 三种旧数字，`.github/workflows/release.yml` 的 `RELEASE_TITLE_PREFIX` 写成 `3dsmax-map`（应为 `max`），README 与 `pyproject.toml` 的 clone URL 指向 `3dsmax-ai-mcp` 而实际 remote 是 `3dsmax-mcp`。
9. **成熟度总评**：架构 良好、覆盖度 优秀、执行可靠性 较差、安全 一般、安装 一般、文档 良好、Client 兼容 未验证 → **v0.1.0 当前状态：不建议以"可靠的 Public Beta"发布**。
10. **最需要先修的 5 件事**（全部是"让 AI 的判断与现实一致"，不是加功能）：修改器参数三连（`mod_add` / `mod_set_params` / `mod_set_param`）、`context_stats` 空值兜底、`undo_last` 出主线程泵、默认读回校验 + 导出"陈旧文件误判成功"、文档与元数据一致性（含 release 标题前缀与 clone URL）。

### 直接回答：今天把它交给一个新用户，他能否独立安装、配置、连接，并可靠地让 AI Agent 操作 3ds Max？

**能装上、能连上、能跑通演示；但"可靠地操作"目前做不到。**

- **安装与连接这一段：能。** 前提是他有系统 Python 3.8+、知道装完要重启 Max。`python scripts/install.py --yes` → 重启 Max → Listener 出现横幅 → `python scripts/doctor.py` 七环全绿，这条路径本机可复现。失败时安装器会写 `loader.log` / `bridge.log`，`doctor.py` 能指出断在哪一环。
- **配置这一段：能，但要读 README。** 端口必须两边一致（安装器负责同步）、`--profile` 影响上下文体积、HTTP 模式需要单独起进程。
- **可靠操作这一段：不能。** 具体会撞上三类问题：① **假成功**（`mod_add` 传 `params` 时参数全丢却报 `applied`）；② **崩溃**（`context_stats` 在"曾构建过但当前缓存已失效"的域上索引 `undefined`）；③ **卡死**（`undo_last` 在 2300 对象场景里让 Max 主线程 20+ 分钟不响应）。而且这些问题 CI 全绿——静态门禁只校验"源码结构"和"schema 合法性"，**不校验 schema 声明的类型与 MAXScript handler 实际接收的形状是否一致**。
- 结论：**Demo 级可用，Beta 级不可承诺。** 修掉 5 处 P0（估计都是几行到几十行的局部改动）后，可靠性会从"会骗人"变为"会报错"，那才是 Public Beta 的底线。

---

## 1. 这个项目究竟是什么

### 1.1 用三句话解释

1. **MCP（Model Context Protocol）是 AI 客户端的"工具插座"标准**。客户端把一堆带 JSON Schema 的工具描述交给模型，模型决定调哪个、传什么参数，客户端负责把调用发出去。
2. **本项目就是那个插座背后的实现**：一个 Python 进程（零第三方依赖）向客户端声明 389 个工具；模型一调用，Python 就把请求经本地 TCP 转成一条 JSON 指令发给 3ds Max 里跑着的 MAXScript 桥。
3. **桥在 Max 的主线程上执行真正的 MAXScript**（等价于你在 Listener 里手敲），把结果序列化成 JSON 回传，Python 再包成 MCP 响应——如果结果里有图片，就变成真正的 `image` 内容块。

### 1.2 MCP 在这里扮演什么角色

| 角色           | 负责                                                                                         | 不负责                              |
| ------------ | ------------------------------------------------------------------------------------------ | -------------------------------- |
| MCP 规范       | 工具发现（`tools/list`）、调用（`tools/call`）、资源（`resources/read`）、传输（stdio / Streamable HTTP / SSE） | 不理解 3D、不校验业务语义                   |
| 本项目 Python 侧 | 把"MCP 调用"翻译成"Max 命令"；双语描述；参数纠正与强转；preset 注入；错误封装；图像块拆分                                     | 不触碰场景                            |
| MAXScript 桥  | 命令注册表、把命令派发到 handler、`theHold` 事务、脏域标记、场景读写                                                | 不懂 MCP，只认 `{id, method, params}` |

|                                                       |                                      |
| ----------------------------------------------------- | ------------------------------------ |
| 关键点：**模型能"看见"什么工具、工具描述怎么写，直接决定它会不会用错**。这也是本项目把描述写成"中文 | English"双语内联的原因——模型在任一语言提示下都能正确解析参数。 |

### 1.3 与普通 MAXScript 工具、Python 脚本的区别

| 维度               | 手写 MAXScript / Listener | 独立 Python 脚本（pymxs）                      | 本项目                                                                 |
| ---------------- | ----------------------- | ---------------------------------------- | ------------------------------------------------------------------- |
| 谁写代码             | 人，每次现写                  | 人，预先写好                                   | **AI 现场决定调用哪个工具、传什么参数**                                             |
| 需要人懂 MAXScript 吗 | 需要                      | 需要                                       | **不需要**（自然语言即可）                                                     |
| 主线程安全            | 天然安全                    | 需自己 `pymxs.runtime.execute` + 消息泵        | 桥用 WinForms Timer 在主线程泵，天然安全（`mcp_net.ms:5-11` 明确写了这个取舍）            |
| Python 版本依赖      | 无                       | 2020/2021 是 Python 2.7，2022+ 是 3.x，双兼容痛苦 | **零依赖**：Python 侧只用标准库，Max 侧纯 MAXScript                              |
| 覆盖面              | 无限                      | 受 pymxs 暴露面限制                            | 389 个工具 + `execute_maxscript` 兜底（等于无限）                              |
| 可撤销性             | 手动                      | 手动                                       | 每个写命令自动包在 `theHold` 里（`mcp_net.ms:182-201`）                         |
| 错误可见性            | Listener 里看             | 看 traceback                              | 结构化 `error{code,kind,tool,message,suggestion}`（`server.py:584-599`） |

### 1.4 为什么 AI 能通过它操作 3ds Max（三个必要条件）

1. **能力必须被"描述"出来**：389 个工具每个都有双语描述 + JSON Schema（`src/python/maxmcp/catalog/*.py`，5,897 行）。模型不需要知道 MAXScript，只需要知道"`mod_bend` 接受 `angle` 和 `direction`"。
2. **调用必须落到真实主线程**：Max 的 `scene` API 只能在 UI 线程碰。桥把 `TcpListener` 和 `WinForms.Timer(25ms)` 都建在主线程，每个请求都是在 tick 回调里同步执行的（`mcp_net.ms:482-506`）。
3. **结果必须可判断真假**：纯文本 `{"ok":true}` 无法证明"盒子真的建出来了"。项目对此有三层设计——最外层是 `vision_capture` 把像素直接回灌给模型（`server.py:95-154` + `mcp_vision.ms`），中间是 `runtime.py` 的前后 `scene_info` 快照校验，最内层是各 handler 的 `failures` 数组。**但第二层默认是关的**（见 §6.4、§7.1）。

### 1.5 适合什么工作（按"当前可依赖程度"排序）

| 场景               | 适配度 | 现在能做什么                                                                                               | 需要注意                                                                                          |
| ---------------- | --- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **场景整理与资产管理**    | 高   | 列对象、按类/前缀筛选、图层归并、隐藏冻结、贴图缺失检测与重链（`find_missing_assets` / `relink_assets`）                             | 依赖 `context_get` / `list_objects`（只读，风险低），是本项目最稳的一段                                           |
| **批量建模与程序化操作**   | 高   | 24 个 `create_*`（基础体与样条）、`array_objects` / `scatter_objects`、可编辑多边形全套（39 个 `poly_*`）、修改器栈             | 大批量时注意 `undo_last` 卡死问题；`create_*` 的 `success` 字段可信（带 per-property `failures`）                |
| **游戏资产制作**       | 中高  | `export_fbx`（含 UE5/Unity 预设）、`bake_normals/ao/lighting`、`uvw_unwrap`、`poly_optimize`、LOD 思路可行        | 导出用 `preset` 参数最稳；导出后建议 `file_exists` + `get_file_info` 复核（`_recover_written_file` 有陈旧文件误判风险） |
| **材质、灯光、渲染**     | 中   | 69 个 shading 工具（Arnold/V-Ray/Corona/FStorm 材质、贴图节点、物理相机、太阳光）、54 个 pipeline 工具（引擎切换、帧范围、渲染元素、单帧/序列/批） | 渲染类工具依赖第三方渲染器是否装；`vision_preview` 首帧可能数十秒（着色器编译），不是卡死                                         |
| **影视与动画制作**      | 中   | 59 个 animation 工具（关键帧、控制器、表达式、约束、骨骼、IK、蒙皮、Morpher）                                                   | `rig_skin_auto_weight` 等重操作未验证；`anim_bake` 在复杂场景上的表现未测量                                       |
| **广告与 CG 制作**    | 中   | 布光、相机、渲染、导出链路都有                                                                                      | 主要缺"迭代质量"证据：没有实机的"改 → 截图 → 判断 → 再改"闭环成功率数据                                                    |
| **自动化 Pipeline** | 中   | `--transport http` 可被云端 Agent 按 URL 调用；`execute_maxscript` / `execute_python` 可挂任意内部脚本               | 无认证的 TCP 桥 + 任意代码工具，**只适合单人受控机器**                                                             |
| **Rigging 精细活**  | 低   | 有骨骼链、镜像、IK、蒙皮权重工具                                                                                    | 没有实机证据；精细绑定对"错一点点就崩"的容忍度极低，不建议现在交给 AI 独立完成                                                    |

### 1.6 明确不适合 / 不能承诺的场景（不夸大）

- **不能用它做"无人值守的批量生产"**：`undo_last` 已实证会让主线程 20+ 分钟无响应；HTTP 端无并发模型（单一 socket + `RLock`，见 §7.2）。
- **不能承诺"所有工具都验证过"**：43/384 有实机用例（今为 43/389）。
- **不能承诺"任意 Max 版本表现一致"**：只有 2022 有实测；代码里用 `mcpMaxYear()` 做了版本分支，但分支从未在 2020/2021/2023+ 上跑过。
- **不能把它当安全沙箱**：README 自己写清了（`README.md:552-584`），`disabled_categories` / `--profile` 只影响"工具列表呈现"，传输层不做鉴权。
- **不能承诺"视觉闭环已成型"**：三个视觉工具确实返回真图片（`A`），但"模型看图后自我纠正并达标"的成功率没有任何测量记录。

---

## 2. 技术栈完整盘点

### 2.1 核心语言

| 语言                   | 文件数 |     行数 | 实际职责                                                                                                                                            | 证据                                                                  |
| -------------------- | --: | -----: | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| **Python 3**         |  22 |  9,154 | MCP 协议实现、工具目录（catalog）、参数纠正/强转、配置、i18n、HTTP/SSE、TCP 客户端、诊断/测试脚本                                                                                 | `src/python/maxmcp/**`，`pyproject.toml` `requires-python = ">=3.8"` |
| **MAXScript**        |  23 | 17,390 | 桥接（TCP 监听 + 主线程泵）、命令注册表、JSON 引擎、全部场景操作 handler、Max 内自检与面板                                                                                       | `src/ms/mcp_*.ms`，模块清单在 `mcp_bridge.ms:97-120`                      |
| Python（脚本层）          |   8 |  3,815 | 安装/卸载、客户端注册、诊断、静态校验、端到端测试、域表生成、健康监视                                                                                                             | `scripts/*.py`                                                      |
| Python（测试层）          |  58 |  8,592 | 静态门禁 4,642 行 + 实机测试 + 一次性探针                                                                                                                     | `test/**`                                                           |
| **没有** C++ / C# / JS |   — |      — | 无原生插件、无 npm 依赖、无编译步骤。C# 只在 MAXScript 里以 `dotNetClass` 形式借用 .NET BCL（`TcpListener`、`StreamWriter`、`System.Windows.Forms.Timer`、`System.IO.File`） | `mcp_net.ms:287-304`、`mcp_bridge.ms:47-95`                          |

### 2.2 框架与依赖

| 项目                 | 实际值                                                                                                                                                              | 证据                                                                            |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| MCP SDK            | **不使用官方 SDK**，自行实现 JSON-RPC 2.0 子集                                                                                                                               | `src/python/maxmcp/protocol.py`（155 行）                                        |
| 第三方运行时依赖           | **0 个**                                                                                                                                                          | `pyproject.toml` `dependencies = []`，注释写明"keeps the installer self contained" |
| 用到的标准库             | `json`, `socket`, `threading`, `queue`, `secrets`, `ipaddress`, `http.server`(`ThreadingHTTPServer`), `base64`, `difflib`, `pathlib`, `dataclasses`, `importlib` | 逐文件 import 头                                                                  |
| TCP 通信实现           | Python `socket`（客户端）+ MAXScript `System.Net.Sockets.TcpListener/NetworkStream`（服务端）                                                                              | `bridge.py:102-132`、`mcp_net.ms:563-617`                                      |
| JSON 序列化（Python）   | `json.dumps(..., ensure_ascii=True)`（线协议）/ `ensure_ascii=False`（MCP 响应）                                                                                          | `bridge.py:143` / `protocol.py:67`                                            |
| JSON 引擎（MAXScript） | 自研，816 行                                                                                                                                                         | `src/ms/mcp_json.ms`                                                          |
| 测试框架               | **不使用 pytest**，全部是可直接运行的脚本（`python test/static/xxx.py`，退出码语义）                                                                                                    | `test/static/*_test.py` 顶部都是 `Usage:` 注释                                      |
| 可选开发依赖             | `pytest>=7`, `ruff>=0.5`（`[project.optional-dependencies].dev`，实际门禁不依赖它们）                                                                                        | `pyproject.toml`                                                              |
| CI                 | GitHub Actions，仅发布用（打 tag 建 Release），**没有测试 workflow**                                                                                                           | `.github/workflows/release.yml`（未跟踪文件）                                        |

### 2.3 通信协议（四层）

```
①  MCP / JSON-RPC 2.0    客户端 ⇄ Python        三种传输：stdio | POST /mcp | GET /sse + POST /messages
②  TCP 长连接             Python  ⇄ Max          127.0.0.1:8765，换行分隔单行 JSON，ASCII-only
③  线编码 (wire codec)    Python  ⇄ Max          非 ASCII → 本地 ANSI 码页字节 → \u00XX 转义
④  MAXScript 派发         Max 内部               {id, method, params} → mcpRegistry → handler → mcpOkJson
```

- **stdio 怎么工作**：客户端拉起 `python -m maxmcp`，stdin 每行一条 JSON-RPC，stdout 只写协议（诊断全部走 stderr，`protocol.py:66-84`）。
- **HTTP / SSE 怎么工作**：`POST /mcp` 直接返回 JSON（也支持批量数组）；`GET /sse` 先回一条 `event: endpoint` 告知 `POST /messages?sessionId=…`，之后响应从 SSE 流推回（`http_transport.py:418-479`）。会话 30 分钟 TTL。
- **Python 与 Max 怎么通信**：`MaxBridge.call()` 把 `{id, method, params, lang}` 序列化后 `sendall`，然后**按 id 匹配**读回复（`bridge.py:172-192`）——这一步是为了防止"上一次调用的结果被当成这一次的结果"（历史 bug）。
- **TCP Bridge 的作用**：把 MCP 协议层与 Max 主线程解耦。Python 可以是 stdio 子进程、也可以是远程 HTTP 服务，只要它能连到 127.0.0.1:8765。
- **JSON 怎么传递**：Python 侧全 ASCII 转义发出；Max 侧逐字节 `ReadByte()` 拼字符串，遇到 `\n` 截断成一条（`mcp_net.ms:403-429`）。**不用 `StreamReader` 是刻意的**，注释记录了实测原因（会预读，导致第二个请求永远收不到）。


### 2.4 运行环境

| 项目             | 要求 / 实际                                                                                                         | 证据                                                                          |
| -------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| 操作系统           | Windows 10 / 11（依赖 MBCS 代码页、WinForms Timer、`%LOCALAPPDATA%`）                                                    | `wire.py`（`mbcs` 编解码）、`http_transport.py`、`install.py`                      |
| 3ds Max        | 声称 2020–2027+；**实测仅 2022**                                                                                      | `README.md:106`、`mcp_core.ms:310-317`                                       |
| Python         | ≥3.8；**本机实测安装器未找到系统 Python**（回落到 `C:\Users\VINCE\.workbuddy\binaries\python\versions\3.13.12\python.exe`）       | `python -B scripts/install.py --list` 输出                                    |
| MCP Client     | 不限（只要是 MCP 客户端）；安装器认识 7 种客户端配置路径                                                                                | `install.py` `CLIENTS` 表                                                    |
| MCP 协议版本       | 首选 `2025-06-18`，兼容 `2025-03-26`、`2024-11-05`                                                                    | `config.py:19-20`                                                           |
| 安装位置（Max 侧）    | `%LOCALAPPDATA%\Autodesk\3dsMax\<年份> - 64bit\<语言>\scripts\3dsmax-mcp\` + `scripts\startup\3dsmax-mcp-bridge.ms` | 本机实际存在：`...\2022 - 64bit\ENU\scripts\3dsmax-mcp\`（23 个 .ms + .ini）          |
| 安装位置（Python 侧） | `%LOCALAPPDATA%\3dsmax-mcp\maxmcp` + `install-manifest.json`                                                    | 本机实际存在                                                                      |
| 用户配置           | `%USERPROFILE%\.3dsmax-mcp\config.json`（可 `MAXMCP_HOME` 改）                                                      | 本机内容：`{"port":8765,"language":"auto","tool_profile":"full","port_scan":10}` |
| 端口             | 桥 8765（可 `+0..+9` 自动避让，两侧都扫 10 个）；HTTP 8770                                                                     | `config.py:174-175`、`mcp_bridge.ms:296-316`                                 |
| 超时             | 单次 120 s（`MAXMCP_TIMEOUT`）；连接 2 s；超时后会尝试自动关闭 Max 的模态对话框再等一轮                                                     | `config.py:33-34`、`bridge.py:194-235`                                       |

### 2.5 技术栈总表

| 层级          | 技术                                                   | 版本                     | 用途                         | 证据                               |
| ----------- | ---------------------------------------------------- | ---------------------- | -------------------------- | -------------------------------- |
| 客户端接入       | MCP over JSON-RPC 2.0                                | 协议 `2025-06-18`（兼容前两版） | 工具发现与调用                    | `config.py:19-20`、`protocol.py`  |
| 传输 A        | stdio（换行分隔）                                          | —                      | 本地客户端零配置                   | `protocol.py:37-84`              |
| 传输 B        | Streamable HTTP `POST /mcp`                          | —                      | 云端 Agent 按 URL 接入          | `http_transport.py:369-415`      |
| 传输 C        | legacy HTTP+SSE                                      | —                      | 老客户端 / 部分国产平台              | `http_transport.py:418-479`      |
| 服务端框架       | Python 标准库 `http.server.ThreadingHTTPServer`         | 3.8+                   | 无依赖 HTTP                   | `http_transport.py:32,128`       |
| 业务层         | 自研 `MaxMcpServer.dispatch`                           | —                      | 单一派发逻辑服务三种传输               | `server.py:242-296`              |
| 工具目录        | 自研 DSL（`tool/s/n/i/b/arr/num3`）                      | —                      | 389 工具 schema + 双语描述       | `catalog/schema.py`              |
| 参数层         | `_resolve_argument_names` + `_coerce` + preset 合并    | —                      | 容错（改拼写/别名/类型强转）            | `server.py:643-853`              |
| 运行封装        | `SceneRuntime`（前后快照 + 校验 + 失败归一）                     | —                      | 只在 `core` profile 或显式开启时生效 | `runtime.py`、`server.py:516-524` |
| i18n        | 双语描述内联 + Max UI 语言自动跟随                               | —                      | 中/英自动切换                    | `i18n.py`、`mcp_core.ms:146-214`  |
| 线编码         | ANSI 字节 → `\u00XX` 转义（Python `mbcs`）                 | —                      | 中文往返不失真                    | `wire.py`                        |
| 桥传输         | TCP + 换行 JSON（ASCII）                                 | —                      | Python ⇄ Max               | `bridge.py`、`mcp_net.ms`         |
| 桥调度         | WinForms `Timer` 25 ms 主线程泵 + `mcpPumpBusy` 重入闸      | .NET BCL               | 保证只在 UI 线程碰场景              | `mcp_net.ms:482-506`             |
| JSON（Max 侧） | 自研 MAXScript JSON                                    | 816 行                  | 无 Python 依赖的序列化            | `mcp_json.ms`                    |
| 事务          | `theHold.Begin/Accept/Cancel`                        | MAXScript              | 每个写命令可撤销                   | `mcp_core.ms:280-299`            |
| 场景上下文       | 9 域缓存 + 全局/域双 revision + `since` 增量                  | —                      | 避免每次全场景扫描                  | `mcp_context.ms`                 |
| 变更账本        | `callbacks.addScript` + `NodeEventCallback`（能力运行时探测） | —                      | 知道"场景变了"                   | `mcp_events.ms:22-44`            |
| 视觉          | `gw.getViewportDib()` → 缩放 → JPEG → base64           | GDI+                   | 让 AI 看见画面                  | `mcp_vision.ms`                  |
| Max 内 UI    | WinForms `TabControl` 七页只读面板                         | —                      | 人看的状态面板                    | `mcp_ui.ms`（680 行）               |
| 测试          | 自研脚本 + MockBridge                                    | —                      | 58 个测试文件                   | `test/**`                        |
| CI          | GitHub Actions（仅 Release）                            | —                      | 打 tag 发版                   | `.github/workflows/release.yml`  |

---

## 3. 完整架构与执行流程

### 3.1 真实架构（对任务书示意图的修正）

任务书给的链路是单向的 `Agent → Client → Server → TCP → Bridge → Handlers → Scene`。实际代码比这多三条回路，必须画出来才准确：

```
┌──────────────┐
│  AI Agent    │  自然语言 + 工具调用决策
└──────┬───────┘
       │ MCP / JSON-RPC 2.0
┌──────▼─────────────────────────────────────────────────────────────┐
│ MCP Client（Cursor / Claude / WorkBuddy / 云端平台…）               │
└──────┬─────────────────────────────────────────────────────────────┘
       │ ① stdio   ② POST /mcp   ③ GET /sse + POST /messages
┌──────▼─────────────────────────────────────────────────────────────┐
│ maxmcp 进程（Python 3, stdlib only）                                │
│  protocol.py   ← 传输无关的 JSON-RPC                                │
│  server.py     dispatch()  ←── 三种传输共用同一派发                 │
│    ├ catalog/  build_catalog() 389 tools（双语 + preset + mutates） │
│    ├ _build_payload(): preset 合并 → 参数改名/别名 → 类型强转        │
│    ├ runtime.py: SceneRuntime（core profile 才有前后读回）           │
│    ├ context.py: SceneContextCache（把增量回复缝成完整快照）         │
│    └ _split_images(): "_images" → MCP image content block           │
│  bridge.py     MaxBridge（单 socket + RLock，按 id 匹配回复）        │
└──────┬─────────────────────────────────────────────────────────────┘
       │ ④ TCP 127.0.0.1:8765，换行分隔 ASCII JSON（自动扫 8765..8774）
┌──────▼─────────────────────────────────────────────────────────────┐
│ 3ds Max 进程（纯 MAXScript，无插件无 pymx）                          │
│  mcp_bridge.ms  入口：加载 22 个模块 + 启动监听 + 写 bridge.json      │
│  mcp_net.ms     TcpListener + WinForms.Timer(25ms) 主线程泵          │
│                 mcpPumpBusy 重入闸 / mcpVisionBusy 视觉闸            │
│  mcp_core.ms    mcpRegistry（359 条 #(method,handler,undoable,label)）│
│                 mcpMsg 双语消息表 / mcpHold* / 节点解析              │
│  mcp_json.ms    自研 JSON 引擎（对象用 pair 数组 + marker Name 表示） │
│  mcp_domains.ms 每个命令写脏哪些 context 域（生成文件）              │
│  mcp_events.ms  callbacks + NodeEventCallback → 全局 revision        │
│  mcp_context.ms 9 域缓存（scene/selection/objects/materials/assets/  │
│                 animation/rigging/render/project）+ since 增量       │
│  16 个领域模块  objects/poly/modifiers/modeling_ext/shading/lights/  │
│                 animation/rigging/render/bake/export/scene/vision/   │
│                 system/ui/selftest                                   │
└──────┬─────────────────────────────────────────────────────────────┘
       │ ⑤ 主线程同步执行（等价于 Listener 里手敲）
┌──────▼─────────────────────────────────────────────────────────────┐
│ 3ds Max 场景（theHold 事务 / 脏域标记 / revision）                   │
└────────────────────────────────────────────────────────────────────┘

回路（任务书示意图没画的）：
  R1  context_get / context_stats / max://scene/context  ← AI 先问"场景里有什么"，减少盲猜
  R2  vision_capture / vision_views / vision_preview      ← 像素回到 AI，形成"改-看-改"闭环
  R3  client_ui / client_status                           ← Max 里的人能看到 AI 在干什么
```

### 3.2 十个关键问题的答案

| #  | 问题                                              | 答案（含代码位置）                                                                                                                                                                                                                                                                                                                                                                                 |
| -- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1  | Agent 如何发现工具                                    | 客户端发 `tools/list` → `MaxMcpServer.on_tools_list` → `catalog.to_mcp(language, bilingual, profile, disabled_categories)`（`server.py:370-378`）。数量随 `--profile` 变化：core 58 / pipeline 178 / animation 183 / lookdev 193 / modeling 207 / full 389。                                                                                                                                            |
| 2  | 工具 Schema 从哪注册                                  | `catalog/*.py` 用 `tool(...)` DSL 声明 → `build_catalog()` 合并 7 个模块（`catalog/__init__.py:20`）→ `Tool` dataclass 带 `schema / bridge / mutating / preset / mutates`。MAXScript 侧另有一份 `mcpRegister`，两边由 `test/static/registration_sync_test.py` + `verify.py` 校验一一对应。                                                                                                                            |
| 3  | 调用怎么进来                                          | `tools/call` → `on_tools_call`（`server.py:486-582`）。三种传输都调同一个 `dispatch()`，因此错误形状完全一致。                                                                                                                                                                                                                                                                                                    |
| 4  | 参数如何校验/转换/序列化                                   | `_build_payload`（`server.py:643-680`）：preset → `_resolve_argument_names`（精确 → 忽略大小写 → 别名组 → `difflib` 近似，`server.py:734-811`）→ 未知键不丢弃而是记 `parameterNotes` → 必填校验 → 逐项 `_coerce` → `to_wire`（ANSI 转义）。                                                                                                                                                                                     |
| 5  | Python 怎么发给 Max                                 | `MaxBridge.call`：`json.dumps(ensure_ascii=True)` + `\n` → `sendall`（`bridge.py:135-170`）。单 socket + `RLock`，失败重连一次。                                                                                                                                                                                                                                                                       |
| 6  | Max 怎么接收执行                                      | 25 ms tick → `mcpNetPump` → `DataAvailable` 逐字节读 → 按 `\n` 切行 → `mcpHandleLine` → `mcpDispatch` → `mcpFindEntry` → `handler params`（`mcp_net.ms:307-340, 482-506`）。                                                                                                                                                                                                                        |
| 7  | 结果怎么回 Python                                    | handler 返回 `mcpObj`（pair 数组 + marker）→ `mcpJsonStringify` → `{"id":…,"ok":true,"result":…}\n` → `StreamWriter.Write`（`mcp_net.ms:71-103, 287-304`）。异常统一转 `{"ok":false,"error":{"kind","message"}}`。                                                                                                                                                                                       |
| 8  | Python 怎么转 MCP 响应                               | `from_wire` 解转义 → `_apply_side_effects`（语言持久化 / `bridge_restart` 断连 / `context_get` 喂缓存）→ 生成 `operation_id` → `_split_images` 拆图 → 文本块 `json.dumps(indent=2)` → `clamp_text(200000)` → `make_result`（`server.py:556-582`）。                                                                                                                                                                |
| 9  | 错误/超时/异常如何处理                                    | 五类：`BridgeNotRunning` / `BridgeTimeout` / `BridgeProtocolError` / `BridgeCommandError` / Python 侧 `ValueError`。超时时会尝试关闭 Max 的模态框（`_dismiss_blocking_dialogs`，`bridge.py:25-38, 194-235`）；`bridge_restart` 断连被特判为成功（`server.py:528-539`）；导出类工具"文件已落盘"可被认成成功（`_recover_written_file`，`server.py:611-641`——**这条有副作用，见 §7.2**）。                                                               |
| 10 | Context / Event / Revision / Dirty Domain 各解决什么 | **Event**：知道"场景变了"（`callbacks.addScript` + `NodeEventCallback`，能力在启动时探测并公布，`mcp_events.ms:22-44`）。**Revision**：全局计数器，每次写 +1，作为 `since` 的坐标系。**Dirty Domain**：`mcp_domains.ms` 声明每个命令写脏哪些域（389 条工具 / 359 条命令），避免"改材质却让 render 域失效"。**Context**：9 个域的**有界摘要**缓存，按域 revision 失效，`since` 只回增量；每段带 `source/valid/supported/stale/buildMs`，读失败报 `valid:false` 而不是编一个 0（`mcp_context.ms:27-45`）。 |

### 3.3 完整案例：`create_box` 从注册到场景

|  步 | 位置                                    | 发生了什么                                                                                                                                                           |
| -: | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `catalog/objects.py`（`create_box` 定义） | `tool("create_box","objects",…, props={name,position,length,width,height,…}, preset={"class":"Box"})`，`mutating=True`，`mutates=("scene","objects","selection")` |
|  2 | `server.py:370`                       | `tools/list` 把它连同其余 388 个工具交给客户端（full profile）                                                                                                                  |
|  3 | 模型决定                                  | 参数例如 `{"length":10,"width":10,"height":10,"name":"Box_A"}`                                                                                                      |
|  4 | `server.py:643`                       | `_build_payload`：先铺 `preset{"class":"Box"}`，再合并调用参数；`class` 是隐藏的关键参数——**AI 不需要知道它**                                                                             |
|  5 | `server.py:758`                       | 参数名解析：`length` 精确命中；若模型写 `len`/`Length` 也能纠正，并在结果里留 `parameterNotes`                                                                                            |
|  6 | `server.py:814`                       | `_coerce`：`length` 声明 `number` → `10` 变 `10.0`                                                                                                                  |
|  7 | `wire.py`                             | 全字段 ANSI 转义，`ensure_ascii=True`                                                                                                                                 |
|  8 | `server.py:516`                       | `runtime_enabled = config.runtime_verify or profile=="core"` → 默认 `full` 下为 **False**，直接 `bridge.call`（不做前后快照）                                                  |
|  9 | `bridge.py:143`                       | 发出 `{"id":7,"method":"create_box","params":{…},"lang":"zh"}\n"`                                                                                                 |
| 10 | `mcp_net.ms:403`                      | 下一个 25 ms tick 读到字节，切成一行，进 `mcpHandleLine`                                                                                                                      |
| 11 | `mcp_net.ms:156`                      | `mcpDispatch`：查到 `#("create_box", mcpH_create_primitive, true, "Create Box")` → `mcpHoldBegin()`                                                                |
| 12 | `mcp_objects.ms:44`                   | `mcpH_create_primitive`：`execute "Box()"` → 设 name/position/尺寸（`mcpNum` 逐项 `setProperty`）→ `mcpRedraw()`；返回 `success/object/failures`                           |
| 13 | `mcp_net.ms:194`                      | 成功 → `mcpHoldAccept "Create Box"`（变成一步可撤销操作）                                                                                                                    |
| 14 | `mcp_net.ms:136`                      | `mcpDispatchNotify`：查 `mcp_domains.ms:113` → `scene,objects,selection` → `mcpEvAfterWrite` → revision +1，三域标脏                                                   |
| 15 | `mcp_net.ms:88`                       | 组 `{"id":7,"ok":true,"result":{…"object":{name,handle,class,vertexCount…}}}`                                                                                    |
| 16 | `bridge.py:255`                       | `_unpack` 判 `ok` → `from_wire`                                                                                                                                  |
| 17 | `server.py:574`                       | 无 `_images` → 只有一个文本块；`clamp_text` 截断保护                                                                                                                         |
| 18 | 客户端                                   | 模型收到 JSON：对象名、句柄、类名、顶点/面数 → 可以据此继续（例如 `convert_to_editable_poly`）                                                                                               |


**这条链路的可信度**：`create_*` 是少数"返回值本身就可信"的工具——它返回真实 `mcpNodeInfo`（含 `vertexCount`/`faceCount`）和 per-property `failures` 数组，属性设失败会进 `failures` 并让 `success=false`（`mcp_objects.ms:54-91`）。**同样是"设置属性"，`mod_set_param` 没有这层保护**（见 §7.1）。

### 3.4 一条失败路径的对照（说明"为什么有的工具会骗人"）

```
mod_set_params  →  catalog 声明 params: array
                →  server._coerce(dict) → [ {...} ]        ← 类型被包装
                →  mcp_json 还原成 Array（最后一个元素不是 marker Name）
                →  mcpH_mod_set_params: if not (mcpIsObj paramsObj) → mcpFail err.bad_value
                →  结果：工具永远不可用（但至少是"诚实地报错"）

mod_add         →  同上，params 变成 [ {...} ]
                →  mcpH_mod_add: for e in (mcpPairs explicit) do …   ← mcpPairs 对非对象返回 #()
                →  循环 0 次 → extra 为空 → 添加修改器成功
                →  mcpApplyModParams 返回 #(#(), #(), #())，**返回值被丢弃**（mcp_modifiers.ms:136）
                →  结果：参数一个没设，工具报 applied + msg.ok   ← 假成功
```

---

## 4. 工具能力盘点

> 数字全部来自实际运行 `python -m maxmcp --selftest-python` / `--list-profiles`，不取 README。

### 4.1 数字

| 指标                  |                                                                             数值 | 证据                                                       |
| ------------------- | -----------------------------------------------------------------------------: | -------------------------------------------------------- |
| MCP 工具总数            |                                                                        **389** | `--selftest-python`：`catalog: 389 tools in 9 categories` |
| 分类数                 |                                                                              9 | 同上                                                       |
| 桥接命令（`mcpRegister`） |                                                                        **359** | 源码正则统计；`bridge_stop` 注册但不暴露（`server.py:528-534` 注释）      |
| 去重后的桥接方法            |                                                                            358 | 389 工具中有 31 个是 preset 复用                                 |
| MAXScript 模块        |                                                           23 个文件（入口 1 + 22 模块） | `mcp_bridge.ms:97-120`                                   |
| Python 模块           |                                                         22 个文件（含 catalog 10 个） | `find src/python -name '*.py'`                           |
| 写工具 / 只读工具          |                                                                   **303 / 86** | 按 `Tool.mutating` 统计                                     |
| 各 profile           | core 58 / pipeline 178 / animation 183 / lookdev 193 / modeling 207 / full 389 | `--list-profiles`                                        |
| 全量 schema 体积（双语）    |                                                                  ≈ 300 KB JSON | 实测 `len(json.dumps(...))`                                |

### 4.2 Profile 与上下文成本

| Profile     | 工具数 | 说明                                                          |
| ----------- | --: | ----------------------------------------------------------- |
| `core`      |  58 | 显式白名单（`schema.py:139-156`）。**唯一默认开启 Scene Runtime 读回校验的档位** |
| `modeling`  | 207 | core 分类 + modeling                                          |
| `lookdev`   | 193 | core 分类 + shading                                           |
| `animation` | 183 | core 分类 + animation                                         |
| `pipeline`  | 178 | core 分类 + pipeline                                          |
| `full`      | 389 | 默认值                                                         |

> 389 个工具的双语描述约 300 KB，直接全量进上下文对模型是明显负担。README 建议按需裁剪，这点是对的；但**默认仍是 `full`**，而 `full` 恰好不开启读回校验——默认值把"能力最大"和"校验最少"绑在了一起。

### 4.3 分类明细

> 「实机证据」列：`A` = 真实 Max 有执行结果；`B` = 自动化测试（Mock / 静态）；`C` = 仅代码；`D` = 仅文档。下文括号里的"实机用例 N"指 `docs/LIVE_MATRIX.md` 的 43 条 case 分布，**它们直连桥、不经 Python 层**（详见 §7.3 N-15），因此标 A 时请理解为"桥的这条命令在真实 Max 上成立"。

#### system（32 个｜实机用例 3）

- **代表工具**：`bridge_status`、`bridge_capabilities`、`bridge_selftest`（Max 内 13 项自检）、`execute_maxscript`、`execute_python`、`undo_last`/`redo_last`/`begin_undo`/`end_undo`/`cancel_undo`、`hold_scene`/`fetch_scene`/`release_scene`、`set_units`、`get_class_properties`
- **解决什么**：连接自检、版本能力探测、任意脚本兜底、撤销事务、单位/时间配置、类内省
- **输入/输出**：`execute_maxscript{code, asOneUndo?, label?}` → `{result, resultText, message}`；`bridge_selftest{echoText?}` → `{ok, failures, checks[13], maxYear, language, port}`
- **实机证据**：`bridge_status`/`bridge_selftest`/`get_max_version` = A（3 条 case 全通过）；`execute_maxscript` = A（多次实机使用）
- **已知限制**：`undo_last` 会让主线程长时间阻塞（A*，见 §6.5）；`execute_python` 依赖 Max 自带 Python（2020 只有 2.7）

#### scene（17 个｜实机用例 2）

- **代表工具**：`scene_info`、`scene_statistics`、`scene_new`/`reset`/`open`/`save`/`save_as`/`merge`、`create_layer`/`assign_to_layer`、`find_missing_assets`/`relink_assets`
- **解决什么**：场景生命周期、图层管理、贴图丢失修复
- **输入/输出**：多数无参或仅 `path`；返回 `objectCount`、`selectionCount`、`currentFrame`、`modified` 等
- **实机证据**：2 条 case A；`scene_statistics` 曾把 65 个对象全归为 `other`（已修，`mcpCtxSuperKind`）
- **已知限制**：`scene_open`/`scene_save_as` 被注册成 `undoable:true`（会包 `theHold`），语义上"打开文件可否撤销"未验证

#### files（8 个｜实机用例 0）

- **代表工具**：`read_text_file`、`write_text_file`、`list_directory`、`copy_file`、`delete_file`、`make_directory`、`file_exists`、`get_file_info`
- **解决什么**：给 AI 一个受控的本地文件读写面（日志、配置、导出清单）
- **已知限制**：**路径无沙箱**（README 已声明），`delete_file` 是真删除

#### objects（61 个｜实机用例 15，全部通过）

- **代表工具**：`create_box/sphere/cylinder/cone/torus/teapot/plane/tube/pyramid/geosphere/line/rectangle/circle`…（24 个 `create_*` = 23 种具体形状 + 1 个通用 `create_primitive`）、`transform_object`、`clone_objects`、`array_objects`、`scatter_objects`、`boolean_operation`/`proboolean`、`select_objects`/`select_by_superclass`、`group_objects`/`attach_objects`、`set_pivot`、`snap_objects_to_grid`
- **解决什么**：建模的第一层——把东西摆出来、选中、成组、复制
- **输入/输出**：`create_*` 共用一套 24 个几何/参数属性（含大量与具体体无关的项，如 box 也有 `radius1`）；返回真实 `mcpNodeInfo` + `failures`
- **实机证据**：A（15 条 case 全通过）
- **已知限制**：`create_box` 这类工具的 schema 是"多类共用平铺参数"，模型容易传无关参数（无害但浪费 token）；`create_*` 的 `additionalProperties:false` 与实际存在的 `setName` 等别名并存，容易困惑

#### modeling（83 个｜实机用例 15，14 通过 1 失败）

- **代表工具**：`convert_to_editable_poly`、`poly_*` 全套 39 个（extrude/bevel/inset/chamfer/bridge/cap/weld/subdivide/loop/ring/triangulate/quadify/relax/optimize…）、`mod_add` + 22 个具名修改器（`mod_bend`/`mod_turbosmooth`/`mod_symmetry`/`mod_ffd_*`…）、`mod_set_param(s)`、`mod_reorder`、`collapse_stack`、`model_loft`/`model_sweep`/`model_lathe`
- **解决什么**：真正的建模核心——拓扑编辑 + 非破坏性修改器栈
- **输入/输出**：`poly_*` 以 `objects`/面索引起手，返回统计与 `failures`；`mod_*` 返回 `applied/rejected/failures/partial`
- **实机证据**：14 条 A；`poly_triangulate` 失败（`poly_get_stats: 'objects.0.faces' = 6, want 12`，`docs/LIVE_MATRIX.md:64`）
- **已知限制**：**`params` 相关的 3 个 P0 全部落在这个分类**（`mod_add`/`mod_set_params`/`mod_set_param`）

#### shading（69 个｜实机用例 8，全通过）

- **代表工具**：`mat_create_standard/physical/arnold/vray/corona/fstorm/generic/multi_sub/blend/shellac`、`mat_assign`、`mat_set_diffuse/pbr/emission/opacity/specular/property`、`map_create_bitmap/checker/noise/normal/falloff/gradient*`、`uvw_map`/`uvw_unwrap`/`uvw_quick_peel`、`light_create_*`（6）、`cam_create*`、`env_set_*`
- **解决什么**：看图前先把材质、灯光、相机、环境配好
- **输入/输出**：`mat_set_property{object?, material, property, value}` 有 **string→float/bool/Point3 的显式转换**（`mcp_scene.ms:1131-1180`），这是同类工具的正确范式
- **实机证据**：A（8 条全通过）
- **已知限制**：Arnold/V-Ray/Corona/FStorm 材质的创建需要对应渲染器已安装，否则 `err.class_missing`（会诚实报错）

#### animation（59 个｜实机用例 0）

- **代表工具**：`anim_set_key`/`anim_set_keys`、`anim_bake`/`anim_bake_range`、`anim_set_controller`、`ctrl_assign_expression`/`ctrl_wire`、`constraint_*`（9）、`rig_create_bone_chain`、`rig_skin_add`/`rig_skin_auto_weight`、`rig_ik_enable`/`rig_set_ik_chain`、`rig_morpher_*`
- **解决什么**：动画与绑定的全流程
- **实机证据**：**0 条 live case**，全部为 C/D
- **已知限制**：这是覆盖"看起来最全、证据最少"的分类；`rig_skin_auto_weight`、`rig_ik_*` 在真实角色上的表现完全未知

#### pipeline（54 个｜实机用例 0）

- **代表工具**：`render_still`/`render_frames`/`render_animation`/`render_batch`、`render_set_engine/resolution/quality/frame_range/output`、`render_element_*`、`bake_normals/ao/lighting/texture`、`export_fbx/obj/gltf/usd/abc/stl/3ds` + `export_engine_preset`、`import_*`、**`viewport_capture`/`viewport_capture_all`/`vision_capture`/`vision_views`/`vision_preview`**
- **解决什么**：出图、出资产、给 AI 眼睛
- **输入/输出**：`vision_capture{max_edge,format,redraw,path}` → 文本（width/height/mime/bytes）+ **1 个 `image` 内容块**（`mcp_vision.ms:191-198` + `server.py:95-154`）
- **实机证据**：视觉三工具 = **A（2026-11-19 实测返回真图，画面内容经目视确认）**；渲染/烘焙/导出 = 0 条 live case（`_recover_written_file` 的存在说明导出路径曾出问题，但修复本身无 case）
- **已知限制**：`max_edge` 硬上限 2048（视觉）/1600（渲染）；`vision_preview` 首帧可能数十秒；渲染结果依赖当前渲染器

#### context（6 个｜实机用例 0，但有专项实测记录）

- **代表工具**：`context_get{sections,since,detail}`、`context_refresh`、`context_stats`、`context_events`、`client_ui`、`client_status`
- **解决什么**：让 AI"先看一眼场景"而不是盲猜；`since` 增量避免每次全量
- **输入/输出**：9 域摘要，每段带 `revision/changedAt/sentAt/valid/supported/stale/buildMs/updatedAt`
- **实机证据**：A-doc（`mcp_events.ms:22-44` 与 `CHANGELOG` 记录 2022 实测：20/55 个通知可用、`NodeEventCallback` 必须两参、`callbacks` id 必须是 Name；`context_refresh` 9 域 4 对象场景 2 ms）；**`context_stats` 当前会崩溃（A*，见 §7.1）**

#### 通用执行入口 vs 专用工具

| 工具                                             | 与专用工具的区别                                            | 权限               | 风险                                  |
| ---------------------------------------------- | --------------------------------------------------- | ---------------- | ----------------------------------- |
| `execute_maxscript`                            | 一条字符串换无限能力。专用工具是"约定形状的安全通道"，它是"后门"                  | 完整场景 + 文件系统 + 配置 | 可绕过一切前置校验；`asOneUndo` 只影响撤销粒度，不影响能力 |
| `execute_python`                               | 经 Max 内置 Python 执行（写临时文件 + 驱动脚本捕获 stdout/traceback） | 本机 Python 能碰的一切  | 同上；2020 只有 Python 2.7，会明确报"不可用"     |
| `hold_scene` / `fetch_scene` / `release_scene` | 整场景快照（`holdMaxFile`），等价于 Ctrl+H                     | 极高（大场景吃内存/磁盘）    | 与 `theHold` 是两套机制，混用语义未验证           |
| `files` 类                                      | 直接操作磁盘                                              | 本机任意路径           | 无白名单，`delete_file` 不可恢复             |

### 4.4 覆盖度的真实形状

- 389 个工具叠在 **358 个桥接命令**上，其中 4 个命令承载 31 个工具：`mod_add`（23）、`light_create`（6）、`mat_create_guarded`（4）、`mod_collapse`（2）。**这意味着一个 handler 的缺陷会同时污染 23 个工具名**——`mod_add` 的 `params` P0 正是如此。
- 分类数量与实机证据严重不匹配：objects/modeling/shading 有 38 条 case，animation/pipeline/context/files 合计 **0 条**。

---

## 5. 用户实际使用流程

### 5.1 十个步骤（含真实命令）

|  # | 步骤              | 真实操作                                                                                                                        | 判定标准                                                                |
| -: | --------------- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
|  1 | 准备              | Windows 10/11 + 3ds Max 2020+ + Python 3.8+（服务端零依赖，但客户端要能拉起 `python`）                                                       | `python --version` 有输出                                              |
|  2 | 安装桥 + 服务端 + 客户端 | `cd 3dsmax-mcp && python scripts/install.py --yes`（或 `--client cursor workbuddy --yes`）                                     | 出现 `3ds Max installations found: N` 且每个都有 `scripts / startup` 两行    |
|  3 | 启动服务端           | stdio 模式不用手动起（客户端拉起）；HTTP 模式：`python -m maxmcp --transport http --http-port 8770`                                           | stderr 出现 `[3dsmax-mcp] ... ready - 389 tools`                      |
|  4 | 配置客户端           | 安装器自动写；手动则用 `python scripts/install.py --client print` 拿 JSON 贴进去                                                           | 客户端 MCP 面板显示 `3dsmax-mcp` 已连接                                       |
|  5 | 让 Agent 发现工具    | 客户端自动 `tools/list`；可让人先看：`python -m maxmcp --list-tools`                                                                    | 显示 389 个名字 + `profile 'full': 389 tools in 9 categories.`           |
|  6 | 确认连接            | 让 AI 调 `bridge_status`，或人跑 `python scripts/doctor.py`                                                                       | `[ok] Bridge listening on port 8765` + `Live handshake succeeded`   |
|  7 | 第一次场景查询         | AI 调 `scene_info` 或 `context_get`（推荐后者，一次拿到 9 域）                                                                            | 返回 `objectCount` 等真实字段，非 `null`                                     |
|  8 | 第一次对象创建         | AI 调 `create_box{length:10,width:10,height:10}`                                                                             | 返回 `success:true` + `object{name,handle,vertexCount:8,faceCount:6}` |
|  9 | 拿结果             | 同一响应里的 JSON；要看画面就 `vision_capture`                                                                                          | 收到 `image` 块（能显示图片的客户端直接看到画面）                                       |
| 10 | 排错              | `python scripts/doctor.py` → 看 `[warn]/[fail]` 落在哪一环；Max 内 `mcpSelfTest()`；日志 `%TEMP%\3dsmax-mcp\bridge.log` / `loader.log` | 每条检查都有 `ok/warn/fail` 明确结论                                          |

### 5.2 本机实测的安装检测输出（2026-11-19，`--list` 只读）

```
3ds Max installations found: 1
  - 2022 [ENU]
      scripts : C:\Users\VINCE\AppData\Local\Autodesk\3dsMax\2022 - 64bit\ENU\scripts
      startup : C:\Users\VINCE\AppData\Local\Autodesk\3dsMax\2022 - 64bit\ENU\scripts\startup

Python for the MCP server: (not found, will use C:\Users\VINCE\.workbuddy\binaries\python\versions\3.13.12\python.exe)
Server install dir       : C:\Users\VINCE\AppData\Local\3dsmax-mcp

MCP client configs:
  ...
  WorkBuddy        found        C:\Users\VINCE\.workbuddy\mcp.json
```


**两个必须知道的点**：① `(not found)` 说明本机没有装在 4 个探测路径里的系统 Python，安装器准备把 **WorkBuddy 内置解释器**写进客户端配置——换台机器或该目录被清理就失效；② `WorkBuddy found` 只是"配置文件存在"，本机 `~/.workbuddy/mcp.json` 里**并没有** `3dsmax-mcp` 条目（上次是用 `--client none` 装的），说明"检测到客户端"≠"已注册"。

### 5.3 三个使用案例

#### 案例 A：场景查询（只读，安全）

```
AI → context_get {sections: ["scene","objects","selection"], detail: "brief"}
     ↳ server: 无 preset，_coerce 把 sections 保持为 list
     ↳ bridge: {"method":"context_get","params":{"sections":[...]}}
     ↳ Max: mcpH_context_get → 按 sections 取缓存，必要时重建 → 9 域摘要（只回 3 个）
     ↳ 返回: {revision: 41, sections:{scene:{objectCount:2300,…}, objects:{…}, selection:{…}}}
```

- 为什么优先推荐它：一次往返拿到"场景规模 + 选择 + 对象统计"，比连调 `scene_info` + `list_objects` + `get_selection` 便宜得多（实测 `list_objects` 单次 62 ms 端到端，`context` 全量重建 7 ms 级）。
- 证据等级：**A**（`context_get` 在验收轮实机返回真实域数据）。

#### 案例 B：批量建模（写操作）

```
AI → create_box×N / array_objects / mod_turbosmooth{iterations:2}
```

- 调用链见 §3.3。批量场景的真实观感：`create_*` 每次一个往返（≈一笔 TCP + 一次 tick），`array_objects` 一次创建 N 个（Max 内部循环），后者明显更划算。
- 每个写命令都会被 `theHold` 包成**一步可撤销**操作——好处是 AI 的每步都能 Ctrl+Z，坏处是**撤销本身可能极慢**（§6.5）。
- 证据等级：**A**（`output/forest/cedar_hollow.max` 为今日实机构建产物；15 条 objects case 全通过）。

#### 案例 C：视觉反馈（只说明有证据支持的部分）

```
AI → vision_capture {max_edge: 640, format: "jpeg"}
     ↳ mcp_vision.ms: gw.getViewportDib() → 缩放 → JPEG → base64
     ↳ 返回 {count:1, width, height, mime, bytes, _images:[{label,data,mime}]}
     ↳ server._split_images → content[0]=text(元数据)  content[1]={type:"image", data, mimeType}
AI → 看图 → 决定下一步（例如"盒子翻面了，poly_flip_faces"）
```

- **有证据的**：三个视觉工具都能在真实 Max 上返回**真图片块**（今日实测，画面内容我目视确认：红球、树林 + 水池 + 地形，`output/forest/views/01_aerial_wide.png`）。
- **没有证据的**：模型"看图 → 判断 → 改正 → 再截图直到正确"这一整圈的**成功率**。没有任何测量记录，本报告不编造。
- 证据等级：工具本身 **A**；闭环效果 **未验证**。

---

## 6. 真实实机表现评估

### 6.1 证据等级约定（与任务书一致）

| 级         | 含义                        | 本报告中的来源                                      |
| --------- | ------------------------- | -------------------------------------------- |
| **A**     | 真实 Max 实机，有明确执行结果         | `output/` 今日产物、验收轮记录                         |
| **A***    | 真实 Max 实机，但发生在审计日早前、本次未复跑 | 2026-11-19 上午验收轮（同一机器 / Max 2022）            |
| **A-doc** | 源码注释或文档中记录的实机测量值          | `mcp_events.ms`、`mcp_context.ms`、`CHANGELOG` |
| **B**     | 自动化测试（Mock / 静态契约）        | `test/static/**`、`scripts/test_e2e.py`       |
| **C**     | 仅静态代码 / schema 分析         | 本次代码走读                                       |
| **D**     | 仅文档描述                     | README、旧报告                                   |

### 6.2 十二维评估

| 维度        | 结论         | 等级    | 依据                                                                                                            | 未覆盖                             |
| --------- | ---------- | ----- | ------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| **连接稳定性** | 好          | A*    | stdio 与 HTTP 两种客户端都能连；断线自动重连一次（`bridge.py:145-160`）；按 id 匹配回复，杜绝"串答案"                                         | 长时间（>数小时）连接存活未测                 |
| **通信可靠性** | 好          | A*+C  | 换行分帧 + 缓冲保留 + `mcpPumpBusy` 重入闸；历史 bug（丢尾巴、乱序、StreamReader 预读）都有对应修复与注释                                       | 高并发多客户端压测未做（本机单客户端）             |
| **执行可靠性** | **差**      | A*    | 5 处 P0：假成功 1 处、必失败 1 处、崩溃 1 处、卡死 1 处、参数不可用 1 处                                                                | 无回归用例覆盖这些边界                     |
| **返回真实性** | **差**      | A*+C  | 默认 `full` profile 无读回校验；`mod_add` 报 applied 而参数全丢；`_recover_written_file` 会把**先前就存在的旧文件**当成"刚写成功"             | 303 个写工具中只有少数自带 `failures` 字段   |
| **参数正确性** | 一般         | A*+C  | 有别名组 + `difflib` 近似 + 类型强转 + `parameterNotes`（很用心）；但"声明类型 ↔ handler 期望形状"无人校验，`params` 这类 object/array 混淆直接穿透 | 边界值（超大数组、极值、空串）无系统用例            |
| **批量能力**  | 一般         | A*    | `array_objects`/`scatter_objects`/`render_frames` 是"一次调用内部循环"，比逐个调用高效；`build_batch_result` 明确"部分成功不算整体成功"     | 千级批量的耗时/内存**未测量**               |
| **场景规模**  | **差**      | A*    | 2300 对象场景下 `undo_last` 20+ 分钟无响应（强杀进程）                                                                        | 只有 65 对象（A-doc）与 2300 对象（A*）两个点 |
| **执行速度**  | 一般（有少量真数据） | A-doc | 65 对象全量节点信息 7 ms（Max 内）；`list_objects` 端到端 62 ms；`context_refresh` 9 域 4 对象 2 ms；视觉 800px JPEG 每张 30–90 KB    | **FPS、内存占用、大场景 tick 延迟：未测量**    |
| **主线程阻塞** | **差**      | A*    | 设计上所有命令在 25 ms tick 里**同步**执行——渲染/烘焙/导出/undo 期间整个桥停摆，且 UI 无响应                                                 | 阻塞期间客户端的超时行为只做了定性观察             |
| **错误恢复**  | 一般         | A*+C  | 桥异常统一转 `ok:false` + `kind/message`；Python 侧分类建议；`bridge_restart` 断连特判为成功；超时会尝试关模态框                            | 崩溃后（Max 强杀）客户端能否自动恢复未测          |
| **视觉能力**  | **好**      | A     | 三工具返回真实 `image` 内容块，画面经目视确认；尺寸/格式/上限都有钳制；失败会返回 `image_errors` 并置 `isError`                                    | 无头/最小化视口下的失败路径未测                |
| **长时间运行** | 未验证        | —     | 无任何 soak/泄漏测试记录                                                                                               | 全部                              |

### 6.3 只列真实测量（不推测）

| 指标                    |                数值 | 场景           | 来源/等级                        |
| --------------------- | ----------------: | ------------ | ---------------------------- |
| catalog 构建 + 线编解码自检   | 全通过，389 工具 / 9 分类 | 无需 Max       | 本次实测（B）                      |
| 工具定义全量 JSON（双语）       |          ≈ 300 KB | full profile | 本次实测（C/B）                    |
| 全量节点信息构建              |              7 ms | 65 对象        | `mcp_context.ms:8-12`（A-doc） |
| `list_objects` 端到端    |             62 ms | 65 对象        | 同上（A-doc）                    |
| `context_refresh` 9 域 |              2 ms | 4 对象         | `CHANGELOG.md`（A-doc）        |
| 单张 800px JPEG base64  |          30–90 KB | 视口截图         | `mcp_vision.ms:37-42`（A-doc） |
| `undo_last` 阻塞        |       **> 20 分钟** | 2300 对象      | 验收轮（A*，进程被强杀）                |
| 桥命令数 / 工具数            |         359 / 389 | —            | 本次实测                         |

### 6.4 明确「未测量」的清单

- 帧率（FPS）、视口交互延迟；
- 3ds Max 进程内存占用及其随调用次数的增长；
- 1000+ 对象下的单次工具调用耗时分布（p50/p95）；
- 批量创建 1000 个对象的成功率与耗时；
- 渲染、烘焙、导出的耗时与成功率；
- 渲染/导出在高负载下的超时率；
- 连续运行数小时的连接存活与内存曲线；
- 多客户端并发（stdio + HTTP 同时）的行为；
- 2020 / 2021 / 2023–2027 版本上的任何行为。

> 这些数据一个都没有，所以本报告不给任何估计值。README 里的"建议 800px 截图"这类经验值有代码注释支撑，属于 A-doc；其余性能描述请按"未测"处理。

### 6.5 事故复盘：`undo_last` 为什么能卡 20 分钟

**事实（A*）**：在约 2300 对象的场景里调用 `undo_last`，Max 主线程 20+ 分钟无响应，最终强杀进程。

**机制（C，逐行可查）**：

1. `mcpH_undo_last`（`mcp_system.ms:342-356`）循环调用 `actionMan.executeAction 0 "40005"`（Edit → Undo 的 action id）。
2. 它跑在 `mcpOnTick`（`mcp_net.ms:498-506`）里，而 `mcpOnTick` 是 WinForms `Timer(25ms)` 的 Tick 回调——**在 UI 线程上执行**。
3. 撤销一个"包含 2300 个对象变更"的 hold 记录，Max 要重建整个对象图并刷新视口；这段时间 UI 线程被完全占用，**泵停止、所有后续请求排队、窗口不刷新**。
4. 该工具注册为 `undoable:false`（`mcp_system.ms:521`），所以不会额外嵌套一层 `theHold`——但这不改变"它在 UI 线程里同步跑"的事实。
5. 客户端看到的是"调用无响应"，`MAXMCP_TIMEOUT`（默认 120 s）先超时；而桥侧的 tick 仍卡在那一帧里，**后续所有工具调用都会失败**，直到撤销结束。

**为什么危险**：这不是"慢"，是**单点全阻塞**——一个调用能让整个桥在几分钟到几十分钟内完全不可用，且没有取消机制（没有 `cancel` 通路，`mcpPumpBusy` 也只在 tick 之间生效）。

**任务书要求"不要直接修改或设计新实现"，因此本报告只给约束，不给方案**：任何修复都必须满足"不在 25 ms tick 的同步栈里长时间占用 UI 线程"，并保留"AI 的一步操作可撤销"这一既有承诺。

---

## 7. 当前已知缺陷与风险

### 7.1 五处 P0（全部有代码定位；未修改）

#### P0-1 `mod_add` 的 `params` 假成功（会同时影响 23 个工具名）

| 项              | 内容                                                                                                                                                                                                                                                                                                                                    |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 现象             | `mod_add{modifier:"Bend", params:{angle:45}}` → 修改器加上了，`angle` 没设，返回 `applied:["Box001"]` + `msg.ok`                                                                                                                                                                                                                                  |
| 根因             | ① catalog 把 `params` 声明成 `array`（`catalog/modeling.py:676-677`）；② `_coerce` 对 array 收到 dict 时 `return [value]`（`server.py:837-852`）；③ MAXScript 侧 `mcpIsObj` 对"数组套对象"判 false（`mcp_json.ms:51-57`）；④ `mcpPairs` 因此返回 `#()`（`mcp_json.ms:60-66`）；⑤ `mcpH_mod_add` 把 `mcpApplyModParams` 的返回值**丢弃**（`mcp_modifiers.ms:136`），仍报 `applied` |
| 影响面            | `mod_add` + 22 个具名修改器（`mod_bend`/`mod_turbosmooth`/`mod_noise`…全部走 `mod_add`）。注意：**顶层平铺参数**（如 `mod_turbosmooth{iterations:2}`）是好的，只有用 `params:{...}` 这条路径会丢                                                                                                                                                                           |
| 证据             | 本次静态复现 `_coerce({"iterations":2}) → [{"iterations":2}]`（C）；验收轮实机观测（A*）                                                                                                                                                                                                                                                                |
| 最小修法方向（不建议现在动） | schema 改成 `object` 语义；`_coerce` 的 `object` 分支保留 dict；`mcpH_mod_add` 检查 `applied/rejected/failures` 并据实回报                                                                                                                                                                                                                              |

#### P0-2 `mod_set_params` 恒失败

| 项   | 内容                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------- |
| 现象  | 任何调用都返回 `err.bad_value: params`                                                                                           |
| 根因  | 同 P0-1 的 ①–③；`mcpH_mod_set_params` 有显式校验 `if not (mcpIsObj paramsObj) do mcpFail "err.bad_value"`（`mcp_modifiers.ms:311`） |
| 影响面 | 1 个工具，但它是"批量设置修改器参数"的唯一入口                                                                                                 |
| 性质  | **诚实失败**（不骗人），只是工具不可用                                                                                                     |

#### P0-3 `mod_set_param` 数值不可用

| 项   | 内容                                                                                                                                                                         |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 现象  | `mod_set_param{modifier:"Bend", param:"angle", value:45}` → 失败（`setProperty` 收到字符串 `"45"` 给 float 属性）                                                                      |
| 根因  | `value` 声明 `string`（`catalog/modeling.py:734-735`）→ `_coerce` 转 `"45"`（`server.py:833-836`）→ `mcpApplyModParams` 直接 `setProperty mod k v`，**无类型转换**（`mcp_modifiers.ms:92`） |
| 对照  | 同类工具 `mat_set_property` / `set_property_value` 有完整转换：读当前值类型 → 字符串转 float/bool/String/Point3（`mcp_scene.ms:1155-1180`）                                                      |
| 影响面 | 1 个工具 + 所有"用字符串传数值"的调用习惯                                                                                                                                                   |

#### P0-4 `context_stats` 崩溃

| 项   | 内容                                                                                                                                                                                                                           |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 现象  | 调用即报运行时错误（`cannot index undefined`），统计不可用                                                                                                                                                                                    |
| 根因  | `mcp_context.ms:1275-1278`：`if built do ( local w = entry[3] ... )`——`built=true`（曾构建过）但 `cached=false`（当前 revision 下没有缓存）时，`entry` 是 `undefined`，`entry[3]` 直接崩。兜底写在了下一行 `if w == undefined do w = anyEntry[3]`，但**崩在取值之前** |
| 影响面 | 1 个只读工具（诊断/面板用），但它恰好是"看上下文层状态"的唯一入口；`mcp_ui.ms` 的 Context 页也读这张表                                                                                                                                                             |
| 证据  | 验收轮实机崩溃（A*）；代码逐行确认（C）                                                                                                                                                                                                        |

#### P0-5 `undo_last` 卡死主线程

见 §6.5。证据 A*（2300 对象，>20 分钟，强杀）。`redo_last` 同构（`mcp_system.ms:358-372`），风险相同但未实测。

### 7.2 本次新发现的风险（未在任务书清单内）

| 编号   | 级别     | 问题                                                                                                                                                              | 位置                                                      | 后果                                                                          |
| ---- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------- |
| N-1  | **P1** | `_recover_written_file` 把**早已存在的旧文件**当成"刚写成功"：只检查 `is_file()` 和 `size>0`，不比对 mtime                                                                              | `server.py:611-641`                                     | 导出失败 + 目标路径有旧文件 → 工具报 `written:true` + 旧文件大小。**这是"返回真实性"的又一个漏洞**            |
| N-2  | **P1** | TCP 桥（8765）无任何认证，任何本机进程可连上执行任意 MAXScript                                                                                                                        | `mcp_net.ms:563-617`                                    | 本机恶意/误操作进程可完全控制 Max；`bridge.json` 还公开了端口与 pid                               |
| N-3  | **P1** | 默认 `full` profile + `runtime_verify=false` → 303 个写工具无读回                                                                                                        | `server.py:516-524`、`config.py:45`                      | "AI 说做成了"缺乏第二来源；README 的"每步可撤销"成立，但"每步可验证"不成立                               |
| N-4  | **P1** | HTTP token 支持 `?token=` 查询参数，且 legacy SSE 会把 token 拼进 `endpoint` 事件                                                                                             | `http_transport.py:278-279, 436-437`                    | token 会进浏览器历史、代理日志、Referer；暴露部署时降低令牌价值                                      |
| N-5  | **P1** | 安装器 Python 探测只看 4 类固定路径（Store/conda/pyenv/自定义路径全漏），回落 `sys.executable`                                                                                          | `install.py:159-178`；本机实测 `(not found)`                 | 客户端配置可能指向一个临时/内置解释器，日后失效；新用户最难自查的一类故障                                       |
| N-6  | **P1** | Release 标题前缀写成 `3dsmax-map`                                                                                                                                     | `.github/workflows/release.yml`（`RELEASE_TITLE_PREFIX`） | 一旦打 tag，Release 标题变成 `3dsmax-map-v0.1.0`                                    |
| N-7  | P2     | clone URL 与实际 remote 不一致：README/pyproject 指向 `3dsmax-ai-mcp`，remote 是 `3dsmax-mcp`                                                                              | `README.md:786`、`pyproject.toml` `[project.urls]`       | 新用户照 README 克隆可能 404                                                        |
| N-8  | P2     | `GET /health` 不做鉴权（在 `_authorized` 之前直接返回）                                                                                                                      | `http_transport.py:307-316`                             | 暴露部署时泄露服务名与请求计数（低危）                                                         |
| N-9  | P2     | 单 socket + 全局 `RLock`，所有调用串行；HTTP 多线程共享同一把锁                                                                                                                     | `bridge.py:77, 145`                                     | 多客户端/并发场景下排队放大；与 P0-5 叠加会长时间全阻塞                                             |
| N-10 | P2     | 文档数字漂移：`LIVE_MATRIX` 384/43（2026-10-20 生成）、`CHANGELOG` 写"384 → 390"、`OFFLINE_LINT_GUIDE` 384、`CORE_RUNTIME_AUDIT` 384、README 说"22 个模块"但实际部署 23 个文件              | 多处                                                      | 外人对"到底多少工具"没有单一可信答案（实际：**389**）                                             |
| N-11 | P2     | `mcp_vision.ms` 头部注释把 `_images` 描述成 pair 数组 `[label,data,mime]`，实际代码构造的是对象                                                                                      | `mcp_vision.ms:20-28` vs `:191-198`                     | 误导后续维护者（server 侧只接受 dict）                                                   |
| N-12 | P2     | 未跟踪文件：`.github/`（发布 workflow）与 `output/`（7.5 MB + 3.3 MB 场景 + 截图）都不在版本控制                                                                                        | `git status`                                            | 发版时 workflow 可能漏掉；`output/` 里有大二进制                                          |
| N-13 | P3     | `create_*` 的 schema 是"24 个创建工具共用 24 个属性"（`create_box` 也带 `radius1`/`turns` 等无关项）                                                                                | `catalog/objects.py`                                    | 模型容易传无关参数，浪费 token 且易困惑                                                     |
| N-14 | P3     | `scene_open` / `scene_save_as` 被标成 `undoable:true`，会包 `theHold`                                                                                                 | `mcp_scene.ms:1230-1232`                                | "打开文件"包在撤销事务里语义可疑，未验证                                                       |
| N-15 | **P1** | 43 条实机用例**绕过 Python 层**：`live_matrix.build_payload` 自行合并 preset，不执行 `_coerce` / `to_wire` / `runtime` / `_split_images`，直接 `client.call(tool.bridge_method, …)` | `test/live/live_matrix.py:215-224, 262`                 | 实机矩阵证明的是"桥能用"，不是"AI 走完整链路能用"。**P0-1 / P0-2 / P0-3 三个都落在被绕过的这一层**，所以矩阵里它们是绿的 |
| N-16 | P2     | 同因：`vision_*` 类工具无法被 live_matrix 覆盖（图像块由 Python 层生成），所以 pipeline 分类 0 条 case 并非偶然                                                                               | 同上                                                      | 视觉能力只有人工目视证据，没有可回归的自动化断言                                                    |


### 7.3 为什么 CI 全绿还是漏了这 5 条

任务书说"不要把静态测试通过当作实机能力已验证"。这次的具体证据是：

| 门禁                                          | 实际检查什么                                                        | 为什么漏                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/verify.py`                         | 括号平衡、禁用构造（`struct`/lambda/续行）、工具↔handler 一一对应、模块清单、速查表符号、文档统计 | 只比"名字对不对"，**不比"参数形状对不对"**                                                                                                                                                                                                                                                                                              |
| `test/static/ms_check.py`                   | 编码/BOM、括号、方法链取成员、未定义符号                                        | 编译期级别，不看运行时类型                                                                                                                                                                                                                                                                                                          |
| `test/static/catalog_contract_test.py`      | schema 合法性、preset 键、必填拒绝、类型强转                                 | 验证的是"`_coerce` 行为符合声明"，**声明本身错了就一起错**                                                                                                                                                                                                                                                                                  |
| `test/static/modifier_param_result_test.py` | 正则检查 `mcpApplyModParams` 是否分类、handler 是否统计                    | 只看源码**结构**，不看 `params` 的 schema 类型                                                                                                                                                                                                                                                                                     |
| `test/static/offline_lint_helper.py`        | 双语描述、参数类型合法性、默认值类型                                            | 只校验"类型名在 6 个合法值里"，不校验"是不是该类型"                                                                                                                                                                                                                                                                                          |
| `test/live/live_matrix.py` + 43 个 case      | 真实 Max 断言（**直接对桥发命令**）                                        | **结构上测不到 Python 层**：`live_matrix.build_payload`（`:215-224`）自己合并 preset、**不跑 `_coerce`/`to_wire`/`runtime`**，再 `client.call(tool.bridge_method, payload)` 直连 8765。`mod_set_param` 的 case 传的是整数 `2`（`03_modeling.json:461`），绕过 Python 后才对；`mod_add` 的 case 根本不传 `params`（`03_modeling.json:391-398`）→ 所以两个 P0 在矩阵里都是"通过" |

**结论**：这是一套"结构正确性"门禁，缺少"语义一致性"门禁——具体缺两条：

1. **catalog 声明的参数类型，必须与 MAXScript handler 实际消费该参数的方式一致**（`params` 是 object 还是 array、`value` 是 string 还是 number）。这条没有对应测试，所以 P0-1/2/3 全部逃过所有关卡。
2. **实机用例必须走真实 MCP 入口**。当前 43 条 case 直连桥、自己合并 preset，等于把"Python 层"从实机验证里删掉了；而 Python 层恰恰是 `_coerce`、preset、`to_wire`、读回校验、图像块所在的地方。补一条"经 `MaxMcpServer.dispatch` 的实机冒烟"比再加 100 条桥级 case 更有价值。

---

## 8. 项目成熟度评估

### 8.1 十项评级

|  # | 维度                    | 评级      | 依据                                                                                                                                               |
| -: | --------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
|  1 | **架构成熟度**             | **良好**  | 三层职责清晰（协议 / 翻译 / 执行），三种传输共用一套派发，无循环依赖；`context` / `events` / `runtime` 三层抽象各自解决一个真问题。扣分项：`runtime.py` 与各 handler 的 `failures` 是两套并行的失败语义，默认只生效一套 |
|  2 | **技术实现成熟度**           | **良好**  | 自研 JSON 引擎、ANSI 线编码、主线程泵、重入闸、`theHold` 事务都是硬骨头且做对了，注释记录了"为什么"（多处有实测依据）。扣分项：类型契约在 Python↔MAXScript 边界上没有机器校验                                      |
|  3 | **工具覆盖度**             | **优秀**  | 389 工具 / 9 分类，从基础体到蒙皮到烘焙到引擎预设，覆盖面在同类项目里属第一梯队；`execute_maxscript` 兜底保证"没有做不了的"                                                                    |
|  4 | **执行可靠性**             | **较差**  | 5 处 P0：1 假成功、1 必失败、1 崩溃、1 卡死、1 参数不可用；默认无读回；89% 工具无实机用例                                                                                           |
|  5 | **性能与扩展性**            | **一般**  | 有 3 个可信的小场景数据点（7 ms / 62 ms / 2 ms）；大场景有 2300 对象的失败样本；单 socket 串行模型没有扩展空间；FPS/内存全未测                                                              |
|  6 | **安全性**               | **一般**  | HTTP fail-closed、Host 校验、CORS 收紧、`compare_digest` 都是加分项；但 TCP 桥无认证、任意代码工具无沙箱、token 可走 query、`/health` 免鉴权                                        |
|  7 | **安装体验**              | **一般**  | 一键脚本 + 字节级部署 + 清单 + `doctor.py` 七环诊断，工程化程度高于平均；但需重启 Max、Python 探测窄、不检测 Max 进程、`WorkBuddy found ≠ 已注册` 这类误导                                       |
|  8 | **文档完整度**             | **良好**  | README 859 行（含安全边界、故障排查、视觉闭环、返回形状），`BRIDGE_CONVENTIONS.md` 257 行写清桥接契约，CHANGELOG 807 行按 Keep a Changelog。扣分项：存量数字漂移 + clone URL 错                |
|  9 | **MCP Client 兼容性**    | **未验证** | 协议实现覆盖 3 个版本、3 种传输，HTTP/SSE 用 HTTP 客户端实测过；**但没有一个真实 GUI 客户端（Cursor / Claude Desktop / WorkBuddy）的端到端连接记录**                                       |
| 10 | **Public Beta 发布准备度** | **较差**  | 5 个 P0 未修 + 实机覆盖 11% + 版本兼容只有 1 个版本有证据 + relelase 配置有笔误                                                                                          |

### 8.2 四个必答问题

**最有价值的能力是什么？**

> **"让 AI 在一次对话里走完 建模 → 材质 → 灯光 → 渲染 → 截图 → 自查 → 修改"这条链路，而且全程在真实 Max 主线程里执行、每步可撤销。**  
> 支撑它的是三件别人不容易复制的东西：① 纯 MAXScript 桥（不依赖 pymxs，因此 2020–2027 同一份代码）；② 389 工具的双语 schema；③ 把像素变成 MCP `image` 块的能力。第二梯队是 `context_get` 的 9 域增量快照——它让 AI 不必"盲猜场景"，这一点在长对话里价值极高。

**最薄弱的环节是什么？**

> **"返回值与现实的偏差没有第二来源。"**  
> 不是工具少，也不是速度慢，而是：AI 说"参数设好了"，实际没设（P0-1）；AI 说"看看上下文状态"，工具崩了（P0-4）；AI 说"撤销一步"，Max 死了 20 分钟（P0-5）。这三件事对 Agent 工作流的破坏是**结构性**的——模型会基于假前提继续往下做，错误越滚越大。而默认配置下 `runtime_verify=false`，等于把这个问题的唯一兜底关掉了。

**哪些能力现在可以对外展示？**

- 场景查询与统计（`context_get` / `scene_info` / `list_objects` / `get_selection`）
- 基础体与样条创建、变换、选择、成组（15 条 live case 全通过）
- 可编辑多边形主要操作（14 条通过，除 `poly_triangulate` 的断言偏差）
- 材质赋值与属性设置（8 条通过）
- 视口截图 / 多视角 / 渲染预览（今日实机返回真图）
- 安装 → 连接 → 自检 → 第一条查询 这条新手路径（可复现）

**哪些能力现在不应该对外承诺？**

- "参数可靠"（`mod_*` 的 `params` 路径有假成功）
- "撤销随时可用"（`undo_last` 会卡死）
- "所有工具都验证过"（43/389）
- "支持 2020–2027"（只有 2022 有证据）
- "动画与绑定可用"（59 个工具 0 条 live case）
- "渲染/烘焙/导出可靠"（0 条 live case，且 `_recover_written_file` 有误判风险）
- "可以作为云端服务暴露"（无认证 TCP + 任意代码工具 + token 可走 URL）
- "视觉闭环已成型"（工具有，闭环成功率无数据）

### 8.3 v0.1.0 最需要解决的五个问题

|  序 | 问题                                                                         | 为什么排这个位置                                                                                      | 改动量级（仅供评估，本次不改）                               |
| -: | -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------- |
|  1 | **修改器参数三连**（`params` 的 object 语义 + `mod_set_param` 的类型转换 + `mod_add` 据实回报） | 同一个根因，一次修完同时解决"假成功 / 必失败 / 参数不可用"，且覆盖 23 个工具名                                                 | 小：catalog 2 处 + `_coerce` 1 处 + MAXScript 2 处 |
|  2 | **`context_stats` 空值兜底**                                                   | 崩溃，且是唯一的状态观察入口                                                                                | 极小：1 行判空                                      |
|  3 | **`undo_last` 出主线程泵**                                                      | 单点全阻塞，一次调用毁掉整个会话；且它是"AI 可撤销"承诺的核心                                                             | 中：需要重新设计调用时机，不是改一行                            |
|  4 | **默认读回校验 + 修 `_recover_written_file`**                                     | 让"AI 的成功声明"至少有一个第二来源；导出误判会让人以为资产已生成                                                           | 中：`runtime_verify` 默认值 + 导出恢复加 mtime 判据       |
|  5 | **文档与元数据一致性**                                                              | 对外发布的最小体面：384→389、CHANGELOG 的 390、LIVE_MATRIX 重生成、release 前缀 `3dsmax-map`、clone URL、Python 探测 | 小，但琐碎，必须做                                     |

### 8.4 发布建议

- **不建议现在打 tag 发布 v0.1.0。** 理由不是"东西不够多"，而是"承诺与证据不匹配"：389 个工具对外宣称的能力，只有 43 条实机用例支撑；同时 3 处会让 AI 判断失真的缺陷在默认配置下必然触发。
- **建议的发布前最小动作**：修 §8.3 的 1/2/3/5（1、2 是几行；3 需要设计；5 是文档），为修改器 + 导出 + 上下文补 6–10 条 live case，重生成 `LIVE_MATRIX`（389），然后以"Beta，已实测 2022，其余版本未验证"的口径发布。
- **不建议**在修好 P0 之前做任何"生产可用 / 企业级"表述。
- **提交历史本身不是阻碍**：20 个未推送提交经逐条审计确认干净（无空提交、无 revert、无临时提交、无二进制、无密钥），但版本号在 HEAD 上不一致（`1.2.0` vs `1.0.0`）、CHANGELOG 缺 T11/T12、`release.yml` 未跟踪、`output/` 未忽略——这四项发布材料需在 T18 前补齐。详见 §9.4。

---

## 9. 附录

### 9.1 本次审计实际执行的只读命令

| 命令                                                          | 用途            | 结果                                                                                                                                                                                      |
| ----------------------------------------------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `git log/status/rev-parse/remote/tag`                       | Git 状态        | HEAD `2b8d43b`，+20 未 push，5 改 2 未跟踪，无 tag                                                                                                                                               |
| `python -B src/python/maxmcp/__main__.py --selftest-python` | catalog 自检    | 389 tools / 9 categories / `all checks passed`                                                                                                                                          |
| `python -B ... --list-profiles`                             | 档位统计          | core 58 / pipeline 178 / animation 183 / lookdev 193 / modeling 207 / full 389                                                                                                          |
| `python -B -c`（统计脚本）                                        | 分类/读写/共享方法/规模 | 见 §4.1                                                                                                                                                                                  |
| `python -B scripts/install.py --list`                       | 检测（只读）        | 1 个 Max 2022 ENU；Python `(not found)`                                                                                                                                                   |
| `tasklist` / `netstat`                                      | 进程与端口         | Max 未运行、8760–8779 无监听                                                                                                                                                                   |
| `cmp` 全量对比仓库 ↔ 安装目录                                         | 部署一致性         | MAXScript 23/23 一致（`.ini` 仅行尾差异）；Python 22/22 一致                                                                                                                                        |
| `python -B -c`（`_coerce` 复现）                                | 参数强转          | dict→`[{...}]`；`3`→`"3"`；`True`→`"True"`                                                                                                                                                |
| 阅读源码 / 文档                                                   | 架构与缺陷定位       | `server.py`、`bridge.py`、`http_transport.py`、`runtime.py`、`mcp_net.ms`、`mcp_core.ms`、`mcp_modifiers.ms`、`mcp_context.ms`、`mcp_events.ms`、`mcp_vision.ms`、`mcp_system.ms`、`mcp_json.ms` 等 |
| 目视检查 `output/forest/views/01_aerial_wide.png`               | 视觉产物确认        | 真实 3D 场景（树林 + 水池 + 地形）                                                                                                                                                                  |

**未执行**：启动 Max、安装/卸载、任何写场景的工具、`undo_last`、git 写操作。

### 9.2 关键文件索引

| 主题              | 文件                                                                                                       |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| MCP 派发与参数层      | `src/python/maxmcp/server.py`（1,097 行）                                                                   |
| 工具目录            | `src/python/maxmcp/catalog/{schema,core,objects,modeling,shading,animation,pipeline,context,domains}.py` |
| TCP 客户端         | `src/python/maxmcp/bridge.py`（276 行）                                                                     |
| HTTP/SSE        | `src/python/maxmcp/http_transport.py`（498 行）                                                             |
| 运行封装（读回）        | `src/python/maxmcp/runtime.py`（345 行）                                                                    |
| 上下文缓存（服务端）      | `src/python/maxmcp/context.py`（174 行）                                                                    |
| 桥入口与模块清单        | `src/ms/mcp_bridge.ms`（430 行）                                                                            |
| 主线程泵与派发         | `src/ms/mcp_net.ms`（650 行）                                                                               |
| 注册表 / 消息 / undo | `src/ms/mcp_core.ms`（574 行）                                                                              |
| JSON 引擎         | `src/ms/mcp_json.ms`（816 行）                                                                              |
| 修改器（3 个 P0 所在）  | `src/ms/mcp_modifiers.ms`（729 行）                                                                         |
| 场景上下文（P0-4 所在）  | `src/ms/mcp_context.ms`（1,345 行）                                                                         |
| 变更账本            | `src/ms/mcp_events.ms`（568 行）                                                                            |
| 视觉              | `src/ms/mcp_vision.ms`（499 行）                                                                            |
| 桥接契约文档          | `docs/BRIDGE_CONVENTIONS.md`（257 行）                                                                      |
| 实机矩阵（已过期）       | `docs/LIVE_MATRIX.md`（384/43，2026-10-20）                                                                 |
| 历史报告            | `docs/reports/AUDIT_20261114.md` 等 7 篇                                                                   |

### 9.3 术语

| 术语                         | 含义                                                                                    |
| -------------------------- | ------------------------------------------------------------------------------------- |
| **hold / theHold**         | MAXScript 的撤销事务：`Begin` → 一组操作 → `Accept`（合成一步）或 `Cancel`（回滚）                         |
| **main-thread pump（主线程泵）** | 用 WinForms Timer 25 ms 一次地在 UI 线程上取 socket 数据并同步执行，保证只碰主线程场景 API                      |
| **wire codec**             | Python 侧把非 ASCII 字符编码成本地 ANSI 字节再转 `\u00XX`，使 MAXScript 单字节读取不失真                      |
| **dirty domain**           | `mcp_domains.ms` 里声明"这个命令会让哪些 context 域失效"，写入后对应域 revision +1                         |
| **revision / since**       | 全局单调计数器；`since` 传上次拿到的 revision，只回之后变过的域                                              |
| **preset**                 | catalog 里预置、对 AI 隐藏的参数（如 `create_box` 的 `class:"Box"`、`mod_bend` 的 `modifier:"Bend"`） |
| **profile**                | 工具子集开关（core/modeling/lookdev/animation/pipeline/full）                                 |
| **A/A*/A-doc/B/C/D**       | 见 §6.1 证据等级                                                                           |

### 9.4 20 个未推送提交审计（发布边界的前置检查）

`git rev-list --count origin/main..HEAD` = **20**，merge-base = `7973cbd`（`origin/main` 当前指向）。范围总量：**59 个文件，+9585 / −348**。

#### 提交清单（按时间顺序，共 20 条）

| #  | 提交        | 时间          | 主题                                                                                            | 归属      | 规模 (+/−)                         |
| -- | --------- | ----------- | --------------------------------------------------------------------------------------------- | ------- | -------------------------------- |
| 1  | `0b0b762` | 11-14 04:57 | feat(context): scene-aware context layer, event ledger and in-Max panel                       | Phase A | +3323 / −46（19 文件）               |
| 2  | `e14ad28` | 11-14 04:59 | fix(scene): scene_statistics classified every object as 'other'                               | Phase A | +86 / −17                        |
| 3  | `74b88a5` | 11-14 08:12 | fix(context): cap every error at 400 chars, add stale/supported/updatedAt                     | Phase A | +2394 / −2273（**有效 +158 / −37**） |
| 4  | `d10a01f` | 11-14 08:12 | style: restore LF endings on the three -text .ms files                                        | **噪声**  | +2366 / −2366（**−w 后 0 行**）      |
| 5  | `295995e` | 11-14 08:20 | feat(panel): Connection / Context / Events / Diagnostics, cache-only refresh                  | Phase A | +294 / −54                       |
| 6  | `aaaea05` | 11-14 08:21 | fix(doctor): stop reporting a healthy autoloader as broken                                    | Phase A | +138 / −5                        |
| 7  | `0bfe9ec` | 11-14 08:24 | fix(rigging): rig_list_bones could not see Biped or CAT bones                                 | Phase A | +993 / −620（**有效 +392 / −19**）   |
| 8  | `531ab7b` | 11-14 08:24 | style: restore CRLF endings on mcp_rigging.ms                                                 | **噪声**  | +872 / −872（**−w 后 0 行**）        |
| 9  | `54cf4c4` | 11-14 08:38 | fix(panel): reopen the bridge after bridge_stop, and stop the audit gap                       | Phase A | +505 / −4                        |
| 10 | `9b8c75a` | 11-14 08:59 | fix(context): report the refresh duration, not Max's uptime                                   | Phase A | +117 / −1                        |
| 11 | `1b45237` | 11-18 10:52 | feat(catalog): declare which context domains each tool invalidates                            | Phase B | +1388 / −12                      |
| 12 | `01eb33d` | 11-18 10:53 | fix(context): make the snapshot's numbers, flags and revisions trustworthy                    | Phase B | +814 / −63                       |
| 13 | `58d5df6` | 11-18 10:54 | fix(catalog): four handlers were declared read-only but write the scene                       | Phase B | +8 / −4                          |
| 14 | `1976b14` | 11-18 10:54 | fix(system): stop exposing bridge_stop to AI clients                                          | Phase B | +92 / −35                        |
| 15 | `b07f87c` | 11-18 10:55 | fix(maxscript): repair the handlers that reported success without doing the work              | Phase B | +960 / −175（11 文件）               |
| 16 | `188dc36` | 11-18 10:55 | fix(bridge): answer the right request, and clear the dialog that blocks it                    | Phase B | +307 / −8                        |
| 17 | `80356b6` | 11-18 10:56 | test(live): prove a write reaches the right domains and no other                              | Phase B | +246 / −0                        |
| 18 | `5404afb` | 11-18 10:56 | docs: changelog for the Phase B fixes, and the counts that follow from them                   | Phase B | +150 / −18                       |
| 19 | `0de553c` | 11-18 23:51 | fix(install+security): clear Max-not-found guidance, fail-closed HTTP exposure, security docs | **T11** | +260 / −24                       |
| 20 | `2b8d43b` | 11-19 08:29 | T12: fix modifier reliability and update docs                                                 | **T12** | +542 / −21                       |


**直接回答"是否有未纳入 T11/T12 的功能或修复"：有，18 条。** 20 条里只有 `0de553c`（T11）和 `2b8d43b`（T12）属于近期任务书；**前 18 条是两个完整阶段**：Phase A（10 条，新建 context / events / ui 三个 MAXScript 模块 + 6 个新工具 + 1 个 MCP resource，一次 `+3323` 的功能提交）与 Phase B（8 条，写→域声明表、read-only 误标修正、handler 诚实性修复、桥接请求配对）。**Phase A 是本轮最大的功能增量，却没有任何任务书记录它**——这正是发布边界必须先审计的原因。

#### 卫生检查（全部通过，无需整改）

| 检查项                                                        | 结果                                         |
| ---------------------------------------------------------- | ------------------------------------------ |
| 空提交                                                        | 0（逐条 `git diff --numstat` 校验）              |
| 合并提交                                                       | 0（线性历史）                                    |
| `revert` / `wip` / `tmp` / `fixup` / `squash` / `debug` 提交 | 0                                          |
| 重复 subject                                                 | 0                                          |
| 二进制 / 构建产物（png/jpg/exe/dll/zip/pdf/mp4/pyc/log）            | 0                                          |
| 明文密钥（token / api_key / 私钥块）                                | 0                                          |
| 单条提交跨越无关模块                                                 | 未发现（最大 `b07f87c` 11 文件同属"handler 诚实性"一个主题） |

#### 需要处理的三件事（都不属于"重写历史"）

**① 2 条纯换行噪声提交（占 10%），已自愈，不要改写。**  
`d10a01f`（+2366/−2366）与 `531ab7b`（+872/−872）`git diff -w` 后均为 **0 行**，即零语义变更。成因是前一条提交（`74b88a5`、`0bfe9ec`）在改内容时把 `.ms` 的行尾一起归一化了，随即被专门的 style 提交还原。`.gitattributes` 已用 `*.ms -text` 防止复发，且当前四个文件行尾完全一致（`mcp_context.ms` 1345/1345、`mcp_events.ms` 568/568、`mcp_json.ms` 816/816、`mcp_rigging.ms` 872/872 行均为 CRLF）。**结论：保留原样**——squash 它们等于重写 59 个文件的历史，收益为零。

**② HEAD 上的版本号是坏的，会直接卡死发布工作流。**  
已提交状态：`pyproject.toml` = `1.2.0`，`src/python/maxmcp/config.py` = `1.0.0`（**两者不一致**）。而 `.github/workflows/release.yml` 的 "Verify version consistency" 步骤要求标签版本、pyproject、config.VERSION 三者相等，**现在打 tag 必然 fail**。三处改为 `0.1.0` 的修复只存在于未提交的 T08 遗留（`pyproject.toml`、`config.py`、`docs/CHANGELOG.md`）——T18 必须先把它作为独立提交落地，不能靠 tag 触发时临时改。

**③ CHANGELOG 对 T11 / T12 无记录，且 0.1.0 段落不能直接当 Release body 用。**  
在 `## [0.1.0]` 段落（第 7–588 行）内检索：`fail-closed` 0 次、`0.0.0.0` 0 次（T11 未写）；`mod_add` 0 次、`mod_set_param` 0 次（T12 未写）。同时该段落已有 **583 行 / 59 条 bullet / 8 个 `###` 小节（`Added`×2、`Fixed`×3、`Changed`×2 等重复标题）**，违反 Keep a Changelog 的单节结构；`release.yml` 会把这 583 行原样塞进 GitHub Release 正文。T18 需要拆分为用户可读的发布说明，而不是直接复用。

#### 另外两条发布阻断（工作区层面，非提交层面）

| 项                                       | 事实                                                        | 影响                                                                                                         |
| --------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `.github/workflows/release.yml` **未跟踪** | `git status` 显示 `?? .github/`                             | 现在 `git push origin v0.1.0` **不会触发任何发布**；且该工作流只做 tag + Release，**不产出安装包**（T18 的"安装包"需另外定义：源码 zip 还是新增构建步骤） |
| `output/` **未跟踪且未忽略**                   | 42 MB，15 个 PNG + 2 个 `.max`；`.gitignore` 中无任何 `output` 规则 | 任何人执行 `git add -A` 都会把 42 MB 场景资产提交进仓库；T18 前必须补 `.gitignore` 规则                                            |

`RELEASE_TITLE_PREFIX: "3dsmax-map"` 确认是笔误（应为 `3dsmax-mcp`），Release 标题会变成 `3dsmax-map-v0.1.0`。

#### 发布边界建议

- **20 条全部进入发布线**，不做筛选、不做 squash、不做 rebase。Phase A 是主体功能（context 层 + 面板 + 6 工具），抽掉它发布等于发布一个 README 与代码不符的版本。
- **T18 需要额外 3 个提交**（顺序固定）：① T08 版本号 + CHANGELOG 遗留（其中 README 的 `384 → 389` 单独核对后再并入或独立提交）；② T11 / T12 的 CHANGELOG 补记；③ `release.yml`（修 `PREFIX`）+ `.gitignore` 的 `output/` 规则。
- **不要分批 push**。20 条是一个线性整体，分批推送只会制造中间态（例如只推到 `9b8c75a` 时，Phase B 的 read-only 修正还不在，303 个写工具的域声明是错的）。
- 审计结论：**这 20 条提交本身是干净的**——阻碍发布的不是历史质量，而是"版本号 / CHANGELOG / 发布工作流 / 忽略规则"这四项发布材料尚未就位。

---

**报告结束。本次审计未修改任何源代码、配置或文档，未提交、未打 tag、未发布。唯一新增文件即本报告。**
