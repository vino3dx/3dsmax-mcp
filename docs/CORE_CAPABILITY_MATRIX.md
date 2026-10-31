# Core Capability Matrix — Stage 1.5

日期：2026-10-31  
基线：`589acf9`（本阶段离线审计）  
范围：`CORE_TOOLS` 的 56 个工具；不启动 Max、不连接 8765。

## 判定规则

- `IMPLEMENTED`：catalog、注册命令和 Handler/API 路径均存在。
- `OFFLINE_TESTED`：有 Python 静态、契约或 Runtime 测试证据。
- `RUNTIME_VERIFIED`：既有机器报告中的 live case 标为“实机通过”；这是历史证据，不是本阶段重新执行。
- `PARTIAL`：有实现和/或历史实机证据，但契约、读回或行为仍不完整；本基线中包括 `poly_triangulate` 失败以外的未统一输出问题。
- `BLOCKED`：实现路径存在，但没有可用的实机通过证据，必须等 Max/Bridge。
- `NOT_IMPLEMENTED`：未发现可执行路径。本次 56 个 Core 工具没有归入此类。

表中 `注册`、`Handler/API`、`参数` 是离线静态审计；`读回` 和 `实机证据` 严格来自既有 live matrix 文档或明确标记为未验证。当前 catalog 没有独立 output schema，因此“返回结构”总体为 `PARTIAL`：Python Runtime 已统一 envelope，但各 MAXScript payload 仍未完全归一化。

## 56 个 Core 工具

| 工具 | Bridge | 注册 | Handler/API | 参数校验 | 返回结构 | 读回/实机证据 | 单元/离线证据 | 状态 |
|---|---|---:|---:|---:|---|---|---|---|
| bridge_capabilities | bridge_capabilities | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| bridge_ping | bridge_ping | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| bridge_selftest | bridge_selftest | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| bridge_status | bridge_status | Y | Y | Y | PARTIAL | 实机通过 | E2E/live | RUNTIME_VERIFIED |
| clone_objects | clone_objects | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| convert_to_editable_poly | convert_to_editable_poly | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| create_box | create_box / primitive | Y | Y | Y | PARTIAL | 实机通过 | live + Runtime | RUNTIME_VERIFIED |
| create_circle | create_circle / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| create_cone | create_cone / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| create_cylinder | create_cylinder / primitive | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| create_geosphere | create_geosphere / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| create_line | create_line | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| create_plane | create_plane / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| create_pyramid | create_pyramid / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| create_rectangle | create_rectangle | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| create_sphere | create_sphere / primitive | Y | Y | Y | PARTIAL | 实机通过 | live + Runtime | RUNTIME_VERIFIED |
| create_teapot | create_teapot / primitive | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| create_torus | create_torus / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| create_tube | create_tube / primitive | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| delete_objects | delete_objects | Y | Y | Y | PARTIAL | 未验证 | Runtime | OFFLINE_TESTED |
| execute_maxscript | execute_maxscript | Y | Y | Y | PARTIAL | 未验证 | catalog/E2E | BLOCKED |
| get_max_version | get_max_version | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| get_selection | get_selection | Y | Y | Y | PARTIAL | 未验证 | Runtime/catalog | OFFLINE_TESTED |
| light_create_omni | light_create | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| light_create_spot | light_create | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| list_objects | list_objects | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| mat_assign | mat_assign | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| mat_create_standard | mat_create_standard | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| mat_get | mat_get | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| mat_list | mat_list | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| mat_set_diffuse | mat_set_diffuse | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| mod_add | mod_add | Y | Y | Y | PARTIAL | 实机通过 | live + Runtime | RUNTIME_VERIFIED |
| mod_bend | mod_add | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| mod_symmetry | mod_add | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| mod_turbosmooth | mod_add | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| poly_bevel_faces | poly_bevel_faces | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| poly_chamfer_edges | poly_chamfer_edges | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| poly_connect_edges | poly_connect_edges | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| poly_extrude_faces | poly_extrude_faces | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| poly_get_faces | poly_get_faces | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| poly_get_selection | poly_get_selection | Y | Y | Y | PARTIAL | 未验证 | catalog/Runtime | OFFLINE_TESTED |
| poly_get_stats | poly_get_stats | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| poly_get_verts | poly_get_verts | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| poly_inset_faces | poly_inset_faces | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| poly_select_faces | poly_select_faces | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| poly_subdivide | poly_subdivide | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| poly_weld_vertices | poly_weld_vertices | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| rename_object | rename_object | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| scene_info | scene_info | Y | Y | Y | PARTIAL | 实机通过 | live + Runtime | RUNTIME_VERIFIED |
| scene_new | scene_new | Y | Y | Y | PARTIAL | 实机通过 | live + Runtime | RUNTIME_VERIFIED |
| scene_open | scene_open | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| scene_save | scene_save | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| scene_save_as | scene_save_as | Y | Y | Y | PARTIAL | 未验证 | catalog | BLOCKED |
| select_objects | select_objects | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| transform_object | transform_object | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |
| uvw_map | uvw_map | Y | Y | Y | PARTIAL | 实机通过 | live matrix | RUNTIME_VERIFIED |

