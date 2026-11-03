# Stage 9 最终报告：Animation / Rigging 结果真实性

日期：2026-11-03
分支：`main`
提交：`bb6b833` — `fix: make animation and rigging outcomes reliable`
基线：`bcd567d`（Stage 8 结束）

## 1. 审计总览

Stage 8 结束时，`outcome_audit.py` 报告 **23 个 handler 把请求当结果回显**。本阶段逐个读了这 23 个的真实实现，另外发现 6 个"完全没有可读结论字段"的同族工具。

| 项 | 数量 |
| --- | --- |
| 原始清单（回显） | 23 |
| 本阶段修复 | **17** |
| 保留（有证据说明不是缺陷） | 0 |
| 暂缓（写明原因） | 6 |
| 额外修复（无结论声明一类） | 1（`anim_bake_range`） |
| 新发现的问题 | 3（见 §1.1） |

审计分级（`python test/static/outcome_audit.py`）：

```text
result integrity (handlers that report an object list):
  CONFIRMED_BUG     6      (23 at Stage 8)
  SUSPICIOUS        5
  SAFE_ECHO         0
  VERIFIED_RESULT  26      (8 at Stage 8)
  UNKNOWN           0
```

### 1.1 新发现的三件事

1. **`constraint_surface` 会留下半成品。** 它会先 `surface()` 再退到 `surface_constraint()`，两种都可能建出 controller，但 `sc.surface = targetNode` 失败时不回滚——对象上于是挂着一个没绑定目标的约束，而旧代码照样报成功。这是 23 项里唯一"操作部分生效"的案例。
2. **`anim_bake` 的 `keysWritten` 是真的回读，但没人用它判失败。** 全部对象都没写出 key 时仍然返回 `msg.anim_baked`。
3. **`rig_skin_*` 系列早就知道哪些对象失败了**（它们有 `failed` 列表），却仍然把请求列表写进 `objects`。这类不是"不知道"，是"知道了但输出错了"。

## 2. 每个工具的决定

### 2.1 修复（17 项）

| Tool | 原问题 | 修改内容 | 成功语义 | 验证方式 | 状态 |
| --- | --- | --- | --- | --- | --- |
| `anim_bake` | `objects` 回显；`keysWritten=0` 不报错 | 逐对象检查 `startFrame` 处是否有 key | 至少一个属性在起始帧有 key | 回读 `getKey` | 完成 |
| `anim_clear_animation` | 三层静默跳过，回显 | `applied`/`skipped`/`failures` 三态 | 原本有 key 且清空后为 0 | 回读 `ctrl.keys.count` | 完成 |
| `anim_offset_keys` | 无 key 也算成功 | 三态；无 key → skipped | 有 key 且全部移动未抛错 | 逐 key 收集 | 完成 |
| `anim_scale_keys` | 同上 | 同上 | 同上 | 同上 | 完成 |
| `anim_set_controller` | 裸 `catch`，回显请求的类 | 回读实际 controller 类并比较 | 回读类 == 请求类 | `classof (mcpGetAnimController ...)` | 完成 |
| `constraint_remove` | 裸 `catch`，回显 | 回读 controller 类 | 回读为 `bezier_*` | 同上 | 完成 |
| `constraint_surface` | 半成品 + 回显 | 回读绑定目标名 | `sc.surface.name == target` | 回读 `sc.surface` | 完成 |
| `rig_ik_enable` | 回显 `ikEnabled: true`（请求值） | 回读 `node.ikEnabled` | 回读为 true | 回读 | 完成 |
| `rig_ik_disable` | 同上 | 同上 | 回读为 false | 回读 | 完成 |
| `rig_morpher_add` | 裸 `catch` | 回读 `mcpGetMorpherMod` | Morpher 存在 | 回读 | 完成 |
| `rig_morpher_add_target` | 有 `failed` 但 `objects` 回显 | 由 `failed` 反推 `applied` | 不在 `failed` | 已有失败列表 | 完成 |
| `rig_set_bone_size` | 裸 `catch` | 收集抛错的赋值 | 两次赋值都成功 | 控制流 | 完成 |
| `rig_skin_add` | 裸 `catch` | 回读 `mcpGetSkinMod` | Skin 存在 | 回读 | 完成 |
| `rig_skin_add_bone` | 有 `failed` 但 `objects` 回显 | 由 `failed` 反推 | 不在 `failed` | 已有失败列表 | 完成 |
| `rig_skin_remove_bone` | 同上 | 同上 | 同上 | 同上 | 完成 |
| `rig_skin_set_weight` | 同上，且无权重回读 | 由 `failed` 反推 | 写入未抛错且骨头存在 | 失败列表（未回读权重，见 §3.3） | 完成 |
| `rig_skin_set_vertex_weights` | 同上 | 同上 | 每一根骨都写成功 | 同上 | 完成 |

