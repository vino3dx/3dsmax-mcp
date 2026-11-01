# Workflow 执行模型（Stage 3 / 阶段 B）

`workflow_run` 把"一串 MCP 工具调用"变成一条**可观察、可验证、可恢复**的执行记录。
它刻意做得很小：只有顺序、依赖、失败策略、重试策略、验证和前后对比，没有表达式、
没有循环、没有分支。复杂度留给调用方，可信度留在这里。

代码位置：

| 文件 | 职责 |
| --- | --- |
| `src/python/maxmcp/workflow.py` | 步骤/工作流定义、校验、执行引擎、重试策略、三个标准工作流 |
| `src/python/maxmcp/verify.py` | 12 种操作验证（只读回读，不看请求参数） |
| `src/python/maxmcp/scene_state.py` | 快照、diff、目标断言 `check_expectations` |
| `src/python/maxmcp/server.py` | `_execute_tool`（唯一执行路径）+ 两个本地工具 |

## 1. 请求

```json
{
  "workflow": "basic_scene",         // 或者 steps，二选一
  "steps": [
    { "id": "s1",
      "operation": "create_box",
      "arguments": { "name": "Cube" },
      "verification": { "kind": "exists", "objects": ["Cube"] },
      "depends_on": [],
      "on_failure": "abort",          // abort | continue
      "optional": false,              // 失败只降级，不中止
      "retry": "never" }              // never | transport
  ],
  "expect": { "added_includes": ["Cube"], "count_delta": 1 },
  "capture": true,                    // 前后各拍一次快照用于 diff
  "tolerance": 0.0001,
  "dry_run": false                    // 只校验并列出计划
}
```

规则：

1. `workflow` 与 `steps` 不能同时给（`invalid_arguments`）。
2. `workflow` 的取值受 schema enum 约束；未知名在参数校验阶段就被拒绝，并回列可用名称。
3. 不给任何参数 -> 列出内置工作流（不触碰场景）。
4. 步骤 `id` 缺省为 `step_001`、`step_002`…；重复 id、未知依赖、自依赖、依赖环、
   未知 operation、未知 verification kind、嵌套 `workflow_run` 一律在**执行前**拒绝
   （`workflow_invalid`），不会跑一半才发现定义有错。

## 2. 步骤状态机

每一步最终落在下面 7 个状态之一（`PENDING`/`RUNNING` 是常量，但 `run()` 是同步
执行，返回记录里只有终态 —— 进度只能靠 MCP 日志/通知观察，本轮没有实现流式进度）：

| 状态 | 含义 | 触发条件 |
| --- | --- | --- |
| `success` | 执行成功，且（若声明了验证）验证通过 | 工具 ok + read-back 证明达成 |
| `success` + `verified:false` | 执行成功，但没有证据证明达成 | 没声明验证、或回读失败 |
| `verification_failed` | 执行成功，但场景读回**反驳**了目标 | `verify.evaluate` 返回 `passed:false` |
| `failed` | 工具自己报失败（Max 答复了并说 no） | `ok:false` 且非传输失败 |
| `interrupted` | 传输失败（桥断了/超时），场景状态未知 | `ok:false` 且错误码属传输类 |
| `skipped` | 没有执行 | 前序失败且 `on_failure:abort`，或依赖未成功 |
| `pending`/`running` | 保留 | 当前同步模型不会返回 |

每个步骤同时带三个正交字段，避免"成功"一词被混用：

```json
{
  "execution": "execution_success" | "execution_failed" | "execution_skipped" | "execution_interrupted",
  "verification": { "status": "verification_passed" | "verification_failed" | "verification_unavailable",
                    "performed": true, "passed": true, "kind": "exists", "detail": {...} },
  "status": "success | failed | verification_failed | skipped | interrupted"
}
```

`verification.performed:false` 时 `passed` 必须是 `null`，**不允许**用 `false` 表示
"没有验证"（与 `docs/CORE_CONTRACT.md` 第 3 节同一条规则）。

## 3. 整体状态

| 状态 | 判定 |
| --- | --- |
| `success` | 每一步都 `success` 且 `verified:true`，且 `expect` 全通过 |
| `partial` | 有 `skipped` / 有 `optional` 步骤失败 / 有步骤 `verified:false` / `expect` 未通过 |
| `failed` | 存在非 optional 的 `failed` 或 `verification_failed` |
| `interrupted` | 任一步 `interrupted`（传输层断了） |

`partial` **不是** `success` 的弱化说法，它是独立的结论：`success` 字段仍为 `false`。
但 `partial` 也不是工具级错误——如果场景工作做完了、只是截图没拿到，MCP 响应的
`isError` 保持 `false`，由 `status` 与 `expectation` 说明差在哪。工具级 `isError`
只在下列情况置位：`failed`、`interrupted`、有步骤 `verification_failed`、
或声明了 `expect` 且明确未通过（`passed:false`）。

