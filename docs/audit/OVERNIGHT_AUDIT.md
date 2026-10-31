# 3dsmax-mcp 夜间工程审计（Core Runtime Reliability）

- 仓库：`D:\Workspace\MCP\3dsmax-mcp`（任务书给的 `D:\Workspace\Dev\3dsmax-mcp` 不存在）
- 分支 / HEAD：`main` / `98e6499826ee1206b686c0d93069d97cdea4e844`（`feat: add npm launcher package`）
- 工作树状态（审计开始时）：干净，`main` 领先 `3dsmax-mcp/main` 1 个提交
- 审计日期：2026-10-31
- 审计方式：只读代码阅读 + 离线运行现有测试；未连接真实 3ds Max，未修改任何 `.max` 文件

本文件记录**审计发现**。修复与否、证据边界、以及最终测试结果见
`docs/audit/OVERNIGHT_FINAL_REPORT.md`。

---

## 1. 系统架构简图

```text
                    AI Agent (MCP client)
                            │  JSON-RPC 2.0 (stdio / Streamable HTTP / legacy SSE)
                            ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ src/python/maxmcp/                                                       │
│                                                                          │
│  protocol.py     stdio 传输、content block（text / image）、clamp         │
│  server.py       dispatch、tools/list、tools/call、参数校验、图片拆分      │
│  catalog/        384 个工具的 schema + profile（core=56）                  │
│  runtime.py      SceneRuntime：before/after 快照、verification、failures   │
│  batch.py        按对象批量执行 / 对账（新增）                             │
│  scene_state.py  节点快照与差异（新增）                                   │
│  errors.py       稳定错误码分类与 MAXScript kind 映射（新增）              │
│  bridge.py       TCP 客户端、超时、重连、错误分类                          │
│  wire.py         ANSI⇄latin-1 字节线码（中文安全）                        │
└──────────────────────────────────────────────────────────────────────────┘
                            │  newline-delimited JSON, ASCII only, 127.0.0.1:8765
                            ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ src/ms/  19 个 MAXScript 模块（353 条 mcpRegister 命令）                   │
│                                                                          │
│  mcp_bridge.ms  入口：定位目录、加载模块、启动、写 bridge.log             │
│  mcp_net.ms     TcpListener + WinForms Timer(25ms) 泵 + 行分帧 + 1MiB 上限 │
│  mcp_core.ms    mcpObj/mcpFail/mcpMessages、mcpResolveNode(s)、mcpNodeInfo │
│  mcp_json.ms    JSON 编解码（ASCII 字节转义）                             │
│  mcp_objects.ms / mcp_poly.ms / mcp_modifiers.ms / mcp_shading.ms / ...   │
│  mcp_vision.ms  视口截图 / 渲染预览 → "_images" base64                    │
└──────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    3ds Max 场景（主线程执行）
```

## 2. 主要执行链路

### 2.1 工具调用（读/写）

```text
tools/call
  -> server.on_tools_call
     -> catalog.get(name)                        未知工具 -> isError
     -> _build_payload                           required / 类型 / 默认值 / preset
     -> 选择执行路径：
        a) core profile 或 MAXMCP_RUNTIME_VERIFY，且 mutating
              -> SceneRuntime.execute（scene_info 前后快照 + verification）
        b) 其余
              -> MaxBridge.call（单次调用，无 read-back）
     -> from_wire(result)                         ANSI 字节码解码（一次）
     -> _split_images                             "_images" -> MCP image block
     -> json.dumps + clamp_text                   -> content[]
```

### 2.2 批量工具（改造前）

```text
transform_object / clone_objects / delete_objects / select_objects / mat_assign / mod_add
  -> 一次 bridge.call，objects=[...]
  -> MAXScript: mcpResolveNodes(...)  —— 任一名字缺失 -> mcpFail 整条命令失败
  -> 每个节点 try(...) catch()  —— 单节点异常被吞掉
  -> 返回 {"message": "完成。"} / {"applied": [...]}
```

### 2.3 视觉反馈

```text
3ds Max 视口/渲染
  -> mcp_vision.ms 写位图 -> dotNet 编码 PNG/JPEG -> base64
  -> {"_images":[{label,data,mime}]} 经 bridge 回传
  -> server._split_images -> {"type":"image","data":...,"mimeType":...}
  -> MCP content[]（text + image 并存）
```

### 2.4 错误传播

```text
MAXScript: mcpFail "err.node_not_found" -> throw(本地化字符串)
  -> mcp_net.ms: {"ok":false,"error":{"kind":"err.node_not_found","message":...}}
  -> bridge._parse: detail=from_wire(err) -> BridgeCommandError
  -> server: isError=true + {"error":{code,kind,tool,message,suggestion}}
```

