# Stage 9 审计：Animation / Rigging 结果真实性

日期：2026-11-03
基线：`bcd567d`（Stage 8 结束）
审计工具：`test/static/outcome_audit.py`（Static，不执行 MAXScript）

本文件回答一个问题：**这些 handler 返回的 `objects`，是"真的改了这些对象"，还是"请求里有这些对象"？**

## 1. 分级定义

| 等级 | 判据（纯静态） | 含义 |
| --- | --- | --- |
| `VERIFIED_RESULT` | `objects` 来自 `applied`，且列出 `failures` | 成功列表真实，失败可定位 |
| `SUSPICIOUS` | 只有一半：`objects=applied` 无 `failures`，或有 `failures` 但 `objects` 仍回显 | 结论可用，但缺一半信息 |
| `CONFIRMED_BUG` | `objects` 回显请求，且从不记录失败 | 全失败也报成功 |
| `SAFE_ECHO` | 回显，但结论由其他字段承担 | 需要具体证据才成立 |
| `UNKNOWN` | 认不出 `objects` / `applied` / `failures` 形状 | 需要人工读代码 |

`objects` 回显的识别形状：

```maxscript
mcpPair p "objects" (for n in nodes collect n.name)
```

`applied` 的识别形状：

```maxscript
mcpPair p "objects" applied     -- applied 只在成功分支 append
```

## 2. 全量结果（`python test/static/outcome_audit.py`）

```text
result integrity (handlers that report an object list):
  CONFIRMED_BUG     6
  SUSPICIOUS        5
  SAFE_ECHO         0
  VERIFIED_RESULT  26
  UNKNOWN           0
```

CONFIRMED_BUG 从 Stage 8 结束时的 23 降到 6；VERIFIED_RESULT 从 8 升到 26。

## 3. 23 项逐条决定

### 3.1 已修复（17 项）

| Tool | Handler | Input | Operation | Success | Failure | 结果字段 | Catch | 决定 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `anim_bake` | `mcpH_anim_bake` | `objects` | `animate on` 逐帧写 key | `startFrame` 处存在 key | 该帧无 key | `objects`/`failures`/`keysWritten` | 无 | 修复 |
| `anim_clear_animation` | `mcpH_anim_clear_animation` | `objects` | `deleteKeys #all` | 原本有 key 且清空后为 0 | 清除后仍有 key 或抛错 | `objects`/`skipped`/`failures` | 无（改为记录） | 修复 |
| `anim_offset_keys` | `mcpH_anim_offset_keys` | `objects` | 逐 key 改 `k.time` | 有 key 且全部移动成功 | 任一 key 移动失败 | `objects`/`skipped`/`failures` | 记录 | 修复 |
| `anim_scale_keys` | `mcpH_anim_scale_keys` | `objects` | 逐 key 缩放时间 | 同上 | 同上 | 同上 | 记录 | 修复 |
| `anim_set_controller` | `mcpH_anim_set_controller` | `objects` | 替换 controller | **回读 `classof` 等于请求类** | 回读类不符（Max 拒绝时保留旧 controller） | `objects`/`failures` | 记录 | 修复 |
| `constraint_remove` | `mcpH_constraint_remove` | `objects` | 换回 bezier | **回读 controller 是 bezier_xxx** | 仍是约束 | `objects`/`failures` | 记录 | 修复 |
| `constraint_surface` | `mcpH_constraint_surface` | `objects` | 两次构造 + 绑目标 | **回读 `sc.surface.name == target`** | 建出但未绑上（半成品） | `objects`/`failures` | 记录 | 修复（单独处理，未套模板） |
| `rig_ik_enable` | `mcpH_rig_ik_enable` | `objects` | 置 `ikEnabled` | **回读为 true** | 回读不符 | `objects`/`failures` | 记录 | 修复 |
| `rig_ik_disable` | `mcpH_rig_ik_disable` | `objects` | 置 `ikEnabled=false` | **回读为 false** | 回读不符 | `objects`/`failures` | 记录 | 修复 |
| `rig_morpher_add` | `mcpH_rig_morpher_add` | `objects` | `addModifier Morpher()` | **回读 `mcpGetMorpherMod != undefined`** | 加完仍没有 | `objects`/`failures` | 记录 | 修复 |
| `rig_morpher_add_target` | `mcpH_rig_morpher_add_target` | `objects` | 加 morph target | 不在 `failed` | 在 `failed` | `objects`/`failures` | 记录 | 修复 |
| `rig_set_bone_size` | `mcpH_rig_set_bone_size` | `objects` | 设 width/height | 两次赋值都没抛 | 任一抛错 | `objects`/`failures` | 记录 | 修复 |
| `rig_skin_add` | `mcpH_rig_skin_add` | `objects` | `addModifier Skin()` | **回读 `mcpGetSkinMod != undefined`** | 加完仍没有 | `objects`/`failures` | 记录 | 修复 |
| `rig_skin_add_bone` | `mcpH_rig_skin_add_bone` | `objects` | `skinOps.addBone` | 不在 `failed` | 无 Skin / 骨头不在 | `objects`/`failures` | 记录 | 修复 |
| `rig_skin_remove_bone` | `mcpH_rig_skin_remove_bone` | `objects` | `skinOps.removeBone` | 不在 `failed` | 同上 | `objects`/`failures` | 记录 | 修复 |
| `rig_skin_set_weight` | `mcpH_rig_skin_set_weight` | `objects` | `skinOps.setWeight` | 不在 `failed` | 无 Skin / 骨头不在 / 写入抛错 | `objects`/`failures` | 记录 | 修复（未回读权重，见 §5） |
| `rig_skin_set_vertex_weights` | `mcpH_rig_skin_set_vertex_weights` | `objects` | 批量 `setWeight` | 不在 `failed` | 任一根骨失败 | `objects`/`failures` | 记录 | 修复 |