### 2.2 暂缓（6 项，仍然是 CONFIRMED_BUG）

| Tool | 原因 |
| --- | --- |
| `anim_set_interpolation` | 可回读，但与 `anim_ease` 共用 `mcpMapTangent`；一次改两个入口容易让两者判定不一致，留到同一轮一起改 |
| `anim_set_out_of_range` | `setOutOfRangeType` 没有对应的 getter，无法回读，只能依据写入是否抛错 |
| `constraint_set_weight` | `ctrl.getWeight ti` 在不同约束类型上的行为未验证，项目里没有先例 |
| `ctrl_add_list` | 三层嵌套 catch，且 `lst.count` 增加不能证明"层被采纳"（Max 可能合并同类层） |
| `rig_morpher_set_value` | 可回读 `mm[channel].value`，但 `animate on` + `at time` 的读回时机离线无法确认 |
| `rig_set_ik_chain` | `preferredAngle` / `swivelAngle` 是否可读回未验证；写入对象可能不是 IK 节点 |

这 6 项在审计输出里带原因打印，不是遗漏。

## 3. 结果真实性

### 3.1 数字

| 指标 | Stage 8 结束 | 现在 |
| --- | --- | --- |
| 输入回显（CONFIRMED_BUG） | 23 | **6** |
| 已确认安全的回显（SAFE_ECHO） | 0 | 0 |
| 真实成功列表（VERIFIED_RESULT） | 8 | **26** |
| 未知语义（UNKNOWN） | 0 | 0 |
| 仍存在静默失败风险 | 23 | **6** |

### 3.2 六概念分离

| 概念 | 表达 | 不与谁混 |
| --- | --- | --- |
| `success` | 运行时由 `failures` 推 | 不等于 `changed` |
| `changed` | 独立字段 | 成功的 no-op 也是 `false` |
| `applied` | `objects` | 不含 skipped / failed |
| `skipped` | `skipped` | 不是失败，也不是"做了" |
| `failed` | `failures` | 一旦非空，整体 `success=false` |
| `verification` | `performed` / `passed` | 未执行时 `passed=null`，不是 `false` |

`test/static/result_semantics_test.py` 用 10 个用例钉住这些边界，其中三条最关键：

```text
{objects: [], failures: []}          -> success=true,  changed=false   (全部 no-op)
{objects: []}  (无 failures 键)      -> success=false, missing_success (什么都没说)
{changed: true, message: "OK"}       -> success=false, missing_success (changed 不是结论)
```

### 3.3 权重回读：明确的能力边界

`rig_skin_set_weight` 现在能报"写入未抛错"，但**不能**证明权重真的变成了请求值。

- 项目里已有 `skinOps.getVertexWeight` / `getVertexWeightBone` 的用法（`rig_skin_weight_table`）。
- 没有接进来，是因为 `getVertexWeightBone` 返回的索引与 `mcpFindBoneIndex` 的语义是否一致**没有真机验证**；一旦不一致，回读会误报失败，比"未验证"更糟。
- 因此该工具的 `verification.performed` 仍是 `false` —— 如实表示"没有独立证据"，而不是假装验证过。

## 4. 自动化测试

### 4.1 执行命令与原始结果

```text
$ python test/static/result_semantics_test.py
result semantics: all checks passed

$ python test/static/outcome_audit.py
outcome audit: mutating=299 batched=6 audited=293 declared=282 missing=11 unreadable=0
core profile: mutating=36 missing=0
result integrity (handlers that report an object list):
  CONFIRMED_BUG     6
  SUSPICIOUS        5
  SAFE_ECHO         0
  VERIFIED_RESULT  26
  UNKNOWN           0
```

全量静态/离线测试（18 个文件，逐个执行）：

| 文件 | 结果 | 等级 |
| --- | --- | --- |
| `catalog_contract_test` | PASS | Static |
| `core_contract_test` | PASS | Static |
| `runtime_contract_test` | PASS | Static |
| `runtime_server_test` | PASS | Static |
| `scene_runtime_test` | PASS | Static |
| `error_protocol_test` | PASS | Static |
| `doc_alignment_audit` | PASS | Static |
| `offline_lint_helper` | PASS | Static |
| `outcome_audit` | PASS | Static |
| `outcome_declaration_test` | PASS | Static |
| `param_contract_audit` | PASS | Static |
| `i18n_audit` | PASS | Static |
| `result_semantics_test`（新增） | PASS | Static |
| `object_state_test` | PASS | Offline |
| `workflow_engine_test` | PASS | Static |
| `workflow_scene_test` | PASS | Offline |
| `offline_acceptance_test` | PASS | Offline |
| `batch_reliability_test` | PASS | Static |

