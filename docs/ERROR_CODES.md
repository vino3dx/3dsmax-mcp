# 错误码（Error Codes）

所有失败都使用**稳定错误码**（`kind` / `code` 同值，`kind` 为历史字段名）。错误文本
（`message`）只用于诊断，可能被本地化；客户端**不应该**解析文本，只应该判断错误码。

- 权威定义：`src/python/maxmcp/errors.py`（`ERROR_SPECS` / `MAX_ERROR_MAP` / `BRIDGE_KIND_MAP`）
- 一致性由 `test/static/error_protocol_test.py` 检查（本文件必须包含每个错误码）
- `retryable=true` 表示"重试可能成功"，业务错误（对象不存在/参数非法）不可重试

## 1. 三层来源

| 层 | 原始信号 | 映射方式 |
| --- | --- | --- |
| MAXScript | `mcpFail "err.node_not_found"` → `{"ok":false,"error":{"kind":...}}` | `MAX_ERROR_MAP` |
| Python 桥接 | `BridgeNotRunning` / `BridgeTimeout` / `BridgeProtocolError` / `BridgeDisconnected` / `BridgeCommandError` | `BRIDGE_KIND_MAP` + `kind` |
| Runtime / 批处理 / 媒体 | 自己判定的失败（空返回值、部分成功、校验失败、图片损坏...） | 直接使用码 |

未知的 `kind` **不会被压平**成 `command_error`，而是原样小写透传——保留一个未文档化的
原因，比丢掉它更有价值。

## 2. 错误返回形状

工具级失败（`isError:true`）：

```json
{
  "error": {
    "code": "object_not_found",
    "kind": "object_not_found",
    "tool": "transform_object",
    "message": "Object not found: Box001",
    "suggestion": "Correct the reported Max-side problem, then retry; verify scene state before continuing.",
    "retryable": true
  }
}
```

Runtime / 批处理信封内的失败条目：

```json
{ "kind": "bridge_timeout", "code": "bridge_timeout", "message": "...", "retryable": true, "stage": "execute" }
```

`stage` 取值：`before` / `execute` / `after` / `resolve` / `readback`。

## 3. 传输层（重试有意义）

| 码 | stage | retryable | 含义 |
| --- | --- | --- | --- |
| `bridge_not_running` | transport | yes | 桥接未监听：Max 未启动或 `mcp_bridge.ms` 未加载 |
| `bridge_timeout` | transport | yes | 请求已送达但超时无回复；Max 可能仍在执行 |
| `bridge_protocol_error` | transport | yes | 回包不是合法信封（坏 JSON / 空行） |
| `bridge_disconnected` | transport | yes | 请求中途连接被关闭（Max 退出 / 桥重载） |
| `bridge_error` | transport | no | 未分类的桥接失败 |

## 4. MAXScript 业务层（重试无意义，需要改输入）

| 码 | stage | retryable | 含义 |
| --- | --- | --- | --- |
| `object_not_found` | max | no | 没有对象匹配该名字/引用 |
| `ambiguous_object` | max | no | 有多个同名对象，拒绝猜测 |
| `stale_object_reference` | max | no | 引用已失效（对象被删除或改名） |
| `invalid_object_reference` | max | no | 引用格式非法（空、类型不对、缺少 name） |
| `invalid_arguments` | max | no | 参数缺失或超出声明范围 |
| `empty_selection` | max | no | 命令需要选择集但当前没有选择 |
| `unsupported_class` | max | no | 本机 3ds Max 缺少该类/插件 |
| `wrong_object_type` | max | no | 对象存在但类型不符（例如不是 Editable Poly） |
| `file_not_found` | max | no | 文件不存在 |
| `confirmation_required` | max | no | 需要显式 `confirm=true` 才允许覆盖/不可逆操作 |
| `unknown_method` | max | no | 运行中的桥不支持该命令（版本不匹配） |
| `item_not_found` | max | no | 子项（材质、修改器、层...）不存在 |
| `render_engine_unavailable` | max | no | 无法切换到指定渲染器 |
| `unsupported_feature` | max | no | 当前 Max 版本缺少所需 API |
| `max_runtime_error` | max | no | MAXScript 抛出未分类异常 |
| `max_command_failed` | max | no | 桥报告失败但未给出更具体的 kind |

## 5. Runtime / 批处理层

| 码 | stage | retryable | 含义 |
| --- | --- | --- | --- |
| `empty_result` | runtime | no | 桥返回 `ok:true` 但无 payload，无法验证 |
| `duplicate_object_in_request` | runtime | no | 同一对象在一次请求里出现多次，只执行一次 |
| `selection_scope` | runtime | no | 未给对象列表，命令作用于当前选择，无法逐对象回报 |
| `missing_success` | runtime | no | payload 既没有 `success`/`ok`，也没有 `failures`/`applied` 之类的结论声明 |
| `operation_failed` | runtime | no | 命令已执行但报告失败 |
| `partial_success` | runtime | no | 部分对象失败，整体不是成功 |
| `batch_failed` | runtime | no | 全部对象失败 |
| `item_failed` | runtime | no | 单个条目失败且无更具体原因 |
| `not_applied` | runtime | no | Max 回复里没有把这个对象列为已应用（节点级被静默跳过） |
| `not_deleted` | runtime | no | 删除命令返回了，但 read-back 发现对象还在 |
| `no_effect` | runtime | no | read-back 显示"应该有变化"的操作没有产生变化 |
| `verification_failed` | runtime | no | read-back 与声称的结果矛盾 |
| `verification_error` | runtime | no | 校验本身抛异常，结果因此未验证 |
| `aborted` | runtime | no | 遇到传输失败后停止，后续对象未执行 |
| `not_attempted` | runtime | no | 条目被排队但从未执行 |

