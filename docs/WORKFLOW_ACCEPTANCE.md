# Workflow 验收矩阵（Stage 3 / 阶段 H）

本文件只做一件事：把"工作流到底验证了什么""怎么复现""还差什么"写成可核对的表。
**测试分级不混用**：`Static` 只证明 Python 逻辑，`Offline` 走真实 TCP 桩桥 + 假场景，
`Runtime` 必须在真的 3ds Max 里跑。没有任何一条 `Runtime` 项在本轮被执行。

## 1. 怎么跑

```bash
python test/static/workflow_engine_test.py     # Static  —— 引擎语义，注入 invoke，无桥
python test/static/workflow_scene_test.py      # Offline —— MCP -> 真实 TCP -> FakeScene
python test/static/scene_state_test.py         # Static  —— 快照/diff 单元
python test/static/catalog_contract_test.py    # Static  —— 两个新工具的 schema/契约
python scripts/verify.py                       # Static  —— 目录/注册/文档一致
```

`workflow_engine_test.py` 用 `Invoker` 直接喂返回值，**不碰 socket**，所以它只能证明
"引擎怎么解释结果"。`workflow_scene_test.py` 里的 `SceneBridgeStub` 是真实监听
127.0.0.1 的 TCP 服务，说 newline-delimited JSON，穿过真正的 `MaxBridge`
（分帧、超时、断线都是真路径），它后面挂 `FakeScene`——一个按 `src/ms` handler
行为写的内存场景。**假场景不是 3ds Max**，它的结论只到"Python 侧解释正确"。

## 2. 场景矩阵（26 类）

| # | 场景类 | 级别 | 用例 |
| --- | --- | --- | --- |
| W1 | 三个标准工作流完整跑通（10/10/7 步全 verified、expectation 通过、场景真的有对象/修改器/材质） | Offline | `check_workflow_basic_scene`、`check_workflow_model_processing`、`check_workflow_material_look` |
| W2 | 步骤失败 + `on_failure:abort` 中止尾部 | Static | `check_mid_step_failure_aborts_tail` |
| W3 | 步骤失败 + `on_failure:continue` 继续执行 | Static | `check_continue_policy` |
| W4 | 部分成功不得报成整体成功 | Static / Offline | `check_partial_success_is_not_success`、`check_visual_feedback_missing_is_partial` |
| W5 | 依赖未成功 -> 依赖步骤跳过 | Static | `check_dependency_failure_skips_dependent` |
| W6 | 执行成功但场景反驳目标 -> `verification_failed` | Static | `check_verification_failure_when_scene_disagrees` |
| W7 | 回读失败 -> `verification_unavailable`（不是通过） | Static | `check_verification_unavailable_is_not_passed` |
| W8 | 传输中断 -> 步骤 `interrupted`、整体 `interrupted`、`workflow_interrupted` | Static / Offline | `check_transport_failure_interrupts`、`check_bridge_death_mid_workflow` |
| W9 | 非幂等操作即使声明 `retry:transport` 也只跑一次 | Static / Offline | `check_non_idempotent_is_not_retried`、`check_non_idempotent_retry_is_refused_through_mcp` |
| W10 | 只读步骤的传输失败允许重试一次 | Static | `check_read_only_retry_is_allowed` |
| W11 | 非法定义在执行前被拒（重复 id / 未知依赖 / 环 / 未知 operation / 嵌套 / 未知验证 kind） | Static / Offline | `check_invalid_definitions_are_refused`、`check_unknown_and_nested_workflow_are_refused` |
| W12 | `summary` 计数与状态判定一致 | Static | `check_summary_counts` |
| W13 | 快照读不到只丢 diff，不影响步骤执行 | Static | `check_snapshot_failure_degrades_diff_only` |
| W14 | 图像验证三态（有图通过 / 无图不可用 / 图像错误） | Static | `check_image_verification_states` |
| W15 | 失败后重新读场景（`recovery` 有内容、`automatic_retry:false`） | Static | `check_recovery_reads_the_scene` |
| W16 | 参数校验：workflow 与 steps 互斥、未知工作流被 enum 拒绝 | Static / Offline | `check_validation_rejects_bad_input`、`check_unknown_and_nested_workflow_are_refused` |
| W17 | 内置工作流定义自洽（步骤数、依赖、验证 kind、幂等声明） | Static | `check_standard_workflow_definitions` |
| W18 | 快照 + 基线 diff（新增/修改/选择集变化） | Offline | `check_snapshot_and_baseline_diff` |
| W19 | 快照截断 -> `truncated`、`complete:false` | Offline | `check_snapshot_truncation` |
| W20 | 重命名不得被当成"删除 + 新增" | Offline | `check_rename_is_not_delete_plus_create` |
| W21 | handle 缺失 -> `identity_uncertain`，不瞎猜 | Offline | `check_rename_without_handle_is_uncertain` |
| W22 | 重名对象 -> 快照 `partial`、`complete:false` | Offline | `check_duplicate_names_mark_snapshot_partial` |
| W23 | 浮点容差吸收噪声（1e-4 内不算变化） | Offline | `check_tolerance_absorbs_float_noise` |
| W24 | 未知基线 id -> 明确失败并列出已知 id | Offline | `check_unknown_baseline_is_rejected` |
| W25 | 无参数列出工作流 / `dry_run` 不碰场景 | Offline | `check_workflow_listing_and_dry_run` |
| W26 | 自定义步骤 + 目标未达成 -> `partial` 且 `isError:true` | Offline | `check_custom_steps_and_goal_failure` |