---

## 3. 当前存在的问题（审计发现，按严重度）

| # | 问题 | 位置 | 严重度 | 处置 |
| --- | --- | --- | --- | --- |
| A1 | MAXScript 的 `err.*` kind 在 `_parse` 中被丢弃，所有命令失败都变成 `command_error`；客户端只能解析本地化文本 | `bridge.py:_parse` | 高 | 已修复：`errors.classify` 映射为稳定 code，原始 kind 保留在 `max_kind` |
| A2 | `runtime` 路径下，桥接异常消息（已是解码后的中文）会被 `from_wire` 二次解码成乱码 | `server.py:on_tools_call` + `wire.from_wire` | 高 | 已修复：`from_wire` 对含 >U+00FF 字符的字符串视为恒等 |
| A3 | 批量工具是"全有或全无"：`mcpResolveNodes` 遇到一个不存在的名字就整条命令失败，没有逐对象结果 | `mcp_core.ms:403`、6 个批量 handler | 高 | 已修复（Python 侧 `batch.py`）：逐对象执行 + 逐对象错误 |
| A4 | `mat_assign` / `select_objects` / 逐节点 `try(...) catch()` 的 handler 在部分对象失败时仍返回成功 | `mcp_shading.ms:229`、`mcp_objects.ms:682` | 高 | 已修复（对账层）：按 Max 回报的 `applied` / 选择集生成逐对象结果 |
| A5 | 同名对象（Max 允许重名）由 `getNodeByName` 任取一个，Agent 可能改错对象 | `mcp_core.ms:mcpResolveNode` | 高 | 已修复（Python 侧预解析）：`find_objects exact` 命中 >1 -> `ambiguous_object`，拒绝执行 |
| A6 | 空返回值 `{"ok":true,"result":null}` 被当作成功且无任何提示 | `runtime.execute` | 中 | 已修复：`empty_result` warning + `verification.performed=false` |
| A7 | `scene_save` 被声明为 `mutating=False`（对客户端宣告 readOnlyHint），实际写盘 | `catalog/core.py` | 中 | 已修复：改为 mutating |
| A8 | `scene_save_as` 可静默覆盖任意已存在的 `.max`；`keepPath` 参数声明了但 handler 忽略 | `mcp_scene.ms:176`、`catalog/core.py` | 中 | 已修复：已存在文件需 `confirm=true`；`keepPath` 已实现（Runtime 未验证） |
| A9 | 图片链路只校验扩展名/自报 MIME，不校验字节；`data` 不做 base64 校验、不限大小；`path` 可指向任意可读文件 | `server.py:_image_bytes` | 中 | 已修复：base64 严格解码 + 文件头嗅探 + MIME 以字节为准 + 8MiB/12MiB 预算 + 目录白名单 |
| A10 | runtime 包装后的结果里 `_images` 位于 `data` 下，`_split_images` 只看顶层 -> 图片会静默丢失 | `server.py:_split_images` | 中 | 已修复：递归查 `data` / `result` |
| A11 | 参数校验只做类型转换，`enum` / `minimum` / `maximum` / `minItems` 全部忽略，越界值直达 Max | `server.py:_coerce` | 中 | 已修复：枚举（大小写归一）、上下界、数组长度 |
| A12 | `timeout` / `not_running` / `protocol_error` 这些桥接类别没有稳定 code，客户端无法区分"Max 卡住"和"Max 没开" | `bridge.py` | 中 | 已修复：`bridge_*` 稳定码 + `retryable` 标记 + `BridgeDisconnected` |
| A13 | 断开连接与"未启动"共用 `BridgeNotRunning`，诊断信息误导 | `bridge.py:_read_line` | 低 | 已修复：`BridgeDisconnected(kind="disconnected")` |
| A14 | `resolve_object_refs` / `build_batch_result` / `normalize_payload` 只有测试引用，未接入执行路径（死代码） | `runtime.py` | 中 | 部分修复：`build_batch_result` 语义收紧；引用解析接入 `batch.py`；`normalize_payload` 仍为适配器工具，未接主路径 |
| A15 | 176 个 MAXScript 静默 `catch()`（`verify.py` 统计），单节点失败不可见 | `src/ms/*.ms` | 高 | **未修复**：需要逐 handler 改造 MAXScript，属于跨模块重构；本轮用 Python 侧 read-back 兜住核心 6 个批量工具 |
| A16 | `transform_object` 的 undo 粒度：逐对象执行会产生多条 undo 记录（原实现一条） | `batch.py` | 低 | **接受并记录**：仅 core profile / `MAXMCP_RUNTIME_VERIFY` 下生效，换来逐对象错误与 read-back |
| A17 | 语料库漂移：`test/static/registration_sync_test.py` 失败，因为用户机器上已部署的 Max 脚本与仓库 `src/ms` 不一致 | 环境 | 低 | **未修复**：需要运行 `scripts/install.py` 覆盖用户 Max 安装，超出授权范围 |
| A18 | `execute_maxscript` 仍然是无限制任意代码执行（设计如此）；`scene_open` 可加载任意路径文件 | `catalog/core.py`、`mcp_system.ms` | 高（架构） | **只提供方案**：见第 6 节，需要真实 Max 验证与产品决策 |