## 剩余 24 个 Core 缺口

这些工具有静态实现路径，但当前 `test/live/live_cases/` 没有对应 case，因此状态是 `BLOCKED`，不是 `NOT_IMPLEMENTED`：

`bridge_capabilities`, `bridge_ping`, `create_circle`, `create_cone`, `create_geosphere`, `create_plane`, `create_pyramid`, `create_torus`, `create_tube`, `delete_objects`, `execute_maxscript`, `get_selection`, `mat_list`, `mod_symmetry`, `mod_turbosmooth`, `poly_chamfer_edges`, `poly_connect_edges`, `poly_get_selection`, `poly_get_stats`, `poly_inset_faces`, `poly_weld_vertices`, `scene_open`, `scene_save`, `scene_save_as`。

其中 `delete_objects`、`scene_open/save*` 和 `execute_maxscript` 还需要明确的破坏性操作/文件策略；不能仅补一个“success”断言。

## 对象身份机制审计

- 当前工具主要依赖对象名称、名称列表或选择集；未发现跨操作稳定的 Max node handle/UUID 被暴露到 MCP。
- `rename_object` 后，继续使用旧名称的调用可能失效；同名目标的解析由 Max 当前查找语义决定，不能视为稳定身份。
- 删除后再次用旧名称操作通常会失败，但在名称复用或批量解析场景下存在误指向风险。
- 兼容方案：保留现有 `name`/`objects` 参数；新增只读 `object_ref` 结构时优先返回 `{name, handle?, class, creation_index?}`，调用前验证 handle/name/class，失配返回 `stale_object_reference`，不静默回退到同名对象。
- 在 Max 2020 实机确认可持久化的句柄语义前，不把内部 node handle 写入公共契约；本阶段标记为 `BLOCKED`，不是已实现。

## 批量操作审计

| 能力 | 当前可复用入口 | 离线结论 |
|---|---|---|
| 批量创建 | 多次调用 `create_*`；`create_primitive`/对象列表路径 | 有基础能力；未见统一 batch envelope |
| 批量变换 | `transform_object` 的 objects 参数 | 已有入口；需实机确认每个对象读回 |
| 批量复制 | `clone_objects` 的 objects 参数 | 已有入口；live 已覆盖一次 |
| 批量选择 | `select_objects` 的 objects 参数 | 已有入口；live 已覆盖一次 |
| 批量赋材质 | `mat_assign` 的 objects 参数 | 已有入口；live 已覆盖单对象，批量未验 |
| 批量修改器 | `mod_add` 的 objects 参数 | 已有入口；live 已覆盖单对象，批量未验 |

结论：优先补批量请求的参数/返回契约和 live case，不新增重复的 `batch_*` 工具。

## 后续 Runtime 验收清单

1. 启动 Max 后先确认 `scene_info.objectCount`，不接受只看 `success`。
2. 逐项运行 24 个缺口工具的最小安全 case；文件与脚本工具单独确认路径/破坏性策略。
3. 对创建、复制、变换、删除、修改器、材质批量参数逐对象读回。
4. 对重命名后引用、删除后旧引用、同名对象进行实机身份实验；记录 Max 2020 的实际句柄能力。
5. 对 viewport/vision 工具保存真实图片摘要和 MCP image block 证据；本阶段不把静态图片转换测试当作截图通过。
6. 重新生成 `docs/LIVE_MATRIX.md`，分别记录 `RUNTIME_VERIFIED`、失败、未验证和环境阻塞。
