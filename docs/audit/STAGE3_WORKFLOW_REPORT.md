# Stage 3 交付报告：Agent Scene Workflow Engineering

**结论：现有工具已经能组成一条可验证、可观察、可恢复的场景制作工作流，而工具总数只增加了 2 个
（384 → 386），桥接命令一条没增加（353）。** 本轮修掉了一个会直接堵死工作流的既有缺陷
（可靠性模式把 `{applied, failures}` 形状误判为失败），补了 4 条影响工具选择与参数正确性的描述，
并把"部分成功""验证不可用""重试被拒""身份不确定"这些以前只能靠自觉的语义写成了代码与文档。

---

## 1. 执行前基线（未改动任何已有修改）

| 项 | 结果 |
| --- | --- |
| 仓库 | `D:\Workspace\MCP\3dsmax-mcp` |
| 分支 / HEAD | `main` / `a8dfbfb`（`docs: record final report commit id in git status`） |
| 工作区 | 干净，无未提交修改（本阶段没有覆盖、重置任何东西） |
| 工具总数 / core 档位 | 384 / 56 |
| 注册命令 / MAXScript 模块 | 353 / 19 |
| `scripts/verify.py` | 通过（21 条 lint 警告为既有基线） |
| 静态与离线测试 | 除 `registration_sync_test.py` 外全部通过 |

`registration_sync_test.py` 在**动手之前就失败**：用户的 Max 安装目录里部署的 5 个 `.ms`
（`mcp_bridge` / `mcp_core` / `mcp_objects` / `mcp_scene` / `mcp_shading`，ENU+CHS 各一份）
与仓库不一致。修复它必须运行 `scripts/install.py` 写用户 Max 安装目录，本阶段明确禁止，
因此保留为**环境性失败**，见第 9 节。

## 2. 阶段 A：能力审计

`docs/AGENT_WORKFLOW_CAPABILITY.md`

把"空场景 → 可交付场景"拆成 15 步，按五档证据分列（已注册 / 有执行路径 / 静态测试 /
离线集成 / 真实 Max）。结论：

- 15 步**没有一步缺少工具**；13 步有离线集成证据。
- 缺离线证据的两步是**组织（层/组/父子）**与**保存导出**——是测试缺口，不是功能缺口。
- 15 步**全部没有真实 Max 证据**（本阶段不启动 Max），因此所有"场景真的被改对了"的结论
  都只对假场景成立。

## 3. 阶段 B：执行模型

`docs/WORKFLOW_EXECUTION_MODEL.md` + `src/python/maxmcp/workflow.py`

- 步骤状态 7 个：`pending` / `running` / `success` / `failed` / `skipped` /
  `verification_failed` / `interrupted`（`pending`/`running` 是常量，同步执行不会出现在
  返回记录里——文档里写明了这一点，没有假装有流式进度）。
- 每一步同时带三个正交字段：`execution`（4 态）、`verification`（3 态）、`status`（终态），
  避免"成功"一词被混用。
- 整体状态 4 个：`success` / `partial` / `failed` / `interrupted`。`partial` 保持
  `success:false`；`isError` 只在 `failed` / `interrupted` / 有 `verification_failed` /
  声明的 `expect` 明确未通过时置位——"场景做完了但截图没拿到"不是错误。
- 定义校验发生在执行前：重复 id、未知依赖、自依赖、依赖环、未知 operation、
  未知 verification kind、嵌套 `workflow_run` 一律 `workflow_invalid`。
- 复用 Runtime 已有能力，没有重写通信与错误处理：工作流每一步都走
  `server._execute_tool()`，与 Agent 直接调工具是同一条路径。

## 4. 阶段 C：场景快照与差异

`docs/SCENE_SNAPSHOT_DIFF.md` + `scene_state.build_snapshot` / `diff_documents`

