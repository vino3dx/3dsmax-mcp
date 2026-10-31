# 3dsmax-mcp Core Runtime Audit

日期：2026-10-31  
阶段：Stage 0，只读审计  
仓库：`D:\Workspace\MCP\3dsmax-mcp`  
HEAD：以当前仓库 `git rev-parse HEAD` 为准；本次文档更新不改变运行代码。

## 结论摘要

项目已经具备可用的三段式雏形：Python MCP Server 负责协议和 catalog，TCP MAXScript bridge 负责在 Max 主线程执行场景操作，19 个 MAXScript 模块承载领域实现。Scene Runtime 第一阶段已落地：核心 profile 的变更工具默认执行前后 `scene_info` 快照，返回操作 ID、changed、verification 和 failures；仍有大量工具尚未配置可判定的专用读回规则。

静态盘点得到 384 个工具、8 个分类、19 个 MAXScript 模块。已有 `core` profile 为 56 个工具，视觉结果已经有 `_images` 到 MCP image content 的转换路径。真实 Max 证据仍集中在已有 43 条 live case（42 通过、1 失败）；其余工具不能仅凭静态注册视为可用。

## 当前阶段状态

| 能力 | 当前状态 | 证据边界 |
| --- | --- | --- |
| Runtime 操作封装 | 已实现 | Python 静态测试 |
| 核心对象数读回 | 已实现（创建/删除/重置的保守规则） | Mock bridge + 集成测试，未在真实 Max 证明 |
| 原始桥接失败归一化 | 已实现 | Runtime/Server 集成测试 |
| 图片结果与 operation ID 关联 | 已实现 | 图片结果静态测试，未验证真实截图生成 |
| 真实 Max 验证 | 未完成 | 当前没有新的实机证据 |

## 1. 调用链

```text
Agent
  -> JSON-RPC tools/list / tools/call
  -> maxmcp.server.MaxMcpServer.dispatch
  -> Catalog schema 校验、profile 过滤、preset 合并
  -> maxmcp.bridge.MaxBridge.call
  -> 127.0.0.1:8765 newline-delimited JSON
  -> mcp_net.ms / mcp_core.ms
  -> 分类 MAXScript handler
  -> mcpObj / mcpFail
  -> bridge response
  -> Python result 或 MCP error/image content
```

静态确认：Python 层有 stdio、Streamable HTTP 和 legacy SSE 共用 dispatch；MAXScript bridge 使用 TCP + UI Timer pump，符合 Max 主线程约束。`server.py` 已能把 bridge 返回的 `_images` 转成 MCP image blocks，这为视觉反馈闭环提供了传输基础。

## 2. 工具与模块盘点（实测）

| 项目 | 数量 |
| --- | ---: |
| catalog 工具 | 384 |
| 分类 | 8 |
| MAXScript 模块 | 19 |
| system / scene / files | 58 |
| objects | 61 |
| modeling | 83 |
| shading | 69 |
| animation | 59 |
| pipeline | 54 |
| core profile | 56 |

现有 profile：`core`、`modeling`、`lookdev`、`animation`、`pipeline`、`full`。`core` 已从“按分类包含 system/scene/objects/files”收敛为显式工具集合，减少 Agent 初始上下文负担。

## 3. 现有能力分层

### 已具备

- Python catalog、双语描述、参数 schema、profile 过滤。
- 统一 JSON-RPC dispatch，多个传输层复用同一业务入口。
- TCP bridge 重连、超时和协议错误分类。
- MAXScript 注册表和静态注册同步检查。
- 场景、对象、建模、材质、灯光、相机、渲染、动画等领域模块。
- 视口/渲染图像以 base64 暂存于 `_images`，Python 转换为 MCP image 内容。
- 既有 live matrix 和 modeling 回归框架，支持真实状态读回断言。

### 不足

