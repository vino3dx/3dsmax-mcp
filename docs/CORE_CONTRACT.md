# Core Runtime 契约（离线基线）

本文定义 Python MCP 层对核心场景操作的稳定边界：请求校验、执行路径、结果信封、
批量语义、对象身份和错误码。它**不**把离线 fake bridge / 桩桥的结果当成真实 Max 证据。

相关文档：
- 错误码权威列表：`docs/ERROR_CODES.md`
- 视觉反馈链路：`docs/VISUAL_FEEDBACK.md`
- 验收与证据等级：`docs/OVERNIGHT_ACCEPTANCE.md`
- 本轮审计：`docs/audit/OVERNIGHT_AUDIT.md`

## 1. 兼容名称

仓库当前使用更具体的工具名，以下是面向 Agent 的能力映射：

| 能力 | 当前工具 | 说明 |
| --- | --- | --- |
| create_object | `create_box`、`create_sphere` 等 | 保留按类型的旧接口；不要假设存在未注册的泛化工具 |
| transform_object | `transform_object` | 以对象名/对象列表和变换参数调用 |
| duplicate_object | `clone_objects` | 旧接口保留，返回值仍需结合场景读回 |
| delete_object | `delete_objects` | 破坏性操作；由客户端确认目标和保存策略 |
| apply_modifier | `mod_add` / `mod_set_param` | 通用入口；`mod_*` 是兼容薄包装 |
| assign_material | `mat_assign` | 先用 `mat_create_standard` 或 `mat_list` 确认材质 |

公开参数名保持不变；本轮只在需要处**新增**可选参数（例如 `scene_save_as.confirm`）。

## 2. 执行路径选择

```text
tools/call
  ├─ 参数校验失败                 -> error.code = invalid_arguments（不会触达 Max）
  ├─ 批量工具 + objects 非空
  │    ├─ select_objects / mat_assign / mod_add             -> 对账模式（一次调用 + 逐对象结果）
  │    └─ transform_object / clone_objects / delete_objects  -> 逐对象模式（仅 reliability 模式）
  ├─ reliability 模式（core profile 或 MAXMCP_RUNTIME_VERIFY）且 mutating -> Scene Runtime
  └─ 其余 -> 单次桥接调用
```

"reliability 模式" = `tool_profile == "core"` 或配置 `runtime_verify` /
环境变量 `MAXMCP_RUNTIME_VERIFY=1`。非 reliability 模式下，逐对象模式不启用
（保持一次调用、一条 undo 记录），但对账模式始终启用，因为它只做后处理、零额外调用。

## 3. 单操作信封（Scene Runtime）

```json
{
  "success": true,
  "operation": "create_box",
  "operation_id": "op-00000001",
  "changed": true,
  "warnings": [],
  "failures": [],
  "verification": { "performed": true, "passed": true, "detail": { "kind": "object_count" } },
  "result": { "...": "桥返回的原始 payload" },
  "data": { "...": "同 result" },
  "before": { "objectCount": 0 },
  "after": { "objectCount": 1 }
}
```

规则：

1. `success:false` 必须同时有非空 `failures`，每条至少含 `kind`（稳定码）。
2. `verification.performed:false` 时 `verification.passed` 必须是 `null`，
   **不允许**用 `false` 表示"没验证"。
3. `changed` 只在能观测到前后差异时为布尔；观测不到时批处理返回 `null`。
4. 空 payload（`{"ok":true,"result":null}`）-> `warnings[].kind = empty_result`，
   `verification.performed = false`。
5. 校验从未执行 -> 不能声称"验证通过"。

## 4. 批处理信封

适用于 `transform_object`、`clone_objects`、`delete_objects`、`select_objects`、
`mat_assign`、`mod_add`。

```json
{
  "success": false,
  "operation": "transform_object",
  "scope": "objects",
  "changed": true,
  "warnings": [],
  "failures": [{ "kind": "partial_success", "code": "partial_success", "message": "1 of 3 objects failed" }],
  "verification": { "performed": true, "passed": null, "detail": { "verified": 2, "unverified": 1, "scope": "objects", "mode": "per_object" } },
  "objects": [
    { "name": "Box001", "success": true, "changed": true, "verified": true,
      "object_ref": { "name": "Box001", "handle": 123 }, "readback": { "changed_fields": ["position"] } },
    { "name": "Ghost", "success": false, "changed": null, "verified": false,
      "error": { "kind": "object_not_found", "code": "object_not_found", "message": "...", "object": "Ghost" } }
  ],
  "summary": { "total": 2, "succeeded": 1, "failed": 1, "skipped": 0, "verified": 1 }
}
```

