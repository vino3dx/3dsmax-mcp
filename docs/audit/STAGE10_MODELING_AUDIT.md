# Stage 10：Modeling / Modifier 结果真实性审计

审计对象：Catalog 中 `modeling`（83）与 `objects`（61）两个类别的全部 **mutating** 工具，
共 **126** 个（其中 73 个建模、53 个对象操作；只读工具不在本表）。
审计方式：`test/static/outcome_audit.py` + 逐个读 `src/ms/*.ms` 的真实实现；
分级沿用 Stage 9 的五档：`CONFIRMED_BUG` / `SUSPICIOUS` / `SAFE_ECHO` / `VERIFIED_RESULT` / `UNKNOWN`。

本文件记录**每个工具的决定**，以及结论的代码证据。
最终报告见 `docs/audit/STAGE10_FINAL_REPORT.md`。

---

## 0. 先说三个结论

1. **审计工具自身有一个假通过**。`_keys()` 会跟随 `mcp*` 辅助函数，并把它发出的所有键当作
   **顶层**结论字段。`mcpNodeInfo` 返回的节点字典里恰好有 `layer`，而 `layer` 是运行时的
   回执字段之一，于是 `create_circle`、`create_line`、`boolean_operation`、`proboolean`
   被审计判为"已声明结论"，**实际运行时它们是 `missing_success`**——对象建出来了，工具却说
   "没有任何证据"。这是**假失败**，方向和 Stage 9 修的假成功相反，危害同样真实：Agent 会重试
   创建，留下重复对象。
2. **回显不只发生在 `objects` 上**。Stage 9 的检测正则只匹配 `"objects"`，而
   `align_objects` 用 `aligned`、`attach_objects` 用 `attached`、`parent_objects` 用
   `children` 做同样的事：把请求列表当结果。`_RECEIPT_KEYS` 里有这三个键，所以运行时读它们
   并判成功。全部修复。
3. **一行两个语句**。`mcpPair p "success" true  mcpPair p "name" nm` 在 MAXScript 里会被解析成
   一次 7 个参数的调用，运行时报 "Wrong number of arguments"。这类行有 **34 处**，分布在
   `mcp_lights` / `mcp_render` / `mcp_shading` / `mcp_modifiers` 四个文件，是之前批量插入
   `success: true` 时留下的。仓库从未真正执行过 MAXScript，所以静态检查也没发现。已全部拆分，
   并在 `ms_check.py` 增加第 5 节检查。

---

## 1. 分级结果（本阶段结束时）

| 类别 | mutating 工具 | CONFIRMED_BUG | SUSPICIOUS | SAFE_ECHO | VERIFIED_RESULT | UNKNOWN |
| --- | --- | --- | --- | --- | --- | --- |
| modeling | 73 | **0** | **0** | 5 | **68** | 0 |
| objects | 53 | **0** | **0** | 29 | 16 | 8 |

- `UNKNOWN` 的 8 个都不是缺陷：`delete_objects`（per-object + Python 侧回读）、
  `rename_object`（`renamed` 布尔回执）、`group_objects`（`group` 名称回执）、
  `proboolean`（`success` + 面数变化）、`select_all` / `select_by_superclass`（无 per-object
  语义），以及两个只读性质的 `proboolean`/`poly_get_*` 分支。它们的判定字段不在
  `applied`/`failures` 形状里，分级器按设计不认。
- `SAFE_ECHO` 的 29 个主要是 `create_*`：它们现在返回 `success` + `failures`，判定靠
  `failures`，`object` 只是附带的真实节点快照。

---

## 2. 逐工具决定

### 2.1 基础几何创建（19 个工具，2 个 handler）