## 6. 工作流层（`workflow_run` / `scene_snapshot`）

| 码 | stage | retryable | 含义 |
| --- | --- | --- | --- |
| `workflow_invalid` | workflow | no | 工作流定义非法：未知操作、缺步骤 id、id 重复、依赖不存在或成环 |
| `workflow_unknown` | workflow | no | 没有这个内置工作流名；返回值里带 `available` |
| `workflow_nested` | workflow | no | 工作流步骤里又调用 `workflow_run`，被拒绝（部分结果无法归属） |
| `workflow_interrupted` | workflow | no | 传输失败导致工作流中断，后续步骤未执行 |
| `dependency_failed` | workflow | no | 该步骤依赖的上一步没有成功，因此跳过 |
| `retry_blocked` | workflow | no | 失败的步骤没有自动重试，因为操作不幂等（clone/delete/相对变换/create…） |
| `snapshot_unavailable` | workflow | no | 场景读不到，无法生成快照或对比前后状态 |
| `snapshot_truncated` | workflow | no | 快照达到节点上限，diff 只覆盖部分场景 |

`retry_blocked` 只在**步骤执行失败且本可重试**时出现：它表示"系统主动拒绝了自动重试"，
不是新的失败。调用方应重新读场景（步骤记录里的 `recovery`），再决定是否重试。

## 7. 图像 / 视觉反馈层

| 码 | stage | retryable | 含义 |
| --- | --- | --- | --- |
| `image_unavailable` | media | no | 图片文件不可读（不存在/权限） |
| `unsupported_image_type` | media | no | MIME 不在 png/jpeg/webp 允许集合内 |
| `image_too_large` | media | no | 超出单图 8 MiB 或单响应 12 MiB 预算 |
| `corrupt_image` | media | no | base64 非法，或字节不符合声明格式（无有效文件头） |
| `image_path_not_allowed` | media | no | 图片路径不在允许的截图根目录内 |

## 8. 与旧版行为的差异

| 旧 | 新 | 说明 |
| --- | --- | --- |
| `kind: "not_running"` | `bridge_not_running` | 传输类别改为稳定码，`retryable=true` |
| `kind: "timeout"` | `bridge_timeout` | 同上 |
| `kind: "command_error"` | 具体业务码（如 `object_not_found`） | MAXScript 的 `err.*` 不再丢失 |
| `kind: "ambiguous_object_reference"` | `ambiguous_object` | 与文档/任务约定统一 |
| `verification.passed: false`（未验证时） | `verification.passed: null` | 未执行验证不再伪装成"验证失败" |
| `changed: false`（未观测时） | `changed: null`（批处理） | 未观测不再伪装成"没有变化" |
| `missing_success`（对 `{applied, failures}` 也报） | 只在**完全没有结论声明**时才报 | 见下 |

### `missing_success` 的判定收窄（Stage 3 修复，Stage 4 补回执字段）

可靠性模式（`--profile core`）过去只接受 `success`/`ok` 两个字段。而 `src/ms` 里绝大多数
handler 用 `{applied, failures, message}` 声明结果，于是 `convert_to_editable_poly`、
`mat_assign`、所有 `poly_*` 在 core 档位下会被判成 `missing_success`——“执行成功"却报失败。
`runtime.declared_outcome()` 现在按 handler 实际使用的形状读取结论，顺序固定：

1. `success`（布尔）→ 直接采用；
2. `ok`（布尔）→ 直接采用；
3. `failures`（数组）→ 空即成功，非空即失败（失败条目原样保留在 `failures`；
   条目既可以是错误对象，也可以是 `"Box001: <原因>"` 这样的纯文本）；
4. 枚举字段 `applied` / `deleted` / `created` / `objects` / `results`（数组）
   → 非空即成功，空即“没做成”；
5. **回执字段**（receipt）→ 按值判定，不按存在判定：

   | 类型 | 字段 | 规则 |
   | --- | --- | --- |
   | 布尔回执 | `written` `reset` `copied` `renamed` | 取布尔值本身 |
   | 路径/名号回执 | `saved` `opened` `merged` `group` `layer` | 非空字符串即成功，空字符串即失败 |
   | 对象名回执 | `moved` `aligned` `attached` `detached` `children` `ungrouped` | 非空列表即成功，空列表即失败 |

6. 以上都没有 → 仍然是 `missing_success`（**没有证据不等于成功**）。

`message` **永远不参与判定**：每个 handler 都会返回它，包括什么都没做的那些。把它当结论
就是把“没有证据”读成“成功”，而这正是本函数要防的错误。

回执字段读的是 handler 已经给出的真实证据，不是 Python 侧的形状猜测：`saved` 来自
`saveMaxFile` 之后的实际路径，`written` 来自导出后对文件的检查，`renamed` 来自
`n.name == newName` 的比较（Max 遇到重名会静默保留旧名）。MAXScript 侧没有真实回执的工具
（例如 `hide_objects`、`bake_set_output`）仍然命中 `missing_success`——这是待补的声明缺口，
`test/static/outcome_audit.py` 会把它量化并列出清单。

`test/static/outcome_audit.py` 的硬断言只覆盖**标准工作流实际调用的工具**：那些工具一旦读不出
结论，工作流就会把一次成功的操作记成失败，进而得出关于场景的错误结论。