语义：

| 场景 | `success` | 其他 |
| --- | --- | --- |
| 全部成功 | `true` | `summary.failed == 0` |
| 部分成功 | `false` | `failures` 含 `partial_success`，`summary` 精确计数 |
| 全部失败 | `false` | `failures` 含 `batch_failed` |
| 未给对象列表 | 视单次调用结果 | `scope:"selection"`、`objects:[]`、`warnings[].kind="selection_scope"` |
| 传输中断 | `false` | 已执行对象保留结果，后续行 `skipped:true` + `not_attempted`，`failures` 含 `aborted` |
| 重复对象 | 按去重后执行 | `warnings[].kind="duplicate_object_in_request"`，只执行一次 |

逐对象模式的验证来源（全部是**真实 read-back**，不是请求参数）：

| 工具 | read-back | 判定 |
| --- | --- | --- |
| `transform_object` | `get_object_info` 前后 `position/rotation/scale` 差异 | 相对操作要求有变化；绝对操作要求与请求值一致；无变化 -> `no_effect` |
| `delete_objects` | `find_objects exact` | 0 命中 -> 通过；仍存在 -> `not_deleted` |
| `clone_objects` | 对 `created` 名单逐个 `find_objects` | 有缺失 -> `verification_failed` |
| `select_objects` | 响应里的选择集本身（Max 在主线程读回） | `replace/add/subtract` 逐对象判定；`invert` 标记未验证 |
| `mat_assign` / `mod_add` | 响应里的 `applied` / `failures` | 未列入 -> `not_applied` |

注意：`mat_assign` 的 `changed` 为 `null`，因为"赋值语句跑过"不等于"材质真的变了"。

## 5. 对象身份策略

| 输入 | 处理 |
| --- | --- |
| 字符串名称 | 先用 `find_objects{name, exact:true}` 做真实场景解析，再执行 |
| 0 命中 | `object_not_found`（若是"解析成功后执行时消失" -> `stale_object_reference`） |
| >1 命中 | `ambiguous_object`，**拒绝执行**（不取第一个） |
| 空字符串 / 非字符串 / 数字 handle | `invalid_object_reference`（handle 不作为持久 ID） |
| `{"name": ...}` 字典 | 支持，按名称解析 |

`object_ref: {"name", "handle"}` 只是**诊断字段**：handle 来自 `getHandleByAnim`，
在当前实现中未作为执行引用使用（`getNodeByHandle` 的往返可靠性需要真实 Max 验证）。
Agent 应把 `name` 作为引用、把 `handle` 作为"同一性线索"。

## 6. 场景快照与差异

`src/python/maxmcp/scene_state.py` 提供：

- `node_snapshot` / `snapshot_nodes`：从 `mcpNodeInfo` 提取
  `name/handle/class/position/rotation/scale/material/modifiers`；
  字段缺失 -> 进 `missing`，`complete=false`（缺失=未读取，不等于"没有该属性"）。
- `diff_snapshots`：`added` / `removed` / `modified` / `unknown` / `unchanged`。
- `transform_delta`：带容差（默认 1e-4）的变换差异。
- `compare_absolute`：绝对变换校验（欧拉角按 360° 环绕比较）。

不在本轮新增只读工具：快照能力复用 `find_objects` / `get_object_info` /
`list_objects`，避免复制查询接口。

## 7. 错误与失败边界

`success:false` 必须同时有 `failures`；桥接不可用时 MCP 响应必须带 `isError:true`，
不得包装成成功结果。错误码见 `docs/ERROR_CODES.md`，其中传输类错误
（`bridge_*`）带 `retryable:true`。

## 8. 离线证据边界

本契约可由 Python 静态测试、协议测试和假场景测试验证（证据等级 S/O）。
对象是否真的创建、变换、复制、删除，修改器/材质是否真的落到 Max 场景，以及截图是否
真实生成，必须由真实 Max 读回确认（证据等级 M，见 `docs/OVERNIGHT_ACCEPTANCE.md`
第 2 节的 L1–L24）。

结论声明（`success` / `failures` / 枚举 / 回执字段）只说明"handler 说它做了什么"，
不等于"场景真的变成了那样"。两件事在本层是分开的：**执行结论**写在 `success`，
**目标是否达成**写在 `verification`，后者只来自读回。回执字段（`saved`、`written`、
`moved`、`renamed` 等）的读取规则见 `docs/ERROR_CODES.md` 第 5 节——它们比
`message` 强，但比读回弱；`payload_field` 验证器就工作在这个强度上，文档里也是这么写的。
