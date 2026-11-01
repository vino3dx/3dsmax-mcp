# Agent 场景工作流能力审计（Stage 3 / 阶段 A）

本文件回答一个问题：**一个 Agent 从"什么都没建"到一个可交付的场景，中间那 15 步，
现有工具真的支撑得住吗？**

判断不靠"工具存在"就算通过，而按五档证据分开记：

| 档 | 含义 | 判定依据 |
| --- | --- | --- |
| 已注册 | 工具出现在目录里，`mcpRegister` 与 catalog 一致 | `scripts/verify.py`、`registration_sync_test.py` |
| 有执行路径 | 真的会走到桥接（单次 / 对账 / 逐对象 / Scene Runtime / 本地 Python） | `server._execute_tool` 的分支与 `docs/CORE_CONTRACT.md` 第 2 节 |
| 静态测试 | schema、参数类型、枚举、双语描述、preset 被检查 | `catalog_contract_test.py`、`core_tool_validation_test.py` |
| 离线集成 | 有真实 Python 执行路径 + 假场景/桩桥，跑出可断言的场景变化 | `test/static/fake_scene.py`（20 条命令）+ `scene_bridge_stub.py`（真实 TCP） |
| 真实 Max | 在真的 3ds Max 里跑过并读回 | **本轮 0 项**（见第 4 节） |

"离线集成"一栏写"无"的步骤，不代表工具坏了，只代表**没有任何自动化证据**说明它在
真场景里做对了事——这类步骤必须靠 M 级验收（`docs/OVERNIGHT_ACCEPTANCE.md` 第 2 节）
补齐，不能靠"它能返回 success"来推。

## 1. 15 步能力矩阵

| # | 步骤 | 主要工具 | 已注册 | 执行路径 | 静态 | 离线集成 | 真实 Max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 连接与健康检查 | `bridge_ping` / `bridge_status` / `bridge_selftest` | 是 | 单次桥接 | S | 部分（`bridge_status` 有假场景） | 未执行 |
| 2 | 读场景概况 | `scene_info` / `count_objects` / `list_objects` | 是 | 单次桥接（`list_objects` 分页） | S | `scene_info`、`list_objects` 有；`count_objects` 无 | 未执行 |
| 3 | 确认对象身份 | `find_objects` / `get_object_info` | 是 | 单次桥接 | S | 有（重名/缺失/唯一性均有用例） | 未执行 |
| 4 | 创建几何 | `create_plane` / `create_box` / `create_sphere` 等 | 是 | Scene Runtime（mutating） | S | 有（`create_plane`/`create_box`/`create_sphere`） | 未执行 |
| 5 | 定位与变换 | `transform_object` | 是 | 逐对象 batch（reliability 模式） | S | 有（绝对/相对/失败行） | 未执行 |
| 6 | 选择集 | `select_objects` / `get_selection` / `deselect_all` | 是 | 对账 batch | S | 有 | 未执行 |
| 7 | 转可编辑多边形 | `convert_to_editable_poly` | 是 | Scene Runtime | S | 有 | 未执行 |
| 8 | 子对象编辑 | `poly_get_stats` / `poly_select_faces` / `poly_extrude_faces` | 是 | 对账 / 单次 | S | 有（面数真的变化） | 未执行 |
| 9 | 修改器 | `mod_add` / `mod_set_param` | 是 | 对账 batch | S | `mod_add` 有；`mod_set_param` 无 | 未执行 |
| 10 | 材质 | `mat_list` / `mat_create_standard` / `mat_assign` / `mat_get_for_object` | 是 | 对账 / Scene Runtime | S | 有（材质真的落到对象上） | 未执行 |
| 11 | 复制与删除 | `clone_objects` / `delete_objects` | 是 | 逐对象 batch | S | 有（含部分失败与副本核对） | 未执行 |
| 12 | 组织（层/组/父子） | `create_layer` / `assign_to_layer` / `group_objects` / `parent_objects` | 是 | 单次桥接 | S | **无** | 未执行 |
| 13 | 验证与前后对比 | `scene_snapshot` / `workflow_run`（含 12 种 verification） | 是（Python 本地） | 本地工具，内部复用上面各步 | S | 有（本轮新增，SNAP/W 两组） | 未执行 |
| 14 | 视觉反馈 | `vision_capture` / `vision_views` | 是 | 单次桥接 + 图片块 | S | 有（合成 PNG 走真实链路） | 未执行 |
| 15 | 保存与导出 | `scene_save` / `scene_save_as` / `export_*` | 是 | 单次桥接（保存带确认） | S | **无** | 未执行 |