1. **Scene Runtime 覆盖仍不完整**：核心 profile 已有统一运行时对象，但对象属性、材质、修改器、拓扑等专用读回规则尚未覆盖。
2. **返回结构不统一**：不同工具使用 `object`、`objects`、`applied`、`assignedTo`、`message` 等不同键，Agent 需要记忆每个工具的特例。
3. **身份依赖名称**：大量工具以对象名定位，没有稳定对象 ID 或操作前后的身份映射层。
4. **错误语义不统一**：Python 已有 `BridgeCommandError`，但 MAXScript handler 仍存在裸异常和静默 `catch()`；稳定错误码、失败参数、恢复建议尚未贯穿全链路。
5. **视觉反馈尚未形成操作闭环**：传输路径存在，但 operation 前后截图关联、失败现场保存、客户端可见性和实机覆盖仍需验证。
6. **实机覆盖不足**：LIVE_MATRIX 当前为 43 条用例、42 通过、1 失败，绝大多数 catalog 工具仍是未验证状态。
7. **自由脚本逃生舱过强**：`execute_maxscript` 合理地作为兜底存在，但高频能力缺口会诱使 Agent 绕过语义工具。

## 4. 重复与边界问题

- `mod_*` 薄包装与 `mod_add`/`mod_set_param` 通用入口并存；应保留高频别名，但长尾应由统一 Modifier Runtime 承担。
- `scene_info`、`get_system_info`、`get_object_info`、`poly_info`、`light_get`、`mat_get` 的读取命名和返回形态不完全一致。
- 列表返回键名分别为 `objects`、`materials`、`lights`、`modifiers`、`verts`，分页回声也不完全一致。
- 选择器参数存在 `name`、`object`、`objects`、`material`、`light`、`modifier` 多种写法；短期应在描述中明确，长期通过 Scene Runtime 统一目标解析。
- `type` 在不同工具中既表示 superclass 又表示具体类型；应新增更明确的语义参数并保留兼容读取。

## 5. 风险清单

| 风险 | 证据 | 优先级 |
| --- | --- | --- |
| 静默 catch 造成假成功或不完整修改 | 多个 `src/ms` 模块存在 `catch()` | P0 |
| 多步操作部分成功后留下半完成场景 | handler 多为局部 try/catch，缺统一事务 | P0 |
| 只返回 success 而不读回真实状态 | 现有 live case 特别强调需要读回 | P0 |
| 名称重名/改名后目标失效 | 多数 API 以 name 定位 | P1 |
| 图像结果客户端不可见 | `_images` 路径已存在，但实机/客户端覆盖不足 | P1 |
| Max 版本 API 差异 | 已有 Max 2020 对属性/API 不存在的实测案例 | P1 |
| 当前工作区含其他任务改动 | Git status 显示多个修改和未跟踪诊断/场景文件 | 流程风险 |

## 6. 建议实施顺序

### Stage 1：Scene Runtime（基础层已完成，实机验收待执行）

Python 侧统一结果模型和前后快照已实现。当前核心结果包含：`success`、`operation`、`operation_id`、`changed`、`warnings`、`failures`、`verification`，并保留原始 `result` 与快照。验证信息来自桥接 `scene_info` 读回，不使用 Python 缓存；下一步必须在真实 Max 中验证这些字段和对象数变化。

### Stage 2：Error & Recovery

先覆盖 core profile 中的工具：把静默失败改为结构化 failure；危险操作加入确认；多步操作使用明确的 hold/undo 边界；失败时返回已完成步骤和恢复建议。

### Stage 3：Modeling Runtime

围绕 Editable Poly 和 Modifier 建立统一适配器：选择范围、参数类型、修改器堆栈、拓扑读回和版本能力探测集中处理。

### Stage 4：Visual Feedback

统一 `operation_id` 与前后截图/场景摘要关联；确保 MCP 客户端收到真实 image blocks，而非只有路径；错误时保存最小现场信息。

### Stage 5：Workflow Validation

用空场景完成房间工作流：几何体、材质、灯光、相机、预览渲染、截图、读回验证和错误修正。每一步都记录实机证据。

## 7. 本阶段边界

本次仅更新审计文档，未启动或操作 Max，未读取用户场景文件。Runtime 相关代码变更已由独立提交完成；当前证据仍以静态测试和 Mock bridge 为主，不能替代真实 Max 读回与截图验证。工作区其他改动未归属本次更新，已保留不动。