Stage 8 已修的 8 项（`anim_delete_keys`、`anim_ease`、`constraint_link`、`constraint_look_at` / `position` / `path` / `orientation`、`rig_skin_auto_weight`）本阶段复查通过，见 §6。

### 3.2 暂缓（6 项，CONFIRMED_BUG 保留）

| Tool | Handler | 为什么暂缓 |
| --- | --- | --- |
| `anim_set_interpolation` | `mcpH_anim_set_interpolation` | 可回读 `k.inTangentType`，但与 `anim_ease` 共用 `mcpMapTangent` 映射；一次改两个入口容易产生不一致，排在下一轮一起改 |
| `anim_set_out_of_range` | `mcpH_anim_set_out_of_range` | 没有可靠的读回 API 确认 out-of-range 类型（`setOutOfRangeType` 无对应 getter），只能靠写入是否抛错 |
| `constraint_set_weight` | `mcpH_constraint_set_weight` | `ctrl.getWeight ti` 在不同约束类型上的返回语义未在项目中验证过；按任务要求"不确定 API 先查已有用法"，项目里没有 getWeight 的先例 |
| `ctrl_add_list` | `mcpH_ctrl_add_list` | 三层嵌套 `catch`，且列表 controller 的 `count` 变化不能直接当作"层加上了"（Max 可能合并同类层） |
| `rig_morpher_set_value` | `mcpH_rig_morpher_set_value` | 可回读 `mm[channel].value`，但 `animate on` + `at time` 的组合在离线无法验证读回时机 |
| `rig_set_ik_chain` | `mcpH_rig_set_ik_chain` | `preferredAngle` / `swivelAngle` 是否可读回未验证；写入对象可能不是 IK 节点 |

这 6 项**保留在 CONFIRMED_BUG**，审计每次都会打印，不是遗忘。

### 3.3 6 项"无结论声明"（不在 23 项内，但同属本阶段范围）

| Tool | 现状 | 决定 |
| --- | --- | --- |
| `anim_bake_range` | 原本只有 `roots`/`objectCount`/`keysWritten`，运行时读不出结论 | **已修**：新增 `objects`/`failures`，与 `anim_bake` 同一判定 |
| `anim_play` | `try (playAnimation) catch()`，无回读手段 | 暂缓：无法确认"播放已开始"，只能报执行 |
| `anim_play_preview` | `makePreview` 失败时 `output` 为空 | 保留：`output` 为空 + `message` 已是可读信号，但运行时读不出，属已知缺口 |
| `ctrl_wire` | 已有 `wired` 布尔，但不在回执表 | 保留：`wired` 语义清晰，可作为下一轮补进回执字段 |
| `rig_ik_solver` | 有 `goal != undefined` 判断，但无结论字段 | 保留：`goal` 为空即失败，语义已表达在 `message` |
| `rig_spline_ik` | 同上 | 保留：同上 |