## 4. 高风险代码位置

| 位置 | 风险 |
| --- | --- |
| `src/ms/mcp_system.ms:mcpH_execute_maxscript` | 任意 MAXScript 执行，等价于完全控制 Max 会话 |
| `src/ms/mcp_scene.ms:mcpH_scene_open/save/save_as` | 任意路径读写、覆盖用户场景；本轮只加了覆盖确认 |
| `src/python/maxmcp/bridge.py:_connect/_read_line` | 单连接串行锁、超时全部按总时长计算；长渲染会占用整个超时预算 |
| `src/ms/mcp_net.ms:mcpNetPump` | 每 tick 最多 256 行、单请求缓冲 1MiB；超限直接断开（无错误帧） |
| `src/python/maxmcp/server.py:_image_bytes` | 曾经是可读任意图片文件的入口（现已加目录白名单） |
| `src/ms/mcp_objects.ms:mcpH_transform_object` | 逐节点 `catch()` 吞异常，无逐对象结果（Python 侧已兜底） |
| `src/python/maxmcp/runtime.py:execute` | 校验只覆盖创建/删除/重置的对象数量，其他工具 `verification.performed=false` |

## 5. 审计时缺失的测试

| 缺失 | 现在由谁覆盖 |
| --- | --- |
| 桥接错误 kind 是否传到 Python | `test/static/error_protocol_test.py`（新增） |
| 断线 / 空回复 / 非法 JSON / 超时 / 未启动 | `test/static/offline_acceptance_test.py`（新增） |
| 批量逐对象结果、部分失败、重复对象、传输中断 | `test/static/batch_reliability_test.py`（新增） |
| 同名 / 删除后引用 / 重命名 / 非法引用 | `test/static/object_reference_test.py`（新增） |
| 场景快照与前后差异 | `test/static/scene_state_test.py`（新增） |
| 图片字节校验、路径越权、预算、嵌套 `_images` | `test/static/image_result_test.py`（扩充） |
| 24 个无 live case 的 Core 工具参数与安全边界 | `test/static/core_tool_validation_test.py`（新增） |
| 真实 Max 下的逐对象 read-back、截图、保存确认 | **仍然缺失**，见第 7 节 |

## 6. 建议修复顺序

1. ~~错误协议统一（A1/A2/A12/A13）~~ —— 已完成，后续所有批处理错误分类依赖它。
2. ~~批量逐对象结果与对账（A3/A4/A5/A14）~~ —— 已完成。
3. ~~图片链路加固（A9/A10）~~ —— 已完成。
4. ~~参数边界校验（A11）~~、~~危险工具标注与确认（A7/A8）~~ —— 已完成。
5. **MAXScript 侧逐 handler 收集失败（A15）**：把 `try(...) catch()` 改为收集 `#(nodeName, error)`，让 `applied/failures` 成为一等返回字段；需要真实 Max 回归。
6. **并发与取消（架构）**：目前 bridge 是全局单锁，一个长渲染会阻塞所有工具调用；建议引入请求级取消与独立长任务通道。
7. **图片链路**：加入可选的缩略图重编码（保持原图不变），并在真实 Max 上验证 JPEG/PNG 输出与 800px 缩放。

## 7. 证据边界（本轮无法在真实 Max 上证明的部分）

- 逐对象 read-back（`find_objects` / `get_object_info`）在真实 Max 上的字段完整性与稳定性；
- `scene_save_as` 的 `confirm` 与 `keepPath` 在真实 Max 上的行为；
- `mcp_vision.ms` 产出的字节是否始终带正确文件头（否则会被新的校验判为 `corrupt_image`）；
- 逐对象执行是否在 Max 里产生符合预期的多条 undo 记录。

这些都在 `docs/OVERNIGHT_ACCEPTANCE.md` 的"真实 3ds Max 验收清单"中列为待验收项。