统计：15 步中 **13 步有离线集成证据**，2 步（组织、保存导出）只有静态证据；
**15 步全部没有真实 Max 证据**。

## 2. 每一步真正的坑（决定工作流怎么写）

1. **名称不是身份。** `find_objects` 默认模糊匹配，`name="Box"` 会同时命中
   `Box001`/`Box002`；Max 本身允许重名。所以"按名称改对象"这一步，前提是
   `count==1`。工作流里的每一步都用 `find_objects{exact:true}` 先落地身份，
   而不是假设名字唯一。
2. **handle 只是线索。** `getHandleByAnim` 在部分情况下返回 0，
   且 `getNodeByHandle` 的往返没有真实 Max 验证，因此 handle 不参与执行引用，
   只在 diff 里用于识别"这是同一个对象改了名"。
3. **选择集不是状态。** 任何选择类工具都会改写它，省略 `objects` 就等于
   "操作上一次留下的东西"。批量工具一律显式传名称。
4. **执行成功 ≠ 目标达成。** `transform_object` 可以 `success:true` 而对象
   根本没动（相对量 0、轴向不符、被约束住）。所以每一步都要有 read-back 断言，
   这就是 `verify.py` 存在的理由。
5. **克隆/删除不幂等。** 超时后重试一次就可能多一份副本或删错两次。
   自动重试对它们一律禁止（`NEVER_RETRY` 之外的 `retry_decision` 也会拒绝）。
6. **`mod_add` 追加在堆栈顶部。** 想让它先于已有修改器生效必须 `mod_reorder`。
7. **材质赋值 `changed` 是 `null`。** "赋值语句跑过"不等于"材质真的换了"，
   必须 `mat_get_for_object` 复核。
8. **视觉反馈拿不到图不是建模失败。** `vision_capture` 在视口被遮挡、渲染器
   不支持时可能没有图；工作流把它标成 `optional`，结果降级为 `partial`
   而不是 `failed`。
9. **单位是场景单位。** 1 单位可能是 1 英寸也可能是 1 米，`get_units` 先看。

## 3. 被能力缺口挡住的做法

| 想做的事 | 现状 | 替代做法 |
| --- | --- | --- |
| 用事务回滚整段工作流 | 无事务系统，也不该有 | 失败后重新读场景，让调用方决定；破坏性操作前 `hold_scene` |
| 按 handle 精确引用对象 | handle 不能作为执行引用 | 名称 + `count==1`；handle 只做诊断 |
| 一次调用里做条件分支 | 工作流只有顺序、依赖、跳过 | 分多次 `workflow_run`，用返回的 `expectation`/`diff` 判断 |
| 跨会话记住场景快照 | 快照只存在内存里（`MAX_SNAPSHOTS=8`） | 需要长期基线就自己存 `scene_snapshot` 的 JSON |
| 部分对象成功继续做后续步骤 | 支持（`on_failure:continue`、`optional`） | 但整体只报 `partial`，不会报 `success` |

## 4. 真实 Max 验证为什么还是 0

本轮约束是**不启动 3ds Max、不改动用户 Max 安装目录**，所以没有一条 M 级证据。
所有"对象真的建出来了""面数真的变多了""材质真的在球上"的结论，在离线测试里
都只对**假场景**成立。假场景 20 条命令的行为是照 `src/ms` 的 handler 写的，
它能证明 Python 侧怎么解释返回、怎么判定、怎么失败，**不能**证明 MAXScript
在真 Max 里做的是同一件事。

第 12、15 两步连假场景都没有，因此它们在工作流里也只能"调用并检查返回是否
可读"，没有任何场景级断言——这一点在 `docs/WORKFLOW_ACCEPTANCE.md` 里被显式
标成 `Runtime`（待真实环境执行）。

## 5. 结论

- 现有工具**足够**组成一条完整的场景制作链路（15 步里 13 步有离线证据，
  没有一步缺少工具），缺的不是工具数量，而是**把工具串起来时的记录与验证**。
- 因此 Stage 3 只加 2 个 Python 侧工具（`scene_snapshot`、`workflow_run`），
  没有新增任何 MAXScript 命令：能力缺口在"编排层"，不在"桥接层"。
- 组织（层/组/父子）与保存导出这两步的离线空档，是下一步最值得补的测试缺口，
  而不是功能缺口。