## 4. 失败行为

| 场景 | 行为 |
| --- | --- |
| 步骤失败 + `on_failure:abort`（默认） | 记该步失败，后续步骤全部 `skipped`（`reason: aborted_after_failure`） |
| 步骤失败 + `on_failure:continue` | 记失败，继续下一步；整体 `partial` 或 `failed` |
| 步骤失败 + `optional:true` | 记失败，继续；整体最多 `partial` |
| 依赖步骤未 `success` | 依赖它的步骤 `skipped`（`reason: dependency_failed`，带 `unmet` 列表） |
| 传输中断 | 该步 `interrupted`，其后的步骤全部 `skipped`，整体 `interrupted` |
| 快照读不到 | 只丢 diff（`warnings[] = snapshot_unavailable`），步骤照常执行 |

部分成功永远不被写成完整成功：`summary` 逐项计数（`succeeded/failed/skipped/
verification_failed/interrupted/verified/unverified`），`failures[]` 每个失败步骤
一条，并额外带 `not_attempted`（被跳过的尾部）。

## 5. 重试策略（唯一允许自动重试的情况）

```text
retry:"transport" + 传输类错误码 + errors.retryable + 操作幂等  ->  重试一次（MAX_ATTEMPTS=2）
其余全部拒绝
```

拒绝原因写进步骤的 `retry[]` 日志：

| `reason` | 含义 |
| --- | --- |
| `policy_never` | 步骤没声明 `retry:"transport"` |
| `not_a_transport_failure` | Max 答复了（参数错、对象不存在…），重试没意义 |
| `code_not_retryable` | 传输类但目录标记为不可重试 |
| `non_idempotent_operation` | 幂等白名单之外的一切操作（clone/delete/create/相对变换…） |
| `escape_hatch_never_retried` | `execute_maxscript` / `execute_python`，任何声明都不重试 |
| `attempts_exhausted` | 已达到 `MAX_ATTEMPTS` |

被拒绝的重试会在步骤上留下 `retry_blocked`，并说明"操作可能已经生效，请重新读场景"。
幂等白名单（`IDEMPOTENT_MUTATIONS`）只有读类和 `select_objects`；判据是"重复执行
不会改变结果"，不是"看起来无害"。

批量信封的嵌套原因也参与判定：`clone_objects` 的顶层码可能是 `aborted`，但
`objects[].error.code` 是 `bridge_disconnected` —— 这时按传输失败处理（步骤
`interrupted`），并记录 `error.transport_code`，同时仍然拒绝重试（因为操作不幂等）。

## 6. 失败后的恢复

每个失败/验证失败的步骤都带 `recovery`：

```json
{ "attempted": true, "scene_readable": true, "object_count": 7,
  "selection": ["Cube"], "automatic_retry": false,
  "note_zh": "失败后已重新读取场景；是否重试由调用方按实际状态决定。",
  "note_en": "..." }
```

它只做一件事：**重新读一次场景**，把"桥还活着吗、场景还能读吗、现在几个对象"
交给调用方。不猜、不回滚、不自动重试。`scene_readable:false` 就是"别再往下做了，
先把桥接修好"。

## 7. 目标断言 `expect`

`expect` 与步骤验证是两层：步骤验证看"这一步做到没有"，`expect` 看"整个场景是不是
变成要的样子"。支持：

| 键 | 含义 |
| --- | --- |
| `added_includes` / `removed_includes` / `modified_includes` / `unchanged_includes` | diff 里必须出现的名称 |
| `selection_includes` | 结束时选择集里必须有的对象 |
| `min_added` / `min_removed` / `min_modified` | 数量下限 |
| `count_delta` | 对象数量净变化 |

没有 diff（快照失败/`capture:false`）时返回 `performed:false, passed:null` ——
不是通过，也不是失败。

## 8. 明确不做什么

- 不是事务系统：不回滚、不 `theHold`、不做两阶段提交。Undo 栈不是数据库。
- 不猜意图：`partial` 之后怎么做由调用方决定。
- 不替代真实 Max 验证：所有验证都是"用桥回读"，桥撒谎它也看不出来。
- 不做条件分支/循环：需要分支就分多次调用。
- 不为通过测试放宽判定：`verification_unavailable` 永远不会被当成 `passed`。

## 9. 档位与可见性

`workflow_run` 与 `scene_snapshot` 是 Python 本地工具（`local=true`），没有对应的
MAXScript 命令，因此不参与 `registration_sync_test` 的注册比对，也不触发任何桥接调用。

标准工作流可以调用当前档位未暴露给 Agent 的工具（例如 core 档位下的
`vision_capture`）。这是有意的：工作流是服务端编排，档位只控制 Agent 能直接看到
哪些工具；如果桥接里缺这个命令，该步会失败，`optional` 步骤则让整体降级为
`partial`，不会让整条工作流崩掉。