```text
$ python scripts/verify.py
all integrity checks passed

$ python test/static/ms_check.py src/ms
0 problem(s)
```

### 4.2 覆盖了哪些场景

| 场景 | 覆盖位置 |
| --- | --- |
| 全部 applied | `result_semantics_test.check_applied_only_is_success` |
| 部分失败 | `check_any_failure_is_not_success`、`check_partial_success_is_not_reported_as_success` |
| 全部 skipped（no-op） | `check_all_skipped_is_a_successful_noop` |
| skipped 不能单独定结论 | `check_skipped_is_not_an_outcome_claim` |
| `changed` 与 `success` 独立 | `check_changed_is_independent_of_success` |
| 未验证 ≠ 验证失败 | `check_verification_unavailable_is_not_passed` |
| summary 计数 | `check_batch_summary_counts` |
| 失败行不能标 verified | `check_verification_counts_only_successful_rows` |
| 无控制器 / 无关键帧 / 写入失败 | 无 Runtime 证据（见 §4.3） |

### 4.3 **没有** Runtime 证据

本阶段**没有启动 3ds Max**，因此以下行为全部是"代码这么写"，不是"真机如此"：

- `classof (mcpGetAnimController node propName)` 在真实场景里的返回值；
- `sc.surface.name` 能否读到绑定的对象名；
- `node.ikEnabled` 是否可读（不可读时会回退到"写入是否抛错"）；
- `mcpGetSkinMod` / `mcpGetMorpherMod` 在各类对象上的行为。

这些是 Static 证据，报告里不当作真机结论。

## 5. 兼容性

| 项 | 是否变化 | 说明 |
| --- | --- | --- |
| MCP Tool Schema | **否** | `src/python/` 完全没动（`git diff --stat HEAD~1 -- src/python/` 为空） |
| 工具名称 | **否** | 386 个工具、58 个 core，与 Stage 8 一致 |
| 公开参数 | **否** | 每个工具的参数个数未变 |
| 返回结构 | **部分变化** | 见下 |

返回结构的变化都是**新增字段**或**字段含义修正**：

| 变化 | 工具 | 影响 |
| --- | --- | --- |
| 新增 `failures` | 17 个已修工具 | 旧调用方忽略未知字段即可 |
| 新增 `skipped` | `anim_clear_animation`、`anim_offset_keys`、`anim_scale_keys` | 同上 |
| 新增 `objects` / `failures` | `anim_bake_range` | 它原本没有可读结论字段 |
| `objects` 含义 | 全部 17 个 | 从"请求里的对象"变成"真正改了的对象"——**这是本阶段的目的** |

`objects` 语义变化对旧 Agent 的影响：以前它会读到"我请求的全部对象"，现在只读到"成功的那些"。如果一个 Agent 依赖 `objects` 做后续操作，现在会**跳过失败的对象**——这正是想要的，但它需要同时检查 `failures` 才知道发生了什么。

## 6. Git

```text
分支      main
基线      bcd567d  (Stage 8)
最终 HEAD bb6b833  (本阶段)
工作区     clean
```

提交：

- `bb6b833` — `fix: make animation and rigging outcomes reliable`（6 文件）

改动统计：`mcp_animation.ms` +139 行、`mcp_rigging.ms` +108 行、`outcome_audit.py` 重构分级、新增 `result_semantics_test.py`、新增审计文档、CHANGELOG。

行尾与编码：两个 `.ms` 保持全 CRLF、无 BOM、无孤立 LF（已逐字节核对）。

## 7. 后续建议

1. **权重回读（最高价值）**：先在真机确认 `getVertexWeightBone` 与 `mcpFindBoneIndex` 的索引语义一致，再把 `rig_skin_set_weight` 升级成"写入 + 回读 + 比对"。不一致时降级为 `verification_unavailable`，不要报失败。
2. **剩余 6 项**：`anim_set_interpolation` 与 `anim_ease` 一起改（共用映射）；`constraint_set_weight` 先确认 `getWeight` 的返回语义；其余四项需要各自的判断依据。
3. **`SUSPICIOUS` 的 5 项**（`anim_set_key`、`anim_set_keys`、`ctrl_*`）：它们的 `objects` 已经是真实 applied，缺的是"部分失败时指出哪一个"。补 `failures` 即可升级到 `VERIFIED_RESULT`。
4. **把 `objects` 的语义写进工具描述**：现在描述里没有说明"这是成功列表，不是请求列表"。这是 Agent 唯一能看到的契约。
5. **真机验收清单**：至少覆盖"锁定控制器上的 `anim_set_controller`"、"surface 约束绑定失败"、"权重写入后回读"三条——它们对应本阶段最依赖回读语义的三处。