## 4. 语义约定（阶段 B）

六个概念严格分开，不互相替代：

| 概念 | 含义 | 由谁表达 |
| --- | --- | --- |
| `success` | 是否按契约完成 | 运行时从 `failures` 推 |
| `changed` | 场景是否实际变化 | 独立；成功 no-op 也是 `false` |
| `applied` | 真正改了的对象 | `objects` |
| `skipped` | 无需操作（合法 no-op） | `skipped` |
| `failed` | 执行失败 | `failures` |
| `verification` | 是否独立读回 | `verification.performed/passed` |

关键三条：

1. **全部 skipped 是成功**：`{objects: [], failures: []}` → `success: true`，因为"我检查过，没有失败"。
2. **什么都不说是未知**：`{objects: []}`（无 `failures` 键）→ `success: false` + `missing_success`。
3. **`changed` 不能当 `success`**：`{changed: true, message: "OK"}` 仍然是 `missing_success`。

`test/static/result_semantics_test.py` 把这三条钉住了。

## 5. 权重回读：为什么没有做

`skinOps.getVertexWeight` / `getVertexWeightBone` 在项目里已有使用（`rig_skin_weight_table`），理论上可以回读。

没有直接接进 `rig_skin_set_weight` 的原因：

1. `getVertexWeightBone` 返回的 index 与 `mcpFindBoneIndex` 的语义是否一致，**没有真机验证**；
2. 如果两者不一致，回读会产生**误报失败**——比"未验证"更糟；
3. 任务要求"无法可靠读取时应明确标记 verification unavailable"，而不是猜。

因此当前状态是：`objects` 只含写入未抛错的对象，`verification.performed` 仍是 `false`。
回读方案列入 §7 的下一阶段任务。

## 6. Stage 8 已修项目的复查（阶段 E）

| Tool | 复查结论 | 证据 |
| --- | --- | --- |
| `constraint_link` | 正确 | 逐对象 `try/catch` 记录异常文本，`objects=applied` |
| `constraint_look_at` | 正确 | 同上；`upNode` 绑定失败仍算成功（upNode 是可选参数，失败不影响主目标） |
| `constraint_position` | 正确 | 同上 |
| `constraint_path` | 正确 | 同上；`path` 赋值在 try 内，失败会进 `failures` |
| `constraint_orientation` | 正确 | 同上 |
| `constraint_surface` | **本阶段重写** | 原实现能建出 controller 但不保证绑上目标，留下半成品；现在回读 `sc.surface.name` |
| `anim_delete_keys` | 正确 | 无控制器 / 无关键帧 / 删除失败三种情况分开 |
| `anim_ease` | 正确 | 无控制器 / 无关键帧 / 切线被拒三种情况分开 |
| `rig_skin_auto_weight` | 正确 | 回读前的 `applied` 只在 `skinOps.autoWeight` 未抛错时 append |

## 7. 可追踪性（阶段 G）

`outcome_audit.py` 现在输出五级分布，并逐条打印 `CONFIRMED_BUG` 与 `SUSPICIOUS` 的判定理由（含裸 `catch()` 计数）。

新增的硬门禁只有一条：

```python
core_bad = [name for name, _ in graded[CONFIRMED_BUG] if name in CORE_TOOLS]
assert not core_bad
```

理由：`core` 是默认档位，那里出现"回显冒充成功"是**活着的 bug**；其余 6 项是 backlog，
用门禁逼它们清零只会让人加 `success: true` 绕过去。

## 8. 这批审计**不**证明什么

- 所有结论都是 Static 级：只读代码，没有执行 MAXScript。
- `mcpGetSkinMod` / `mcpGetMorpherMod` / `classof controller` 在真机上的行为未验证。
- 回读语义（`sc.surface.name`、`node.ikEnabled`）依赖 Max 的属性名，跨版本可能不同。
- 权重是否真的写对，仍然没有被验证（见 §5）。
