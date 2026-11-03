# Stage 5 报告：把"静默失败"从工具面里清出去

日期：2026-11-03
分支：`main`
基线：Stage 4 结束于 `a7d29c3`（工作区干净）

Stage 4 把"回执型返回"读对了，但还有一件事没解决：**有些 handler 根本没在回执里
说结果**，因为它们把失败吞掉了。这一轮就是去清这些静默失败——不是给它们补一个
乐观默认值，而是让它们回读场景状态、逐对象执行、把没做成的点名。

## 1. 起点

`test/static/outcome_audit.py` 在 Stage 4 结束时报告：293 个可审计的 mutating 工具里，
**74 个读不出结论**。它们长这样：

```maxscript
fn mcpH_hide_objects params =
(
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    try ( hide nodes ) catch()          -- everything that could go wrong goes here
    mcpRedraw()
    local p = #()
    mcpPair p "message" (mcpMsg "msg.ok")   -- ...and the reply says OK
    mcpObj p
)
```

两个独立的问题叠在一起：

1. **失败被吞掉**：对象被锁定、在冻结层上、或者 API 拒绝，全被 `catch()` 吃掉。
2. **没有结论字段**：返回只有 `message`，于是可靠性模式判 `missing_success`——
   一次真的成功的操作被报成失败。

把这两件事一起修，才有意义：只补字段会让静默失败变成"成功"；只收集错误而不声明，
工具在 core 档位下仍然报失败。

## 2. 做法：按"能不能回读"分三类

| 类型 | 例子 | 做法 |
| --- | --- | --- |
| **有状态可回读** | `hide_objects` / `freeze_objects` | 操作后读 `isHidden` / `isFrozen`，分成 `hidden` 与 `failures` |
| **可逐对象执行** | `mirror_object` / `reset_transform` / `snap_objects_to_grid` | 每个对象一个 try，成功的进 `applied`，抛错的进 `failures` |
| **失败必抛** | `mat_set_slot` / `mat_rename` / `cam_create` | 原有的 `mcpFail` 已经是兜底，显式写 `success: true` |

**没有**对任何工具使用"统一的 `success: true` 兜底"。凡是加了 `success: true` 的，
都能指出它在哪一行 mcpFail、或者为什么失败会抛出来——注释里写了。

### 2.1 集中在一个辅助函数上

隐藏/冻结这一类共用 `mcpSplitByFlag`（`mcp_objects.ms`）：

```maxscript
fn mcpSplitByFlag nodes flagName want =
(
    local hit = #()
    local miss = #()
    for n in nodes do
    (
        local nm = "?"
        try ( nm = n.name ) catch ( nm = "?" )
        local value = undefined
        try ( value = getProperty n flagName ) catch ( value = undefined )
        if value == want then append hit nm else append miss nm
    )
    #(hit, miss)
)
```

`miss` 同时就是 `failures`：一处回读，两件事都有答案。

### 2.2 `*_all` 必须先记状态

`unfreeze_all` 的第一版我写成了"操作后把所有 `isFrozen == false` 的对象报成 `thawed`"，
那会把整个场景都列进去。正确做法是先记下"原本冻结的"，操作后只看这一批：

```maxscript
local was = #()
for i = 1 to objects.count do
(
    local n = objects[i]
    local f = false
    try ( f = n.isFrozen ) catch ( f = false )
    if f do append was n
)
try ( unfreeze objects ) catch()
local split = mcpSplitByFlag was "isFrozen" false
```

`thawed` 因此是"本来冻结、现在不冻结了"的对象。离线用例
`check_freeze_and_thaw` 断言了这一点。

### 2.3 材质与渲染：读回真正会被用到的值

- `mat_set_pbr` / `mat_set_emission`：逐属性 `applied` / `skipped`。材质类不支持某个
  属性时会进 `skipped`；**一个都没设上就 `mcpFail`**，不再回答 "ok"。
