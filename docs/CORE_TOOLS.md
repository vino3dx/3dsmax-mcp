# Core 工具集

`core` 是面向 agent 默认会话的精简工具面。它只包含建模主路径中已有实机用例的工具，以及连接、场景和恢复所需的少量基础工具；完整 catalog 仍可通过 `full` profile 使用。

## 当前状态

- 工具数：56（由 catalog 自动计算）
- 依据：现有 `docs/LIVE_MATRIX.md` 中的 43 个用例，加上同一主路径中已有建模回归证据的基础入口；这不是“56 个全部已实机验证”的声明
- 当前证据核对：56 个 core 工具中有 32 个出现在 live case 清单，24 个尚无对应 live case；出现在清单也不等于本机本轮已通过
- `poly_triangulate`：不纳入 core；Max 2020 的 Editable Poly 语义尚未确认
- 真实调用频率：未确认；仓库中没有可供本轮读取的统一桥接调用日志

## 工具清单

### system

`bridge_status`, `bridge_ping`, `bridge_capabilities`, `bridge_selftest`, `get_max_version`, `execute_maxscript`

### scene

`scene_info`, `scene_new`, `scene_save`, `scene_save_as`, `scene_open`

### objects

`create_box`, `create_sphere`, `create_cylinder`, `create_cone`, `create_torus`, `create_teapot`, `create_plane`, `create_tube`, `create_pyramid`, `create_geosphere`, `create_line`, `create_rectangle`, `create_circle`, `transform_object`, `clone_objects`, `rename_object`, `delete_objects`, `select_objects`, `get_selection`, `list_objects`

### modeling

`convert_to_editable_poly`, `poly_get_stats`, `poly_get_verts`, `poly_get_faces`, `poly_get_selection`, `poly_select_faces`, `poly_extrude_faces`, `poly_bevel_faces`, `poly_inset_faces`, `poly_chamfer_edges`, `poly_connect_edges`, `poly_weld_vertices`, `poly_subdivide`, `mod_add`, `mod_bend`, `mod_turbosmooth`, `mod_symmetry`

### shading

`mat_create_standard`, `mat_assign`, `mat_set_diffuse`, `mat_get`, `mat_list`, `light_create_omni`, `light_create_spot`, `uvw_map`

## 使用边界

这些工具适合从空场景创建基础几何、变换和组织对象、进入 Editable Poly、做基础面/边操作、添加常用修改器、赋予标准材质和基础灯光。动画、导入导出、渲染器专用材质、骨骼和复杂 UV 展开应切换到对应 profile。

`execute_maxscript` 是逃生舱，不应替代已有专用工具；频繁使用它通常表示某个高频能力还缺少稳定的专用封装。`delete_objects`、`scene_new`、`scene_open` 会改变场景状态，使用前应由客户端确认目标和保存策略。

## 证据标签

- “已实机验证”：来自现有 live matrix 或 modeling 回归记录。
- “未验证”：本轮没有启动 Max，不将静态检查结果冒充实机证据。
- “推测”：依据工具分类和既有工作流提出，待调用日志或新一轮实机数据确认。

## Core 与实机矩阵的边界

`core` 是候选默认工具面，不是自动生成的实机通过清单。当前应以
`test/live/live_cases/` 的逐项读回结果和 `test/logs/` 的机器报告作为工具级证据。
在下一轮 Max 运行完成前，不能把未覆盖的 24 个工具标记为“已实机验证”，也不能
仅因工具出现在 43 条 case 清单中就断言本轮通过。