| 要求 | 实现 |
| --- | --- |
| 新增/删除/变换/名称/材质/Modifier/选择集 | 8 字段固定比较 + `selection` 单独比对 |
| 只用真实读取数据 | 全部来自 `list_objects` / `get_selection`，不看请求参数 |
| 缺失字段标 unknown | `missing` → `partial_nodes` / `missing_fields` / `unknown[]` |
| 浮点容差 | 默认 `1e-4`，可传 `tolerance`；旋转按 360° 环绕（`compare_absolute`） |
| 重命名 ≠ 删除+新增 | 唯一 handle + class 一致才判 `renamed`，并在 `modified` 里留 `previous_name` |
| 名称不是唯一身份 | 重名节点不覆盖，进 `partial_nodes`，`complete:false` |
| 身份不确定要明确标记 | `identity_uncertain`（`handle_missing` / `handle_duplicated` / `handle_not_in_before` / `class_mismatch`） |
| 部分/完整快照都支持 | `node_count` vs `reported_count`、`truncated`、`complete` |

## 5. 阶段 D：操作验证（执行成功 ≠ 目标达成）

`src/python/maxmcp/verify.py`：12 种验证器（`read_ok` / `exists` / `absent` / `count` /
`transform` / `material` / `modifier` / `class` / `face_count` / `selection` /
`payload_number` / `image`）。

- 全部**只读回读**，输入是场景事实，不是"我刚请求了什么"。
- 三态严格分开：`verification_passed` / `verification_failed` /
  `verification_unavailable`；`unavailable` 永远不会被折叠成 `passed`。
- 未知 kind **拒绝执行**而不是静默忽略；验证器抛异常记为 `verification_error`，
  不会读成通过。
- 失败步骤带 `recovery`（重新读 count/selection，`automatic_retry:false`），
  不自动重试任何破坏性操作。

## 6. 阶段 E：三个标准工作流

全部只用现有工具，没有用 `execute_maxscript` 绕过任何一步。

| 工作流 | 步骤 | 覆盖 |
| --- | --- | --- |
| `basic_scene` | 10 | 读场景 → 地面/墙/立方体/球 → 绝对定位 → 数量与单对象复核 → 截图（optional） |
| `model_processing` | 10 | 找目标 → 记类型 → 转 Poly → 面统计 → 按法线选面 → 挤面 → TurboSmooth → 复统计 → 终态 → 截图 |
| `material_look` | 7 | 列材质 → 建两个标准材质 → 分别赋给两个对象 → 逐对象复核 → 截图 |

桩桥上三条都 `status:success`，10/10、10/10、7/7 步全部 `verified`，
`expectation.passed:true`，且假场景里对象/变换/修改器/材质真的变了。

## 7. 阶段 F：轻量失败恢复

| 失败类型 | 行为 |
| --- | --- |
| Bridge 中断 | 步骤 `interrupted`，整体 `interrupted`，`workflow_interrupted` + `recovery.scene_readable:false` |
| 对象不存在 | `object_not_found`，步骤 `failed`（不可重试：不是传输失败） |
| 重名 | `ambiguous_object`，拒绝执行（不取第一个） |
| 参数错误 | `invalid_arguments`，不会触达 Max |
| 超时 | 传输类 → `interrupted`；只读步骤允许重试一次 |
| Batch 部分失败 | 逐对象行保留，整体 `failed`/`partial`，不冒充成功 |
| 状态读取失败 | 快照失败只丢 diff（`warnings[] = snapshot_unavailable`），不判工作流失败 |
| 视觉失败 | `optional` 步骤 → 整体 `partial`，`isError:false` |
| 验证失败 | `verification_failed`，场景被读回反驳；附带 recovery，不重试 |

重试只允许一种组合：`retry:"transport"` + 传输码 + `errors.retryable` + 操作幂等
（`IDEMPOTENT_MUTATIONS`）。Clone/Delete/Create/相对变换一律 `retry_blocked:
non_idempotent_operation`，`execute_maxscript` / `execute_python` 任何声明都不重试。

一个实现细节：批量信封的顶层码可能是 `aborted`，真实原因在
`objects[].error.code`（例如 `bridge_disconnected`）。引擎会向嵌套里看一层，
把这种步骤判成 `interrupted` 而不是 `failed`，同时仍然拒绝重试（操作不幂等）。

**没有实现事务系统**：不回滚、不用 `theHold` 当数据库事务；失败后只重新读场景。