| Tool | Handler | 原问题 | 决定 | 现在的证据 |
| --- | --- | --- | --- | --- |
| `create_box` / `sphere` / `cylinder` / `cone` / `torus` / `teapot` / `plane` / `tube` / `pyramid` / `hedra` / `geosphere` / `chamferbox` / `capsule` / `create_primitive` | `mcpH_create_primitive`（`mcp_objects.ms:89`） | 尺寸用 `setProperty` 写入后不核对：Max 夹取/忽略时 `failures` 为空，`success` 仍为 true；名称被 Max 改成唯一变体时也不说 | **修复** | `mcpSetPropVerified()` 写后读回并比较（容差 1e-4），不一致进 `failures`；名称变化进 `warnings`（对象确实建成了，不应判失败）；`isValidNode` 验证构造结果 |
| `create_circle` / `rect` / `ellipse` / `ngon` / `donut` / `arc` / `helix` / `text` | `mcpH_create_spline`（`mcp_objects.ms:153`） | **没有任何结论字段**（只有嵌套的 `object`），运行时判 `missing_success`；所有参数写入 `try(...)catch()` | **修复** | 新增 `success` / `failures` / `warnings`；`text` 与每个尺寸参数写后读回；名称冲突进 `warnings` |
| `create_line` | `mcpH_create_line`（`mcp_objects.ms:211`） | 同上；且 `addKnot` 逐个吞错，点没落地也报 "Created" | **修复** | 逐点 catch 收集 `failures`，并把 `numKnots` 与请求点数比较；闭合、名称、位置分别核对 |
| `rig_create_bone` / `rig_create_dummy` / `rig_create_point_helper` | `mcp_rigging.ms:51 / 131 / 175` | 同一类：只有嵌套 `object`，无判定字段（被审计的嵌套假通过掩盖） | **修复** | `success` + `failures`；宽高/尺寸/位置写后读回；`isValidNode` 验证 |

### 2.2 对象操作

| Tool | Handler | 原问题 | 决定 | 现在的证据 |
| --- | --- | --- | --- | --- |
| `align_objects` | `mcp_objects.ms:391` | `aligned` = 请求回显 + 3 处裸 catch：全部对象被拒也报成功 | **修复** | 逐对象；位置用 `distance` 回读、缩放在 0.001 容差内比较；`aligned` 只含场景接受的，`failures` 点名拒绝的 |
| `parent_objects` | `mcp_objects.ms:651` | `children` = 请求回显；无任何 catch，第 2 个对象出错时第 1 个已被改而整体报错 | **修复** | 逐对象 `try`；写后 `n.parent == parent` 回读；`children` 只含真正挂上的 |
| `attach_objects` | `mcp_objects.ms:1223` | `convertToSplineShape` 的失败被吞，随后对网格 `attach` 必然失败也照收，`attached` 仍列全部 | **修复** | 目标不是 Shape 时先转换，转换失败直接 `mcpFail`；逐对象比较 `numSplines` 是否增加 |
| `detach_elements` | `mcp_objects.ms:1269` | `detached` 只是拼出来的名字，不证明节点被创建；裸 catch | **修复** | 用 `objects.count` 增长作为"真的分离出节点"的证据，未增长进 `failures`；名称按场景解析 |
| `boolean_operation` | `mcp_objects.ms:1323` | `try (result = boolean2 ...) catch()` 吞掉失败后仍返回 `result` 节点快照；且**没有判定字段**（运行时 `missing_success`） | **修复** | 逐操作数 catch 收集 `failures`；`isValidNode` 检查操作数是否被消耗；新增 `success` / `facesBefore` / `facesAfter` / `changed` |
| `proboolean` | `mcp_objects.ms:1367` | 无判定字段（`missing_success`）；面数变化未知 | **修复** | `success: true`（失败路径已 `mcpFail`）+ `changed` + `operandsRemaining` |
| `clone_objects` | `mcp_objects.ms:1098` | 内层 `for k` 无 try：第 2 份抛错时第 1 份已建，调用整体报错，副本无人知晓 | **修复** | 每份 copy 单独 try，`isValidNode` 验证；`failures` 记到"对象 #N"粒度 |
| `array_objects` | `mcp_objects.ms:1140` | 网格分支把"被移动的原对象"写进 `created`；复制失败无记录 | **修复** | `created` 只含真实副本，原对象进 `moved`；每次 copy 单独 try + `failures` |
| `scatter_objects` | `mcp_objects.ms:586` | 每份 copy 无 try；表面模式射线打空时**静默留在空中** | **修复** | 逐份 try + `isValidNode`；`region=surface` 时未命中表面直接记失败，不再假装摆放成功 |
| `transform_object` / `select_objects` / `mat_assign` | — | 已是 per-object / reconcile，Python 侧回读 | **保留** | `batch._verify_transform` / `_reconcile_selection` / `_reconcile_applied` 已存在，本阶段未动 |
| `hide/freeze/unhide/unfreeze` / `mirror` / `set_pivot` / `reset_transform` / `snap` / `unparent` / `spline_set_points` / `group` / `ungroup` / `open_group` / `close_group` / `delete_objects` / `rename_object` | — | Stage 5/6 已修 | **保留** | 见 `STAGE5_STATE_READBACK_REPORT.md` |