- `mat_delete`：Max 没有"删除材质"，只有引用计数。所以回读"还有谁在用它"
  （`usedBy` / `inSlots`），两个都空才算删掉了。
- `render_set_resolution`：回读 `renderWidth` / `renderHeight`。Max 会夹取尺寸，
  "赋值跑过了"不等于"尺寸改了"。
- `render_set_output`：回读 `rendOutputFilename` / `rendSaveFile`。路径被忽略时，
  渲染会在第 1 帧写到别处——这种事必须现在就报，不能等出图。
- `render_set_frame_range`：回读 `rendTimeType` / `renderStart` / `renderEnd`。
- `set_units`：回读 `units.SystemScale`。**单位错了，后面所有尺寸都错，而且看不出坏**；
  未知的 `displayType` 现在直接 `bad_value`，不再静默忽略。

## 3. 结果

| 指标 | 修前 | 修后 |
| --- | --- | --- |
| 能读出结论的 mutating 工具 | 219 | **282** |
| 读不出 | 74 | **11** |
| core 档位缺口 | 0 | 0 |

修好的 63 个按文件：

| 文件 | 数量 | 代表 |
| --- | --- | --- |
| `mcp_objects.ms` | 13 | hide / freeze / mirror / set_pivot / reset_transform / snap / unparent / open_group / close_group / spline_set_points |
| `mcp_shading.ms` | 22 | mat_set_pbr / mat_set_emission / mat_delete / mat_set_slot / mat_rename / 9 个 map_create_* / mat_library_* |
| `mcp_render.ms` | 11 | render_set_engine / resolution / output / frame_range / save_preset / load_preset / element_add / element_remove / element_set_output / viewport_set_view / viewport_set_layout |
| `mcp_lights.ms` | 15 | light_set / cam_set / env_set_* / cam_create / cam_delete / light_set_sun |
| `mcp_system.ms` | 1 | set_units |
| `mcp_animation.ms` | 1 | anim_goto_frame（回读 currentTime） |

剩下 11 个，如实列出（`outcome_audit.py` 会持续打印）：

| 工具 | 为什么没修 |
| --- | --- |
| `execute_python` | 逃生仓：返回值是 Python 表达式的值，没有"成功"可判 |
| `anim_play` / `anim_play_preview` / `anim_bake_range` | 播放与烘焙状态：回读只能读到"当前帧"，不能证明"播放过" |
| `ctrl_wire` / `rig_ik_solver` / `rig_spline_ik` | 约束/解算结果通过场景关系表达，需要专门的验证 kind |
| `viewport_zoom_extents` / `viewport_set_shading` / `viewport_toggle_grid` | 纯视图状态，跨版本回读 API 不可靠 |
| `bake_set_output` | 只是记下参数，真正的写盘发生在 bake 时 |

这一批的共同点：**没有可靠的回读方式**。给它们加 `success: true` 会把"不知道"说成
"成功"，这正是本项目一直在避免的事。它们继续返回 `missing_success`——难看，但诚实。

## 4. 测试

新增 `test/static/object_state_test.py`（Offline，10 个用例），走真实 TCP 桩：

| 用例 | 证明了什么 |
| --- | --- |
| `check_hide_reports_the_scene_state` | 隐藏后回读 `hidden`；再取消隐藏一个，另一个保持隐藏 |
| `check_hide_partial_failure_is_not_success` | **核心用例**：一个对象拒绝 → `hidden` 只含成功的那个、`failures` 点名拒绝的、工具 `isError: true` |
| `check_hide_reports_state_not_request` | 已经隐藏的对象再隐藏一次，仍然如实报 `hidden` |
| `check_unhide_all_covers_every_object` | 全场景三个隐藏对象一次解开 |
| `check_freeze_and_thaw` | `frozen` 只含刚冻结的；`thawed` 只含本来冻结的（不是全场景） |
| `check_reset_transform_reports_each_object` | 一个拒绝 → `applied` / `failures` 分开，被拒对象状态没变 |
| `check_reset_transform_can_skip_parts` | 只重置旋转时，缩放与位置不动 |
| `check_snap_to_grid_moves_and_reports` | 吸附真的改变了坐标，被拒的那个没动 |
| `check_group_open_refuses_plain_meshes` | 对普通网格开场 → 失败；对真组 → 成功 |
| `check_empty_target_list_is_an_honest_no_op` | 空目标列表：什么都不做，也不声称做了什么 |