## 8. 阶段 G：工具描述优化（只改影响选择与参数的）

| 工具 | 加了什么 | 为什么必须加 |
| --- | --- | --- |
| `find_objects` | 默认是**模糊包含**匹配；名称不唯一，`count==1` 才能当身份 | 缺这句，Agent 会 `find_objects{name:"Box"}` 然后改到 `Box001/Box002` |
| `transform_object` | `value` 是**场景单位**、角度是度；省略 `objects` 会用上次选择 | 单位与"隐形操作对象"是最常见的两次误操作 |
| `select_objects` | 选择集**不是**持久状态 | 防止 Agent 写"我上一步选过了"这种不可靠假设 |
| `clone_objects` | 克隆**不幂等**，失败后先读场景再决定 | 直接影响"要不要重试"的判断 |

没动的工具描述保持原样——描述不是文案工作，改不到行为的地方不改。

## 9. 阶段 H：离线验收结果

`docs/WORKFLOW_ACCEPTANCE.md`：26 类场景，33 个测试函数
（`workflow_engine_test.py` Static 17 个、`workflow_scene_test.py` Offline 16 个）。

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| Static | 16 类 | 注入 `invoke`，不碰 socket，只证明引擎语义 |
| Offline | 15 类 | 真实 TCP（127.0.0.1 随机端口）+ `FakeScene`，穿过真正的 `MaxBridge` |
| Runtime | 0 类 | 本阶段不启动 Max；R1–R10 待执行清单已写在文档里 |

全量结果（本轮实跑）：

```text
batch_reliability_test           PASS
catalog_contract_test            PASS   (584/584 payload cases)
core_contract_test               PASS
core_tool_validation_test        PASS
error_protocol_test              PASS
image_result_test                PASS
object_reference_test            PASS
runtime_contract_test            PASS
runtime_server_test              PASS
scene_runtime_test               PASS
scene_state_test                 PASS
vision_result_test               PASS
core_evidence_audit              PASS
doc_alignment_audit              PASS   (386 tools / 8 categories / 353 commands)
workflow_engine_test             PASS
workflow_scene_test              PASS
offline_acceptance_test          PASS
registration_sync_test           FAIL   环境性：deployed tree drifted（见下）
scripts/verify.py                PASS   all integrity checks passed
scripts/test_e2e.py              PASS   end to end: all checks passed
test/static/ms_check.py src/ms   PASS   0 problem(s)
python -m compileall             PASS
python -m maxmcp --selftest-python  PASS
python -m maxmcp --list-profiles    PASS   core 58 / modeling 204 / lookdev 190 / animation 180 / pipeline 175 / full 386
```

**唯一失败项**：`registration_sync_test.py` 报
`deployed tree drifted from the repo ... ENU/CHS: mcp_bridge.ms, mcp_core.ms, mcp_objects.ms,
mcp_scene.ms, mcp_shading.ms`。这条在基线（`a8dfbfb`）上就已经失败，原因是我不能碰的
部署目录。本阶段改了 `src/ms/mcp_shading.ms`（给 `mcpAssignCreatedMat` 补 `success` 字段），
所以**合并后必须跑一次 `python scripts/install.py --yes`**，否则用户机器上仍是旧桥接，
`mat_create_*` 在 core 档位仍会被判 `missing_success`。

## 10. 阶段 I：文档与提交

新增文档：`AGENT_WORKFLOW_CAPABILITY.md`、`WORKFLOW_EXECUTION_MODEL.md`、
`SCENE_SNAPSHOT_DIFF.md`、`WORKFLOW_ACCEPTANCE.md`、本报告。
更新：`README.md`（386/分类表/档位表/工作流与快照说明）、`docs/tools.txt`（386 条）、
`docs/CHANGELOG.md`、`docs/ERROR_CODES.md`（新增第 6 节 8 个工作流错误码 + `missing_success`
判定收窄说明）、`docs/OVERNIGHT_ACCEPTANCE.md`（新增工作流组）。

一致性检查（全部实跑）：