### 2.3 Modifier

| Tool | Handler | 原问题 | 决定 | 现在的证据 |
| --- | --- | --- | --- | --- |
| `mod_add` + 30 个 `mod_*` 预设包装 | `mcp_modifiers.ms:115` | `addModifier` 之后不检查栈；`mcpApplyModParams` 的返回值被丢弃且函数本身返回未定义的 `ok`、吞掉全部 `setProperty` 错误 → 参数全被拒也报 `applied` | **修复** | `n.modifiers.count` 必须增加，否则 `mcpFail`；`mcpApplyModParams` 改为返回"没生效的参数列表"（写后 `getProperty` 比较），非空即该对象失败 |
| `mod_set_param` | `mcp_modifiers.ms:265` | `value` 在 schema 里声明为字符串并承诺"类型自动转换"，但 handler 把字符串直接交给 `setProperty` → 数值参数必然失败；且不核对最终值 | **修复** | 新增 `mcpCoerceValue`（`"true"/"false"` → bool，可解析为数字 → float）；复用 `mcpApplyModParams` 做写后读回 |
| `mod_set_params` | `mcp_modifiers.ms:300` | 同 `mod_add` 的参数问题 | **修复** | 参数列表里任一未生效 → 该对象失败，并报出第一个 |
| `mod_remove` | `mcp_modifiers.ms:169` | `deleteModifier` 后不核对栈是否变小 | **修复** | `n.modifiers.count` 必须减少，否则失败；不存在时仍然报失败（不是合法 no-op） |
| `mod_set_sub_object_selection` | `mcp_modifiers.ms:510` | 三处 `try(...)catch()` 吞错后无条件 `append applied` | **修复** | 回读 `subobjectLevel`；选择集写后用 `selectedVerts/Edges/Faces/CP` 的 count 证明落地 |
| `mod_reorder` / `mod_enable` / `mod_disable` / `mod_rename` / `mod_toggle` / `mod_collapse` | — | 已有 `applied` + `failures`（`mod_collapse`/`mod_toggle` 另有 before/after 字段） | **保留** | 分级为 `VERIFIED_RESULT` / `SAFE_ECHO` |
| `model_extrude_spline` / `model_lathe_spline` / `model_sweep` | `mcp_modifiers.ms:566 / 601 / 671` | `addModifier` 无栈校验 | **修复** | 栈计数必须增加 |

### 2.4 Editable Poly

| Tool | Handler | 原问题 | 决定 | 现在的证据 |
| --- | --- | --- | --- | --- |
| 16 个拓扑操作：`extrude/inset/bevel/bridge/cap/slice/connect/chamfer(edges,verts)/weld/target_weld/remove_verts/delete_faces/triangulate/quadify` | `mcp_poly.ms` | `applied` 只代表"调用没抛异常"，拓扑是否变化未知（重合点焊接、不可连接的边） | **修复** | 每个对象记录调用前后 `getNumFaces`/`getNumVerts`，未变化进 `unchanged`（**不判失败**——no-op 是合法语义）；`applied`/`failures` 不变 |
| `poly_subdivide` / `poly_optimize` / `poly_relax` | `mcp_poly.ms:1298 / 1331 / 1364` | `addModifier` 无栈校验；`poly_relax` 无 `failures` | **修复** | 栈计数必须增加 |
| `poly_select_faces` / `poly_loop_select` / `poly_ring_select` | `mcp_poly.ms:573 / 1099 / 1139` | 失败时把 `"ERROR name: ..."` **字符串塞进 `results`**，运行时把非空列表读成成功 → 全失败也报成功 | **修复** | 失败进独立的 `failures`；`objects`/`results` 只含成功行；`applied` 记录成功对象 |
| `poly_get_*` / `poly_info` | — | 只读 | **保留** | 不参与 mutating 审计 |
| 其余 `poly_*`（`set_vertex` / `move_vertices` / `assign_material_id` / `set_smoothing` / `auto_smooth` / `unify_normals` / `make_planar` / `flip_faces` / `detach_faces`） | — | 已有 `applied` + `failures`；这些操作本来不改拓扑计数，用计数判断会误报 | **保留** | 分级 `VERIFIED_RESULT` |