`FakeScene` 新增 `reject_ops`（模拟被锁定/拒绝的节点）和 13 个 handler，
`snap_objects_to_grid` 用 `math.floor(x/spacing + 0.5)` 与 MAXScript 保持一致
（Python 的 `round()` 是银行家舍入，在 .5 上会给出不同结果）。

`outcome_declaration_test.py` 增加一组 `check_state_readback_shapes`，
把这一轮新增的返回形状钉住，包括"`applied` 空、`skipped` 非空不得读成成功"。

回归结果：21 个静态/离线测试文件全部通过，`verify.py`、`test_e2e.py`、
`ms_check.py`（0 problem）通过。`registration_sync_test` 仍是部署树漂移
（基线即失败，需要 `install.py`）。

## 5. 字节与部署

改了 5 个 `.ms`：`mcp_objects.ms`、`mcp_shading.ms`、`mcp_render.ms`、
`mcp_lights.ms`、`mcp_system.ms`。

| 文件 | 行尾 | 核对 |
| --- | --- | --- |
| `mcp_objects.ms` | CRLF | CRLF 计数 == LF 计数，无孤立 LF |
| `mcp_shading.ms` | CRLF | 同上 |
| `mcp_render.ms` | CRLF | 同上 |
| `mcp_lights.ms` | CRLF | 同上 |
| `mcp_system.ms` | LF + BOM | 保持原样 |

**这批改动必须在用户机器上重装才生效**：`python scripts/install.py --yes`。
在装之前，用户机器上的桥接仍是旧版本；core 档位下这些工具会继续报
`missing_success`（旧行为），不会报错，只是判得不准。

## 6. 已知风险

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| R1 无真实 Max 证据 | `getProperty n "isHidden"`、`units.SystemScale` 回读、`renderWidth` 夹取行为都只在假场景里验证过 | 按 `WORKFLOW_ACCEPTANCE.md` R1–R11 人工验收；本轮新增 R12 / R13 |
| R2 行为变更 | `set_units` 现在拒绝未知 `displayType`；`mat_set_pbr` 全 skipped 会失败 | 都是"把静默改成明说"，属预期变化；CHANGELOG 已列 |
| R3 仍有 15 个工具无结论 | 见第 3 节表 | 审计持续打印，不设"必须清零"的门禁——那会逼人乱加 `success` |
| R4 `skipped` 不进 failures | 部分属性没设上时整体仍判成功 | 刻意如此：材质类差异太常见；`skipped` 在 payload 里可读，Agent 能看到 |

## 7. 下一阶段

1. **执行 R1–R13 真实 Max 验收**（仍然最优先）。本轮新增两条：
   R12 = 锁定/冻结层上的对象做 `hide` / `reset_transform`，确认回执是 `failures` 而不是 "ok"；
   R13 = `set_units` 设一个会被夹取的 `scale`，确认 `failures` 里带实际值。
2. **给剩下 15 个补验证方式**，而不是补 `success`：`ctrl_wire` / `rig_ik_*` 适合走
   `verify.py` 的新 kind（读约束关系），`render_element_*` 需要先确认版本间 API。
3. **把 `reject_ops` 的思路用到材质/灯光测试**：`object_state_test.py` 只覆盖了对象状态，
   `mat_set_pbr` / `light_set` 的 `applied` / `skipped` 仍只有静态证据。
4. **`outcome_audit.py` 变成趋势**：记录每个阶段结束时的数字，让"缺口在缩小"可核对，
   而不是只在报告里说一句。