| 检查 | 结果 |
| --- | --- |
| Git diff 审阅 | 26 个文件，+4285 / −91，无临时文件、无调试残留 |
| Python 语法 | `compileall` 通过；`offline_lint_helper` 无新增违规（21 条既有 `silent catch` 警告） |
| MAXScript 静态 | `ms_check.py` 0 problem；`mcp_shading.ms` 新增行沿用 CRLF（`.gitattributes` `*.ms -text`） |
| 工具数量 | 386（+2：`scene_snapshot`、`workflow_run`） |
| 重复工具 | 0（`verify.py` 与 `catalog_contract_test` 双向检查） |
| 旧工具兼容性 | 没有删除或重命名任何工具；`runtime` 的改动只把"误报失败"改回"成功"，对原本正确的结果无影响 |

**Git commit**：

- `086c4ec` — `feat: add agent scene workflow capabilities`（本阶段代码 + 文档 + 测试）

已知的两种小瑕疵，如实记录：

1. `086c4ec` 的 commit message 把 `workflow_scene_test.py` 的场景数写成 15，实为 16
   （`CHANGELOG` 已更正；commit message 未改写，避免对已提交内容做 amend）。
2. `git diff --check` 对 `mcp_shading.ms` 的新增行报 trailing whitespace，这是 CRLF 文件的
   假警报（该文件 730 行全部 CRLF，新增行与之一致；转成 LF 反而会破坏字节级部署）。

## 11. 已知风险与限制

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| R1 无真实 Max 证据 | 全部结论只到 S/O 级，假场景是"我们对 Max 的理解"的回声 | 按 `WORKFLOW_ACCEPTANCE.md` R1–R10 人工验收 |
| R2 部署漂移 | 仓库改了 `.ms`，用户机器上的桥接还是旧的 | 合并后 `scripts/install.py --yes` + `registration_sync_test.py` 复核 |
| R3 快照不可跨会话 | 基线在内存环形缓冲（8 份），进程重启失效 | 需要长期基线就自己存 `nodes` JSON |
| R4 验证依赖桥接可信 | 桥撒谎（例如 catch 吞掉错误）时验证看不出来 | 12 个验证器都读场景事实，仍无法超越桥接 |
| R5 快照字段有限 | 只有 8 个字段，UV/材质参数/灯光强度不在内 | 用对应 verification kind 或 `get_object_info` |
| R6 组织与保存导出无离线证据 | 层/组/父子、`scene_save*`、`export_*` 没有假场景 handler | 纳入下一阶段测试补齐 |
| R7 工作流可调用档位外工具 | core 档位下 `basic_scene` 仍会调 `vision_capture` | 有意设计（服务端编排），已在文档说明 |

## 12. 下一阶段的五项任务

1. **补第 12、15 步的离线证据**：给 `FakeScene` 加 `create_layer` / `assign_to_layer` /
   `group_objects` / `scene_save_as` 的 handler，让"组织"和"保存导出"也有 O 级证据，
   把能力矩阵里仅剩的两个空格填掉。
2. **执行 R1–R10 真实 Max 验收**：按 `docs/WORKFLOW_ACCEPTANCE.md` 第 3 节逐项跑，
   记录 Max 版本、日期与 PASS/FAIL；重点是 R5（中途关掉 Max）、R9（无图只降级）、
   R10（逃逸仓不重试）。
3. **把 `workflow_run` 的证据接进 Agent 的默认操作习惯**：在 MCP 的 instruction
   prompt 里加一条"修改类多步骤任务优先用 `workflow_run` 并声明 `verification`"，
   让 `scene_snapshot` 的前后对比成为默认动作，而不是可选动作。
4. **报告与诊断的收口**：`recovery` 目前只读 count/selection，考虑补
   `scene_readable=false` 时的"桥接自愈建议"（`bridge_restart` 是否值得建议尝试），
   并让 `workflow_run` 支持把逐步记录写进 MCP log 通知，便于长任务观察。
5. **补齐"快照基线可持久化"**：给出把 `scene_snapshot` 的 `nodes` 存盘/读回的约定
   （文件名、版本号、容差），使跨会话对比成为可能——但不要把它做成场景数据库。