### 2.5 顺带修掉的三处

| 位置 | 问题 | 处理 |
| --- | --- | --- |
| `mcp_lights.ms:652 / 707 / 732`（`uvw_map` / `uvw_unwrap` / `uvw_quick_peel`） | `addModifier` 无栈校验；`uvw_unwrap` 甚至整段 `catch()` 裸吞 | **修复**：栈计数 + `failures` |
| `mcp_lights/render/shading/modifiers` 共 34 行 | 一行两个 `mcpPair`，运行时报参数数量错误 | **修复**：拆成两行；`ms_check.py` 新增第 5 节检查防复发 |
| `verify.payload_number` | 只看信封顶层与 `objects[0]`，而 mutating 工具的载荷在 `result`/`data` 下，导致所有 mutating 步骤被记为"未验证" | **修复**：`_find_field()` 依次查 `payload` / `data` / `result`，行列表支持 `objects` 与 `results` |

---

## 3. 明确**保留**的判定（附理由）

| 项 | 为什么不用改 |
| --- | --- |
| `transform_object` / `delete_objects` / `clone_objects` 的 Python 侧判定 | `batch.py` 已按对象逐个回读（`_verify_transform` / `_verify_delete` / `_verify_clone`），MAXScript 侧的 `message` 不承担结论 |
| `select_objects` | reconcile 到实际选择集；无法判断时给 `reconcile_unavailable` 警告而不是猜 |
| `mod_*` 的 `applied` 语义 | "`applied` = 该对象已处理"是准确的；`failures` 负责另一半 |
| `poly_detach_faces` 的 `created` | 新节点名由 `polyOp` 返回并被使用，当前是真实结果 |
| `group_objects` 的 `group` | `group nodes` 失败会抛；`g.name` 是场景真实名称 |
| `mat_delete` 的 `usedBy`/`inSlots` | Stage 5 已按引用计数回读，属于正确设计 |

---

## 4. 明确**暂缓**的判定（记为 UNKNOWN / 需要真机）

| 项 | 原因 | 需要什么才能决定 |
| --- | --- | --- |
| `proboolean` 的 `operandsRemaining` 是否应判失败 | ProBoolean 在某些版本会保留操作数副本；离线无法确认真实行为 | 真机 ProBoolean 三种运算各跑一次（R17） |
| `mod_add` 写后读回是否会对某些修改器产生**假失败** | 个别修改器的属性在 `addModifier` 后短时间只读或需要面板上下文；离线桩无法复现 | 真机对 `TurboSmooth`/`Bend`/`Shell`/`ProOptimizer` 各设一次参数（R16） |
| `attach` 的 `numSplines` 语义 | 若目标已是多 spline 形状，`attach` 可能把源并入最后一条 spline 而不是新增一条 | 真机 attach 两个 Circle（R18） |
| `boolean2` 是否一定消耗操作数 | 依赖网格是否水密；离线桩按"消耗"建模 | 真机 union/subtract 各一次（R17） |
| `poly_*` 的 `unchanged` 是否覆盖全部 no-op 形态 | 只比较面/点数量；仅移动顶点、只改平滑组的操作本来不改变计数 | 真机抽样（R19） |

---

## 5. 证据等级

- 本文件所有结论都是 **Static**（读源码 + 结构化审计）或 **Offline**（真实 TCP 桩 + FakeScene）。
- **没有任何结论来自真实 3ds Max**。R15–R20 见 `docs/WORKFLOW_ACCEPTANCE.md`。
- 反面证据同样重要：`ms_check.py` 之前查不出"一行两个语句"，说明"语法检查通过"不等于
  "能在 Max 里跑"。这类问题只能靠真机或更细的静态规则发现，本次采用后者。