级别统计：`Static` 16 类、`Offline` 15 类（其中 5 类两种证据都有，共 26 类），
`Runtime` 0 类。对应 33 个测试函数：`workflow_engine_test.py` 17 个（Static）、
`workflow_scene_test.py` 16 个（Offline）。

## 3. Runtime 待执行清单（本轮未做）

以下每一项都必须在真的 3ds Max 里跑，判定标准写在右边。执行后请把 PASS/FAIL
补在本节，并注明 Max 版本与日期。

| # | 步骤 | 期望 |
| --- | --- | --- |
| R1 | `workflow_run{"workflow":"basic_scene"}` 空场景 | `status:"success"`、`summary.verified==10`、`diff.added` 恰为 4 个对象、视口里真能看到地面/墙/立方体/球 |
| R2 | 同上，执行前删掉 `Ground` 改名成 `Ground_Old` | `renamed` 里出现该配对（不是 removed+added） |
| R3 | `model_processing` 对真 Box | `Editable_Poly`、面数真的增加、TurboSmooth 在堆栈里 |
| R4 | `material_look` | 两个对象的 `material` 字段真的是 MatteRed/MatteBlue，视口渲染确实变色 |
| R5 | 工作流执行中手动关闭 Max | 步骤 `interrupted`、整体 `interrupted`，`recovery.scene_readable:false`，**没有**任何自动重试 |
| R6 | 场景里造两个同名对象后跑 `scene_snapshot` | `handles_unique` 与 `complete` 的真实取值、重名节点是否进 `partial_nodes` |
| R7 | 大场景（>200 节点）`scene_snapshot` | 分页读全（`truncated:false`），`node_count == reported_count` |
| R8 | 中文版 Max 跑 `basic_scene` | 错误与 `note_zh` 是正常中文，不是乱码 |
| R9 | 视口被遮挡时跑 `basic_scene` | 视觉步骤无图 -> `status:"partial"`、`isError:false` |
| R10 | `execute_maxscript` 步骤声明 `retry:"transport"` | 桥断后仍只尝试一次（`escape_hatch_never_retried`） |

R5/R9/R10 是最关键的三个：它们验证的是"失败时不撒谎"，而这一点离线只能证明
Python 侧的解释，证明不了 Max 侧的行为。

## 4. 这批测试**不**证明什么

- 不证明 MAXScript 在真 Max 里做的是同一件事。假场景是照着 `src/ms` 写的，
  它是"我们对 Max 的理解"的回声，不是 Max 本身。
- 不证明画面正确。`vision_capture` 的图在离线测试里是合成 PNG 字节，
  只能证明图片链路通，不能证明视口里长什么样。
- 不证明并发安全。工作流是同步串行的，没有多客户端并发场景的测试。
- 不证明跨会话可用。快照基线在内存里，进程重启即失效（`MAX_SNAPSHOTS=8`）。
- 不证明撤销行为。工作流不做事务，`hold_scene` 只是工具，失败后靠重新读场景，
  不靠回滚。

## 5. 与既有验收文档的关系

| 文档 | 覆盖 |
| --- | --- |
| `docs/OVERNIGHT_ACCEPTANCE.md` | 传输/运行时/批处理/引用/图片五组的基础验收（Stage 1.5） |
| `docs/WORKFLOW_ACCEPTANCE.md`（本文件） | 工作流编排、验证、快照差异、失败恢复 |
| `docs/WORKFLOW_EXECUTION_MODEL.md` | 状态机与重试策略的正式定义 |
| `docs/AGENT_WORKFLOW_CAPABILITY.md` | 15 步能力矩阵与证据分档 |
