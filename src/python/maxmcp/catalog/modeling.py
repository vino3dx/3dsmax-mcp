"""Modeling catalog: editable poly editing, the modifier stack, specific
modifiers and spline-driven geometry.

Category key: ``modeling``.
"""

from __future__ import annotations

from typing import List

from .schema import Tool, arr, b, i, n, num3, s, tool

TOOLS: List[Tool] = []


# ============================================================ converters
TOOLS.append(tool(
    "convert_to_editable_poly", "modeling",
    "把对象转换为可编辑多边形（Editable Poly）。这是绝大多数多边形建模操作的前置步骤。"
    "该转换会塌陷对象原本的修改器与基础类型，不可撤销为原类型。",
    "Convert an object to an Editable Poly. This is the prerequisite for almost every "
    "polygon modeling operation. The conversion collapses the object's base type and "
    "modifiers and cannot be reverted to the original class.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
    },
))

TOOLS.append(tool(
    "convert_to_editable_mesh", "modeling",
    "把对象转换为可编辑网格（Editable Mesh）。网格比多边形更老、功能更少，"
    "通常优先用 convert_to_editable_poly。仅在需要旧版网格接口时使用。",
    "Convert an object to an Editable Mesh. Mesh is older and less capable than poly; "
    "prefer convert_to_editable_poly. Use this only when a legacy mesh interface is needed.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
    },
))

TOOLS.append(tool(
    "convert_to_nurbs", "modeling",
    "把对象转换为 NURBS 曲面。并非所有对象都能转换（例如普通几何体通常不行），"
    "失败时会在 failures 里报告原因，不会中断其他对象。",
    "Convert an object to a NURBS surface. Not every object can be converted (plain "
    "primitives usually cannot); failures are reported per object and do not abort the rest.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
    },
))

TOOLS.append(tool(
    "collapse_stack", "modeling",
    "塌陷（应用并删除）对象上的整个修改器堆栈，把结果烘焙进基础对象。"
    "**此操作不可逆：所有修改器参数将永久丢失，子对象编辑数据也会被烘焙。** "
    "兼容入口：等价于 mod_collapse（bridge 指向同一受保护路径），"
    "必须显式传入 confirm=true 才会执行；新代码请直接用 mod_collapse。",
    "Collapse (apply and delete) the entire modifier stack of an object, baking the result "
    "into the base object. **Irreversible: every modifier parameter is lost for good and "
    "sub-object edits get baked in.** Compatibility entry: equivalent to mod_collapse "
    "(bridged to the same guarded path); only runs when confirm=true is passed explicitly. "
    "Prefer mod_collapse in new code.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("可选：堆栈中必须存在的修改器名/类名/索引，作为批量操作的安全过滤条件。",
                      "Optional: a modifier (name/class/index) that must exist on the stack, "
                      "used as a safety filter for batch calls."),
        "confirm": b("必须为 true 才会执行塌陷。默认 false（拒绝执行）。",
                     "Must be true for the collapse to run. Default false (refused)."),
    },
    required=["confirm"],
    bridge="mod_collapse",
))


# ============================================================ poly query
TOOLS.append(tool(
    "poly_info", "modeling",
    "返回多边形对象的顶点/边/面数量、当前子对象选择层级（subobjectLevel）、"
    "材质 ID 的取值范围。用于建模前确认对象状态。",
    "Return a polygon object's vertex/edge/face counts, the current sub-object level "
    "(subobjectLevel) and the range of material IDs present. Use it to confirm the state "
    "of an object before editing.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
    },
    mutating=False,
))

TOOLS.append(tool(
    "poly_get_verts", "modeling",
    "分页返回顶点索引与坐标。可用 faces 过滤只取某些面用到的顶点。",
    "Return vertex indices and positions, paginated. Pass faces to limit the result to the "
    "vertices used by those faces.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("只返回这些面涉及的顶点；省略则返回全部。",
                     "Only return vertices used by these faces; omit for all.", items="integer"),
        "limit": i("最多返回条数，0 表示全部。", "Maximum entries to return, 0 for all."),
        "offset": i("跳过的条数（分页）。", "Entries to skip (pagination)."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "poly_get_faces", "modeling",
    "分页返回每个面的索引、组成顶点、法线方向与材质 ID。非常适合读取几何拓扑。",
    "Return, per face, its index, the vertices it uses, its normal direction and its "
    "material ID, paginated. Great for reading geometry topology.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "limit": i("最多返回条数，0 表示全部。", "Maximum entries to return, 0 for all."),
        "offset": i("跳过的条数（分页）。", "Entries to skip (pagination)."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "poly_get_edges", "modeling",
    "分页返回每条边的索引及其连接的两个顶点。",
    "Return each edge's index and the two vertices it connects, paginated.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "limit": i("最多返回条数，0 表示全部。", "Maximum entries to return, 0 for all."),
        "offset": i("跳过的条数（分页）。", "Entries to skip (pagination)."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "poly_get_stats", "modeling",
    "返回多边形统计：顶点/边/面数量、材质 ID 区间、多边形总数。",
    "Return polygon statistics: vertex/edge/face counts, the material ID range and the "
    "total polygon count.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
    },
    mutating=False,
))

TOOLS.append(tool(
    "poly_get_elements", "modeling",
    "统计多边形对象的元素（element，即互相连接的面的分组）数量及每个元素的面数。"
    "建模前确认对象是几个连通体、封口后验证元素数是否减少，都用它。",
    "Count the elements (connected groups of faces) of a polygon object and the number of "
    "faces per element. Use it to confirm how many connected bodies an object has, or to "
    "verify that capping reduced the element count.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "limit": i("最多返回多少个元素的明细，默认 100。",
                   "Maximum element details to return, default 100."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "poly_get_selection", "modeling",
    "只读查询多边形对象当前的子对象层级（subobjectLevel）以及顶点/边/面/边界各层级的"
    "选中数量与索引。建模操作后确认选择状态、或排查“为什么挤出没作用”时先用它。",
    "Read-only query of a polygon object's current sub-object level and the count and indices "
    "of selected verts / edges / faces / borders. Use it to confirm the selection state after "
    "an edit, or to debug why an extrude did nothing.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "limit": i("每级最多返回多少个索引，默认 1000。",
                   "Maximum indices per level, default 1000."),
    },
    mutating=False,
))


# ============================================================ poly vertex edit
TOOLS.append(tool(
    "poly_set_vertex", "modeling",
    "把单个顶点移动到绝对坐标（position）或相对偏移（offset）。不能同时省略两者。"
    "坐标使用当前场景单位。",
    "Move a single vertex to an absolute position or by a relative offset. Exactly one of "
    "position/offset is required. Coordinates use the current scene unit.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "index": i("顶点索引（从 1 开始）。", "Vertex index (1-based)."),
        "position": num3("绝对坐标 [x,y,z]。", "Absolute position [x,y,z]."),
        "offset": num3("相对偏移 [x,y,z]。", "Relative offset [x,y,z]."),
    },
    required=["index"],
))

TOOLS.append(tool(
    "poly_move_vertices", "modeling",
    "把一批顶点整体按同一偏移量移动。比逐个 poly_set_vertex 高效。",
    "Move a batch of vertices by the same offset. More efficient than calling "
    "poly_set_vertex per vertex.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "vertices": arr("要移动的顶点索引列表。", "Vertex indices to move.", items="integer"),
        "offset": num3("偏移量 [x,y,z]。", "Offset [x,y,z]."),
    },
    required=["vertices", "offset"],
))

TOOLS.append(tool(
    "poly_weld_vertices", "modeling",
    "在给定阈值内焊接（合并）一批顶点。阈值过小可能焊不上，过大可能误并无关顶点。"
    "单位与场景一致，常用 0.01~0.1。",
    "Weld (merge) a batch of vertices within a threshold. Too small a threshold may weld "
    "nothing; too large may merge unrelated vertices. In scene units, usually 0.01~0.1.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "vertices": arr("要焊接的顶点索引列表。", "Vertex indices to weld.", items="integer"),
        "threshold": n("焊接阈值（场景单位）。", "Weld threshold (scene units).", minimum=0.0),
    },
    required=["vertices"],
))

TOOLS.append(tool(
    "poly_target_weld", "modeling",
    "把 vertex 焊接到 target 顶点上（目标焊接），结果与 target 重合。"
    "与 poly_weld_vertices（取平均点）不同，这里明确指定落点。",
    "Target-weld `vertex` onto `target` so the result lands exactly on the target. Unlike "
    "poly_weld_vertices (which averages), here the landing point is explicit.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "vertex": i("要移动的顶点索引。", "Vertex index to move."),
        "target": i("目标顶点索引。", "Target vertex index."),
        "threshold": n("容差，默认 0.1。", "Tolerance, default 0.1.", minimum=0.0),
    },
    required=["vertex", "target"],
))

TOOLS.append(tool(
    "poly_chamfer_vertices", "modeling",
    "对顶点做倒角，沿相邻边方向切出小面，amount 控制切出宽度。",
    "Chamfer the given vertices, cutting small faces along adjacent edges. Amount controls "
    "how far the cut extends.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "vertices": arr("要倒角的顶点索引列表。", "Vertex indices to chamfer.", items="integer"),
        "amount": n("倒角宽度。", "Chamfer amount."),
    },
    required=["vertices"],
))

TOOLS.append(tool(
    "poly_remove_vertices", "modeling",
    "删除顶点。被删顶点会连同其所属的面一起消失，**会破坏拓扑**，请先确认后果。",
    "Delete vertices. Removing a vertex also removes the faces that use it, **destroying "
    "topology** - confirm the consequences first.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "vertices": arr("要删除的顶点索引列表。", "Vertex indices to remove.", items="integer"),
    },
    required=["vertices"],
))


# ============================================================ poly face edit
TOOLS.append(tool(
    "poly_select_faces", "modeling",
    "按索引、材质 ID、法线方向或高度范围选择面，并保留该选择（进入面子对象模式）。"
    "返回被选中面的索引，方便后续用 poly_extrude_faces 等继续操作。",
    "Select faces by index, material ID, normal direction or height range, and leave the "
    "selection active (enters face sub-object mode). Returns the selected face indices so "
    "you can follow up with poly_extrude_faces etc.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("按索引选择这些面；与下面条件互斥时优先。",
                     "Select these faces by index; takes priority over the filters below.", items="integer"),
        "materialId": i("选择材质 ID 等于该值的面。", "Select faces whose material ID equals this."),
        "normalAxis": s("按法线方向选：x / y / z。", "Select by normal axis: x / y / z.",
                        enum=["x", "y", "z"]),
        "normalSign": s("法线方向正负：+ 取同向，- 取反向，默认 +。",
                        "Normal sign: + same direction, - opposite, default +.",
                        enum=["+", "-"]),
        "heightAxis": s("按高度范围选：x / y / z。", "Select by height on axis: x / y / z.",
                        enum=["x", "y", "z"]),
        "heightMin": n("高度范围下限（场景单位）。", "Height range lower bound (scene units)."),
        "heightMax": n("高度范围上限（场景单位）。", "Height range upper bound (scene units)."),
    },
    mutating=True,
))

TOOLS.append(tool(
    "poly_select", "modeling",
    "通用子对象选择：进入指定的子对象层级（level：0=对象 / 1=顶点 / 2=边 / 3=边界 / 4=面 / "
    "5=元素，也可用名称）并设置对应选择集合。省略 level 时按传入的索引自动推断层级。"
    "与 poly_select_faces（仅面、带条件过滤）互补；选择会保留，配合 poly_get_selection 验证。",
    "Generic sub-object selection: enter the given sub-object level (0=object / 1=vertex / "
    "2=edge / 3=border / 4=face / 5=element, names accepted too) and set the matching "
    "selection set. When level is omitted it is inferred from the indices passed. "
    "Complements poly_select_faces (faces only, with filters); the selection stays active, "
    "verify it with poly_get_selection.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "level": s("子对象层级：0-5 或 vert/edge/border/face/element；省略则自动推断。",
                   "Sub-object level: 0-5 or vert/edge/border/face/element; omit to infer."),
        "verts": arr("要选中的顶点索引。", "Vertex indices to select.", items="integer"),
        "edges": arr("要选中的边索引。", "Edge indices to select.", items="integer"),
        "faces": arr("要选中的面索引。", "Face indices to select.", items="integer"),
        "borders": arr("要选中的边界索引（当前版本不支持时会被忽略）。",
                       "Border indices to select (ignored when unsupported).", items="integer"),
        "elements": arr("要选中的元素索引（会展开为对应的面）。",
                        "Element indices to select (expanded to their faces).", items="integer"),
    },
    mutating=True,
))

TOOLS.append(tool(
    "poly_extrude_faces", "modeling",
    "沿面法线挤出所选面。amount 为正向外挤、为负向内挤（挖洞）。"
    "可省略 faces 表示挤出所有面；direction 可覆盖默认的法线方向。",
    "Extrude the selected faces along their normals. A positive amount extrudes outward, a "
    "negative amount pushes inward (to dig a hole). Omit faces to extrude all faces; "
    "direction overrides the default normal.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要挤出的面索引；省略则全部面。", "Face indices to extrude; omit for all.", items="integer"),
        "amount": n("挤出高度（负值为向内）。", "Extrusion height (negative goes inward)."),
        "direction": num3("自定义挤出方向 [x,y,z]，省略则用面法线。",
                          "Custom extrude direction [x,y,z]; omit for face normal."),
    },
    required=["amount"],
))

TOOLS.append(tool(
    "poly_bevel_faces", "modeling",
    "对面做斜角：先沿法线挤出 height，再向内收 outline，常用于制作凹槽与边框。",
    "Bevel faces: first extrude along the normal by height, then inset by outline. Useful "
    "for grooves and borders.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要斜角的面索引；省略则全部面。", "Face indices to bevel; omit for all.", items="integer"),
        "height": n("挤出高度。", "Extrusion height."),
        "outline": n("内收/外扩量（正为内收）。", "Inset amount (positive insets)."),
    },
    required=["height", "outline"],
))

TOOLS.append(tool(
    "poly_inset_faces", "modeling",
    "向内收面（inset），在面内部生成一圈更小的面，常用于做凹陷或分段。",
    "Inset faces, generating a smaller face inside each one. Good for depressions or panels.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要 inset 的面索引；省略则全部面。", "Face indices to inset; omit for all.", items="integer"),
        "outline": n("内收量。", "Inset amount."),
    },
    required=["outline"],
))

TOOLS.append(tool(
    "poly_bridge_faces", "modeling",
    "在两组面之间桥接（bridge），生成连接它们的几何。常用于挖洞后连接两侧、做管道。",
    "Bridge two sets of faces, generating geometry that connects them. Useful after holes "
    "or to build tubes.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces1": arr("第一组面索引。", "First face index set.", items="integer"),
        "faces2": arr("第二组面索引。", "Second face index set.", items="integer"),
    },
    required=["faces1", "faces2"],
))

TOOLS.append(tool(
    "poly_cap_holes", "modeling",
    "用面填补孔洞（cap）。选择要封口的面（或省略表示尝试全部边界）即可补洞。",
    "Cap holes by filling them with faces. Select the faces to cap (or omit to try all "
    "boundary loops).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要封口的面索引；省略则全部边界。", "Face indices to cap; omit for all boundaries.", items="integer"),
    },
))

TOOLS.append(tool(
    "poly_flip_faces", "modeling",
    "翻转所选面的法线方向，用于修正反面（黑面/光照错误）。",
    "Flip the normals of the selected faces, fixing back-facing (dark / wrongly lit) surfaces.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要翻转的面索引；省略则全部面。", "Face indices to flip; omit for all.", items="integer"),
    },
))

TOOLS.append(tool(
    "poly_delete_faces", "modeling",
    "删除所选面。删除后面上的顶点若孤立会被一并清除。**会破坏拓扑**。",
    "Delete the selected faces. Isolated vertices left behind are removed too. "
    "**This destroys topology.**",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要删除的面索引。", "Face indices to delete.", items="integer"),
    },
    required=["faces"],
))

TOOLS.append(tool(
    "poly_assign_material_id", "modeling",
    "给所选面设置材质 ID（多材质的前缀）。同一 ID 的面共享子材质槽。",
    "Assign a material ID to the selected faces (for multi/sub-object materials). Faces with "
    "the same ID share a sub-material slot.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要设置的面索引；省略则全部面。", "Face indices to set; omit for all.", items="integer"),
        "materialId": i("材质 ID（从 1 开始）。", "Material ID (1-based).", minimum=1),
    },
    required=["materialId"],
))

TOOLS.append(tool(
    "poly_set_smoothing", "modeling",
    "把所选面归入某个平滑组（1-32）。平滑组决定面与面之间是否平滑过渡（硬边/软边）。",
    "Put the selected faces into a smoothing group (1-32). Smoothing groups decide whether "
    "faces shade smoothly into each other (hard vs soft edges).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要设置的面索引；省略则全部面。", "Face indices to set; omit for all.", items="integer"),
        "group": i("平滑组编号 1-32。", "Smoothing group number 1-32.", minimum=1, maximum=32),
    },
    required=["group"],
))

TOOLS.append(tool(
    "poly_detach_faces", "modeling",
    "把所选面从原对象分离成一个（或克隆出）新对象。name 为新建对象名。",
    "Detach the selected faces into a new object (or clone them into one). name is the new "
    "object's name.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要分离的面索引。", "Face indices to detach.", items="integer"),
        "name": s("新建对象名。", "Name of the new object."),
        "clone": b("是否克隆（保留原面），默认否。", "Clone instead of moving (keep originals), default false."),
    },
    required=["faces", "name"],
))


# ============================================================ poly edge edit
TOOLS.append(tool(
    "poly_chamfer_edges", "modeling",
    "对边做倒角，切出一条宽度可控的边带。常用于硬边圆角。",
    "Chamfer edges, cutting a controllable-width edge strip. Good for rounded hard edges.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "edges": arr("要倒角的边索引列表。", "Edge indices to chamfer.", items="integer"),
        "amount": n("倒角宽度。", "Chamfer amount."),
    },
    required=["edges"],
))

TOOLS.append(tool(
    "poly_connect_edges", "modeling",
    "在所选边之间连接（插入）新边/边环，segments 控制插入条数。用于加密网格、加支撑边。",
    "Connect (insert) new edges between the selected edges; segments sets how many. Use it to "
    "densify the mesh or add support loops.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "edges": arr("参与连接的边索引列表。", "Edge indices to connect.", items="integer"),
        "segments": i("插入的边数，默认 1。", "Number of inserted edges, default 1.", minimum=1),
    },
    required=["edges"],
))

TOOLS.append(tool(
    "poly_extrude_edges", "modeling",
    "沿边法线挤出边，生成带状几何（如做墙裙、边框）。amount 控制挤出高度。",
    "Extrude edges along their normals, producing strip geometry (e.g. skirting, borders). "
    "Amount controls the height.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "edges": arr("要挤出的边索引列表。", "Edge indices to extrude.", items="integer"),
        "amount": n("挤出高度。", "Extrusion height."),
        "direction": num3("自定义挤出方向 [x,y,z]，省略则用边法线。",
                          "Custom extrude direction [x,y,z]; omit for edge normal."),
    },
    required=["edges", "amount"],
))

TOOLS.append(tool(
    "poly_loop_select", "modeling",
    "选择给定边所在的循环（loop），并保留边子对象选择。常用于快速选一圈环形边。",
    "Select the edge loop containing the given edges and keep the edge sub-object selection. "
    "Quick way to grab a ring of edges around a model.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "edges": arr("作为种子的边索引；省略则尝试全部边。",
                     "Seed edge indices; omit to try all edges.", items="integer"),
    },
    mutating=True,
))

TOOLS.append(tool(
    "poly_ring_select", "modeling",
    "选择给定边所在的环（ring），并保留边子对象选择。与 poly_loop_select 垂直互补。",
    "Select the edge ring containing the given edges and keep the edge sub-object selection. "
    "Complementary and perpendicular to poly_loop_select.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "edges": arr("作为种子的边索引；省略则尝试全部边。",
                     "Seed edge indices; omit to try all edges.", items="integer"),
    },
    mutating=True,
))

TOOLS.append(tool(
    "poly_slice", "modeling",
    "用一个平面切割多边形对象（沿 x/y/z 轴、可平移 offset）。split 为真时把切出的面分成两组。",
    "Slice a polygon object with a plane aligned to the x/y/z axis, shifted by offset. With "
    "split true the cut faces are split into two groups.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "axis": s("切割平面法线轴：x / y / z，默认 z。",
                  "Plane normal axis: x / y / z, default z.", enum=["x", "y", "z"]),
        "offset": n("平面沿轴的偏移（场景单位）。", "Plane offset along the axis (scene units)."),
        "split": b("是否把切面分成两组，默认否。", "Split the cut faces into two groups, default false."),
    },
))


# ============================================================ poly overall edit
TOOLS.append(tool(
    "poly_triangulate", "modeling",
    "把所选面三角化（每个多边形切成三角形）。游戏/实时引擎通常要求三角面。",
    "Triangulate the selected faces (split each polygon into triangles). Real-time/game "
    "engines generally require triangles.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要三角化的面索引；省略则全部面。", "Face indices to triangulate; omit for all.", items="integer"),
    },
))

TOOLS.append(tool(
    "poly_quadify", "modeling",
    "把三角形合并为四边形（尽可能），得到更规整的拓扑。不是所有三角网都能四边化。",
    "Merge triangles into quads where possible, yielding cleaner topology. Not every triangle "
    "mesh can be quadified.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要四边化的面索引；省略则全部面。", "Face indices to quadify; omit for all.", items="integer"),
    },
))

TOOLS.append(tool(
    "poly_subdivide", "modeling",
    "通过细分修改器（MeshSmooth）加密网格，iterations 为细分次数。"
    "iterations 超过 3 会让面数爆炸式增长，游戏资产建议 1-2。",
    "Subdivide the mesh via the MeshSmooth modifier; iterations is the subdivision count. "
    "Iterations above 3 explode the polygon count - keep it 1-2 for game assets.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "iterations": i("细分次数，默认 1。", "Subdivision iterations, default 1.", minimum=0, maximum=6),
        "smoothness": n("平滑度 0-1，默认 0.5。", "Smoothness 0-1, default 0.5."),
    },
))

TOOLS.append(tool(
    "poly_optimize", "modeling",
    "用 ProOptimizer 按百分比简化模型，percent 为保留的顶点百分比（0-100）。"
    "会明显改变形状，雕刻/高精度模型慎用。",
    "Simplify the model with ProOptimizer by a percentage; percent is the kept vertex "
    "percentage (0-100). This visibly changes the shape - use care on sculpted/high-detail meshes.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "percent": n("保留顶点百分比 0-100，默认 50。", "Kept vertex percentage 0-100, default 50.",
                     minimum=0.0, maximum=100.0),
        "keepNormals": b("保留法线，默认是。", "Keep normals, default true."),
    },
))

TOOLS.append(tool(
    "poly_relax", "modeling",
    "用 Relax 修改器松弛顶点，减少褶皱、均匀网格。iterations 为迭代次数。",
    "Relax vertices via the Relax modifier to reduce wrinkles and even out the mesh. "
    "iterations is the pass count.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "iterations": i("迭代次数，默认 1。", "Iterations, default 1.", minimum=1, maximum=20),
        "relaxValue": n("松弛强度 0-1，默认 0.5。", "Relax strength 0-1, default 0.5."),
        "keepBoundary": b("保持边界点不动，默认是。", "Keep boundary points fixed, default true."),
    },
))

TOOLS.append(tool(
    "poly_auto_smooth", "modeling",
    "按夹角自动计算平滑组：面法线夹角小于 angle 的相邻面平滑过渡。等效于 3ds Max 的 Auto Smooth。",
    "Auto-compute smoothing groups by angle: adjacent faces whose normals differ by less than "
    "angle are shaded smoothly. Equivalent to 3ds Max Auto Smooth.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "angle": n("平滑阈值角度（度），默认 45。", "Smoothing threshold angle in degrees, default 45.",
                  minimum=0.0, maximum=180.0),
        "faces": arr("作用的面索引；省略则全部面。", "Face indices to affect; omit for all.", items="integer"),
    },
    required=["angle"],
))

TOOLS.append(tool(
    "poly_unify_normals", "modeling",
    "统一所选面的法线方向（全部翻成一致朝向），修正法线紊乱导致的花面。",
    "Unify the normals of the selected faces (flip them to a consistent direction), fixing "
    "broken shading from inconsistent normals.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要统一的面索引；省略则全部面。", "Face indices to unify; omit for all.", items="integer"),
    },
))

TOOLS.append(tool(
    "poly_make_planar", "modeling",
    "把所选面投影到同一平面（make planar），常用于修正歪斜的平面、对齐切割口。",
    "Project the selected faces onto a single plane (make planar). Handy for fixing skewed "
    "surfaces or aligning cut openings.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "faces": arr("要拍平的面索引；省略则全部面。", "Face indices to flatten; omit for all.", items="integer"),
    },
))


# ============================================================ modifier stack
TOOLS.append(tool(
    "mod_add", "modeling",
    "给对象添加一个修改器。修改器名用 3ds Max 类名，例如 Bend、TurboSmooth、Shell。"
    "新增的顶层参数（非 objects/name/params）会作为该修改器的属性被设置。"
    "mod_add 追加到堆栈顶部；要用 mod_reorder 把它移到已有修改器下方。",
    "Add a modifier to an object. Use the 3ds Max class name, e.g. Bend, TurboSmooth, Shell. "
    "Any extra top-level parameter (other than objects/name/params) is applied to the new "
    "modifier as a property. mod_add appends to the top of the stack; use mod_reorder to move "
    "it below existing modifiers.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器类名。", "Modifier class name.", examples=["Bend", "TurboSmooth", "Shell"]),
        "name": s("给修改器起的名字。", "Name to give the modifier."),
        "params": arr("可选的属性名->值对象，批量设置修改器参数。",
                      "Optional name->value object to set modifier parameters in bulk."),
    },
    required=["modifier"],
))

TOOLS.append(tool(
    "mod_remove", "modeling",
    "从对象上删除一个修改器。modifier 可用修改器名、类名或堆栈索引（从 1 开始）。",
    "Remove a modifier from an object. modifier may be the modifier name, class name or stack "
    "index (1-based).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
    },
    required=["modifier"],
))

TOOLS.append(tool(
    "mod_list", "modeling",
    "列出对象修改器堆栈：索引、名称、类名、是否启用。分页返回。",
    "List an object's modifier stack: index, name, class and whether it is enabled. Paginated.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "limit": i("最多返回条数，0 表示全部。", "Maximum entries, 0 for all."),
        "offset": i("跳过的条数（分页）。", "Entries to skip (pagination)."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "mod_get_params", "modeling",
    "列出某个修改器的全部可读写属性及当前值（按实例读取）。分页返回。",
    "List every readable/writable property of a modifier with its current value (read from "
    "the instance). Paginated.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
        "limit": i("最多返回条数，0 表示全部。", "Maximum entries, 0 for all."),
        "offset": i("跳过的条数（分页）。", "Entries to skip (pagination)."),
    },
    required=["modifier"],
    mutating=False,
))

TOOLS.append(tool(
    "mod_set_param", "modeling",
    "设置某个修改器的单个参数（param=value）。值按目标属性类型自动转换。",
    "Set a single parameter of a modifier (param=value). The value is coerced to the target "
    "property type.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
        "param": s("要设置的属性名。", "Property name to set."),
        "value": s("新值（字符串形式，类型自动转换）。",
                  "New value as a string; type is coerced automatically."),
    },
    required=["modifier", "param", "value"],
))

TOOLS.append(tool(
    "mod_set_params", "modeling",
    "批量设置某个修改器的多个参数，params 为属性名->值对象。",
    "Set several parameters of a modifier at once; params is a name->value object.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
        "params": arr("属性名->值对象。", "Name->value object."),
    },
    required=["modifier", "params"],
))

TOOLS.append(tool(
    "mod_enable", "modeling",
    "启用（显示效果）指定修改器。",
    "Enable (make effective) the named modifier.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
    },
    required=["modifier"],
))

TOOLS.append(tool(
    "mod_disable", "modeling",
    "禁用（保留但不生效）指定修改器。",
    "Disable (keep but make ineffective) the named modifier.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
    },
    required=["modifier"],
))

TOOLS.append(tool(
    "mod_reorder", "modeling",
    "把修改器移动到堆栈的指定位置（index 从 1 开始，1 为最底部/离基础最近）。"
    "修改器顺序会显著改变最终效果。",
    "Move a modifier to a stack position (index 1-based, 1 is the bottom / closest to the "
    "base). Order strongly affects the final result.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
        "index": i("目标位置（从 1 开始）。", "Target position (1-based).", minimum=1),
    },
    required=["modifier", "index"],
))

TOOLS.append(tool(
    "mod_rename", "modeling",
    "重命名对象上的一个修改器（便于在 mod_get_params 等命令里按名字引用）。",
    "Rename a modifier on an object so it can later be referenced by name in mod_get_params etc.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("要重命名的修改器名/类名/索引。", "Modifier to rename (name / class / index)."),
        "name": s("新名字。", "New name."),
    },
    required=["modifier", "name"],
))

TOOLS.append(tool(
    "mod_get_gizmo_info", "modeling",
    "返回修改器的 Gizmo（变换控制器）位置/旋转/缩放；没有 Gizmo 的修改器返回 hasGizmo=false。",
    "Return a modifier's Gizmo (transform gizmo) position/rotation/scale; modifiers without a "
    "gizmo return hasGizmo=false.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
    },
    required=["modifier"],
    mutating=False,
))

TOOLS.append(tool(
    "mod_set_sub_object_selection", "modeling",
    "设置某个修改器的子对象层级（level）与选择（selection，顶点/边/面/控制点的索引）。"
    "常用于 FFD 控制点、Edit Poly 子对象等需要选中子元素的修改器。",
    "Set a modifier's sub-object level and selection (indices of verts/edges/faces/control "
    "points). Used for modifiers that need a sub-element selection, e.g. FFD control points "
    "or Edit Poly sub-objects.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
        "level": i("子对象层级（0=关，1=顶点，2=边，3=边界，4=面，5=元素，FFD 用 1=控制点）。",
                   "Sub-object level (0 off, 1 vert, 2 edge, 3 border, 4 face, 5 elem; FFD uses 1=CP)."),
        "selection": arr("要选中的子对象索引。", "Sub-object indices to select.", items="integer"),
    },
    required=["modifier"],
))

TOOLS.append(tool(
    "mod_toggle", "modeling",
    "切换指定修改器的启用状态（启用变禁用、禁用变启用），返回切换前后的状态并回读验证。"
    "需要显式启用或禁用时用 mod_enable / mod_disable。",
    "Toggle a modifier's enabled state (on becomes off and vice versa). The state before and "
    "after is reported and verified by reading it back. Use mod_enable / mod_disable when you "
    "need an explicit state.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("修改器名/类名/索引。", "Modifier name / class name / index."),
    },
    required=["modifier"],
))

TOOLS.append(tool(
    "mod_collapse", "modeling",
    "显式塌陷（烘焙）对象的整个修改器堆栈。**此操作不可逆：所有修改器参数将永久丢失，"
    "子对象编辑数据也会被烘焙。** 必须显式传入 confirm=true 才会执行；"
    "可选用 modifier 指定堆栈中必须存在的修改器作为过滤条件（防止误操作其他对象）。"
    "只需塌陷到某个修改器为止的「部分塌陷」在 MAXScript 中不可用，会返回明确错误而不是假装成功。",
    "Explicitly collapse (bake) an object's whole modifier stack. **Irreversible: every "
    "modifier parameter is lost for good and sub-object edits get baked in.** Only runs when "
    "confirm=true is passed explicitly; the optional modifier argument acts as a filter (the "
    "named modifier must exist) so a batch call never touches the wrong object. "
    "Partial collapse (down to one modifier) is not available in MAXScript and fails loudly "
    "instead of pretending to work.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection.", items="string"),
        "modifier": s("可选：堆栈中必须存在的修改器名/类名/索引，作为批量操作的安全过滤条件。",
                      "Optional: a modifier (name/class/index) that must exist on the stack, "
                      "used as a safety filter for batch calls."),
        "confirm": b("必须为 true 才会执行塌陷。默认 false（拒绝执行）。",
                     "Must be true for the collapse to run. Default false (refused)."),
    },
    required=["confirm"],
))


# ============================================================ specific modifiers
def _mod(name: str, className: str, zh: str, en: str,
         props: dict, required=None) -> Tool:
    """Thin wrapper: bridge to mod_add with a `modifier` preset.

    The MAXScript mod_add applies any extra top-level parameter as a property of
    the new modifier, so each specific modifier only needs to declare its params.
    """
    return tool(name, "modeling", zh, en, props=props, required=required or [],
                bridge="mod_add", preset={"modifier": className})


TOOLS.append(_mod(
    "mod_turbosmooth", "TurboSmooth",
    "涡轮平滑（非破坏性细分）。iterations 为视口细分次数，renderIterations 为渲染细分次数。"
    "游戏资产建议视口 1 / 渲染 2，iterations 过高面数爆炸。",
    "TurboSmooth (non-destructive subdivision). iterations is the viewport subdivision count, "
    "renderIterations the render count. For game assets keep viewport 1 / render 2; high "
    "iterations explode the polygon count.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "iterations": i("视口迭代次数，默认 1。", "Viewport iterations, default 1.", minimum=0, maximum=6),
        "renderIterations": i("渲染迭代次数，默认 2。", "Render iterations, default 2.", minimum=0, maximum=6),
        "smoothness": n("平滑度 0-1，默认 1.0。", "Smoothness 0-1, default 1.0."),
        "isNURMS": b("使用 NURMS 细分，默认是。", "Use NURMS subdivision, default true."),
    },
))

TOOLS.append(_mod(
    "mod_bend", "Bend",
    "弯曲修改器：沿 axis 轴把物体弯 angle 度，direction 控制弯曲平面方向。",
    "Bend modifier: bend the object by angle degrees around axis; direction sets the bend plane.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "angle": n("弯曲角度（度）。", "Bend angle in degrees."),
        "direction": n("弯曲方向（度）。", "Bend direction in degrees."),
        "axis": i("弯曲轴 0=X/1=Y/2=Z，默认 0。", "Bend axis 0=X/1=Y/2=Z, default 0.", minimum=0, maximum=2),
        "limit": b("启用上下限，默认否。", "Enable upper/lower limits, default false."),
    },
))

TOOLS.append(_mod(
    "mod_taper", "Taper",
    "锥化修改器：沿 axis 轴按 amount 缩放截面（一端粗一端细）。",
    "Taper modifier: scale the cross-section along axis by amount (thick at one end, thin at the other).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "amount": n("锥化量。", "Taper amount."),
        "direction": n("方向（度）。", "Direction in degrees."),
        "axis": i("轴 0=X/1=Y/2=Z，默认 2。", "Axis 0=X/1=Y/2=Z, default 2.", minimum=0, maximum=2),
        "limit": b("启用上下限，默认否。", "Enable limits, default false."),
    },
))

TOOLS.append(_mod(
    "mod_twist", "Twist",
    "扭转修改器：沿 axis 轴把物体扭转 angle 度，bias 控制扭转在长度上的分布。",
    "Twist modifier: rotate the object along axis by angle degrees; bias controls how the "
    "twist is distributed along the length.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "angle": n("扭转角度（度）。", "Twist angle in degrees."),
        "bias": n("扭转偏置 -1..1。", "Twist bias -1..1."),
        "axis": i("轴 0=X/1=Y/2=Z，默认 2。", "Axis 0=X/1=Y/2=Z, default 2.", minimum=0, maximum=2),
        "limit": b("启用上下限，默认否。", "Enable limits, default false."),
    },
))

TOOLS.append(_mod(
    "mod_noise", "Noise",
    "噪声修改器：用分形噪声沿 x/y/z 扰动顶点。fractal 开启更有细节，roughness 控制分形粗糙度。",
    "Noise modifier: displace vertices along x/y/z with fractal noise. fractal adds detail; "
    "roughness controls fractal roughness.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "scale": n("噪声频率（越小越细碎），默认 100。", "Noise frequency (smaller = finer), default 100."),
        "fractal": b("使用分形噪声，默认否。", "Use fractal noise, default false."),
        "roughness": n("分形粗糙度 0-1。", "Fractal roughness 0-1."),
        "xStrength": n("X 方向强度。", "X strength."),
        "yStrength": n("Y 方向强度。", "Y strength."),
        "zStrength": n("Z 方向强度。", "Z strength."),
    },
))

TOOLS.append(_mod(
    "mod_ffd_2x2x2", "FFD_2x2x2",
    "自由变形修改器 2x2x2：用 8 个控制点变形对象。移动控制点（mod_set_sub_object_selection）即可塑形。",
    "Free-form deform 2x2x2: deform the object with 8 control points. Move them via "
    "mod_set_sub_object_selection to sculpt.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "autoExtent": b("自动适配对象范围，默认是。", "Auto-fit to object extent, default true."),
    },
))

TOOLS.append(_mod(
    "mod_ffd_3x3x3", "FFD_3x3x3",
    "自由变形修改器 3x3x3：27 个控制点，比 2x2x2 更细腻。",
    "Free-form deform 3x3x3: 27 control points, finer than 2x2x2.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "autoExtent": b("自动适配对象范围，默认是。", "Auto-fit to object extent, default true."),
    },
))

TOOLS.append(_mod(
    "mod_ffd_4x4x4", "FFD_4x4x4",
    "自由变形修改器 4x4x4：64 个控制点，最细腻的 FFD。",
    "Free-form deform 4x4x4: 64 control points, the finest FFD.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "autoExtent": b("自动适配对象范围，默认是。", "Auto-fit to object extent, default true."),
    },
))

TOOLS.append(_mod(
    "mod_shell", "Shell",
    "壳修改器：给表面加厚度，生成内壁（outerAmount）与外壁（innerAmount）。常用于做实体、管壁。",
    "Shell modifier: give a surface thickness with an outer wall (outerAmount) and inner wall "
    "(innerAmount). Use it to make solids or tube walls.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "innerAmount": n("内壁厚度（向内）。", "Inner wall thickness (inward)."),
        "outerAmount": n("外壁厚度（向外）。", "Outer wall thickness (outward)."),
    },
))

TOOLS.append(_mod(
    "mod_chamfer", "Chamfer",
    "倒角修改器（Chamfer）：对整个对象的所有边做统一倒角，是硬表面圆角最常用的修改器。"
    "amount 为倒角宽度，segments 为倒角分段（>=2 得到圆角），openEdges 控制开放边的处理方式。"
    "若当前 3ds Max 版本没有该修改器类，会返回明确错误。",
    "Chamfer modifier: uniformly chamfers every edge of the object - the standard tool for "
    "hard-surface rounding. amount is the chamfer width, segments the segment count (>=2 gives "
    "a rounded corner), openEdges controls how open edges are treated. "
    "Returns a clear error when the class is unavailable on this 3ds Max version.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "amount": n("倒角宽度。", "Chamfer width."),
        "segments": i("倒角分段数，默认 1。", "Chamfer segments, default 1.", minimum=1),
        "openEdges": i("开放边处理：0=保持开放，1=封口，默认 0。",
                       "Open edges: 0=keep open, 1=cap, default 0.", minimum=0, maximum=1),
        "smoothOnIntersections": b("相交处平滑，默认是。", "Smooth on intersections, default true."),
    },
))

TOOLS.append(_mod(
    "mod_symmetry", "Symmetry",
    "对称修改器：沿 axis 轴镜像对象并焊接接缝（weldSeam）。做角色左右对称时很方便。",
    "Symmetry modifier: mirror the object across axis and weld the seam (weldSeam). Handy for "
    "left/right symmetric characters.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "axis": i("对称轴 0=X/1=Y/2=Z，默认 0。", "Mirror axis 0=X/1=Y/2=Z, default 0.", minimum=0, maximum=2),
        "flip": b("翻转镜像方向，默认否。", "Flip mirror direction, default false."),
        "threshold": n("焊接阈值（场景单位）。", "Weld threshold (scene units)."),
        "weldSeam": b("焊接接缝，默认是。", "Weld seam, default true."),
    },
))

TOOLS.append(_mod(
    "mod_displace", "Displace",
    "置换修改器：按强度 strength 沿法线推开顶点（需配合贴图/灰度图才有丰富形状；纯强度为均匀外扩）。",
    "Displace modifier: push vertices along normals by strength (needs a map/grayscale to get "
    "rich shapes; pure strength just inflates uniformly).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "strength": n("置换强度。", "Displace strength."),
        "decay": n("衰减（距离内强度衰减）。", "Decay (strength falls off with distance)."),
    },
))

TOOLS.append(_mod(
    "mod_relax", "Relax",
    "松弛修改器：迭代地把顶点拉向邻居平均位置，平滑网格、消除褶皱。",
    "Relax modifier: iteratively pull vertices toward their neighbours' average, smoothing the "
    "mesh and removing wrinkles.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "relaxValue": n("松弛强度 0-1，默认 0.5。", "Relax strength 0-1, default 0.5."),
        "iterations": i("迭代次数，默认 1。", "Iterations, default 1.", minimum=1, maximum=20),
        "keepBoundary": b("保持边界点不动，默认是。", "Keep boundary points fixed, default true."),
    },
))

TOOLS.append(_mod(
    "mod_subdivide", "Subdivide",
    "细分修改器：按 size 把每个面细分为更小的面（经典细分，不改平滑度）。",
    "Subdivide modifier: split each face into smaller faces by size (classic subdivision, no "
    "smoothing change).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "size": n("细分尺寸（场景单位）。", "Subdivision size (scene units)."),
        "method": i("方法 0=经典/1=四边形，默认 0。", "Method 0=classic/1=quad, default 0.", minimum=0, maximum=1),
    },
))

TOOLS.append(_mod(
    "mod_extrude", "Extrude",
    "挤出修改器：把剖面/面沿轴挤出成实体。amount 为高度，segments 为分段，capStart/capEnd 控制两端封口。",
    "Extrude modifier: push a profile/face into a solid along an axis. amount is the height, "
    "segments the divisions, capStart/capEnd toggle end caps.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "amount": n("挤出高度。", "Extrusion height."),
        "segments": i("分段数，默认 1。", "Segment count, default 1.", minimum=1),
        "outline": n("轮廓外扩/内收。", "Outline expand/inset."),
        "capStart": b("封口起始端，默认是。", "Cap the start, default true."),
        "capEnd": b("封口结束端，默认是。", "Cap the end, default true."),
    },
))

TOOLS.append(_mod(
    "mod_lathe", "Lathe",
    "车削修改器：把剖面绕轴旋转成回转体（瓶、柱、碗）。degrees 默认 360 成闭环。",
    "Lathe modifier: revolve a profile around an axis into a solid of revolution (bottles, "
    "columns, bowls). degrees defaults to 360 for a closed object.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "degrees": n("旋转角度（度），默认 360。", "Revolve angle in degrees, default 360."),
        "segments": i("旋转分段，默认 16。", "Revolve segments, default 16.", minimum=3),
        "smooth": b("平滑着色，默认是。", "Smooth shading, default true."),
        "flipNormals": b("翻转法线，默认否。", "Flip normals, default false."),
        "weldCore": b("焊接轴心，默认是。", "Weld the core, default true."),
    },
))

TOOLS.append(_mod(
    "mod_sweep", "Sweep",
    "扫掠修改器：沿路径扫一个截面成形。本工具仅添加修改器；如需自定义截面，用 model_sweep 并指定 section。",
    "Sweep modifier: sweep a section along a path. This tool only adds the modifier; for a "
    "custom section use model_sweep with a `section` name.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
    },
))

TOOLS.append(_mod(
    "mod_pathdeform", "PathDeform",
    "路径变形修改器：让对象沿一条路径（path）变形。percent 为路径位置百分比，twist/rotation 控制扭转与旋转。",
    "PathDeform modifier: deform an object along a path. percent is the position along the "
    "path (0-100), twist/rotation add twist and rotation.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "percent": n("路径位置百分比 0-100。", "Position along path, percent 0-100."),
        "rotation": n("旋转（度）。", "Rotation in degrees."),
        "twist": n("扭转（度）。", "Twist in degrees."),
        "axis": i("变形轴 0=X/1=Y/2=Z，默认 2。", "Deform axis 0=X/1=Y/2=Z, default 2.", minimum=0, maximum=2),
    },
))

TOOLS.append(_mod(
    "mod_weightednormals", "WeightedNormals",
    "加权法线修改器：按面面积加权计算顶点法线，硬表面/低模烘焙法线时常用，比平滑更硬朗。",
    "Weighted Normals modifier: compute vertex normals weighted by face area. Common for hard-"
    "surface / low-poly normal bakes; gives a crisper look than smoothing.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "threshold": n("权重阈值（度）。", "Weight threshold in degrees."),
        "keepAffine": b("保持仿射，默认否。", "Keep affine, default false."),
        "weightByArea": b("按面积加权，默认是。", "Weight by area, default true."),
    },
))

TOOLS.append(_mod(
    "mod_editpoly", "Edit_Poly",
    "编辑多边形修改器：把多边形编辑能力作为非破坏性修改器加入堆栈（之后可用 poly_* 思路配合子对象选择操作）。",
    "Edit Poly modifier: add non-destructive polygon editing to the stack (afterwards drive it "
    "with sub-object selections like the poly_* tools).",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
    },
))

TOOLS.append(_mod(
    "mod_editnormals", "Edit_Normals",
    "编辑法线修改器：显式控制每个顶点的法线（可拆开/指定），常用于法线修复与硬边定制。",
    "Edit Normals modifier: explicit per-vertex normal control (break/assign), used for normal "
    "fixing and custom hard edges.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
    },
))

TOOLS.append(_mod(
    "mod_smooth", "Smooth",
    "平滑修改器：按阈值自动平滑（autoSmooth）或按角度平滑组平滑，柔化表面。",
    "Smooth modifier: auto-smooth by a threshold (autoSmooth) or smooth by angle, softening "
    "the surface.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。", "Object names; omit for selection.", items="string"),
        "name": s("修改器名。", "Modifier name."),
        "smoothness": n("平滑度 0-1。", "Smoothness 0-1."),
        "threshold": n("平滑阈值（角度）。", "Smooth threshold (angle)."),
        "autoSmooth": b("按阈值自动平滑，默认否。", "Auto-smooth by threshold, default false."),
    },
))


# ============================================================ spline driven geometry
TOOLS.append(tool(
    "model_extrude_spline", "modeling",
    "把样条线（图形）沿轴挤出成三维实体（添加 Extrude 修改器）。amount 为高度。",
    "Extrude a spline (shape) into a 3D solid along an axis by adding an Extrude modifier. "
    "amount is the height.",
    props={
        "objects": arr("样条线对象名列表；省略则使用当前选择。",
                       "Spline (shape) names; omit for selection.", items="string"),
        "amount": n("挤出高度。", "Extrusion height."),
        "segments": i("分段数，默认 1。", "Segment count, default 1.", minimum=1),
        "capStart": b("封口起始端，默认是。", "Cap the start, default true."),
        "capEnd": b("封口结束端，默认是。", "Cap the end, default true."),
    },
    required=["amount"],
))

TOOLS.append(tool(
    "model_lathe_spline", "modeling",
    "把样条线绕轴旋转成回转体（添加 Lathe 修改器）。截面应是 2D 轮廓线。",
    "Revolve a spline around an axis into a solid of revolution by adding a Lathe modifier. The "
    "profile should be a 2D outline.",
    props={
        "objects": arr("样条线对象名列表；省略则使用当前选择。",
                       "Spline (shape) names; omit for selection.", items="string"),
        "degrees": n("旋转角度（度），默认 360。", "Revolve angle in degrees, default 360."),
        "segments": i("旋转分段，默认 16。", "Revolve segments, default 16.", minimum=3),
        "smooth": b("平滑着色，默认是。", "Smooth shading, default true."),
        "flipNormals": b("翻转法线，默认否。", "Flip normals, default false."),
        "weldCore": b("焊接轴心，默认是。", "Weld the core, default true."),
    },
))

TOOLS.append(tool(
    "model_loft", "modeling",
    "放样（Loft 复合对象）：用一条 path 样条作路径，一个或多个 shapes 作截面，扫出复杂曲面。"
    "path 与 shapes 都必须是已存在的图形对象名。",
    "Loft compound object: use a `path` spline as the path and one or more `shapes` as "
    "cross-sections to sweep a complex surface. Both path and shapes must be existing shape names.",
    props={
        "path": s("路径样条线对象名。", "Path spline object name."),
        "shapes": arr("截面样条线对象名列表（至少一个）。",
                      "Cross-section shape names (at least one).", items="string"),
        "name": s("新建放样对象名。", "Name of the new loft object."),
    },
    required=["path", "shapes"],
))

TOOLS.append(tool(
    "model_sweep", "modeling",
    "扫掠：沿路径样条扫一个截面（section）成形，添加 Sweep 修改器。"
    "省略 section 时使用默认矩形截面。section 必须是已存在的图形对象名。",
    "Sweep: sweep a `section` profile along a path spline by adding a Sweep modifier. With no "
    "section a default rectangular profile is used. section must be an existing shape name.",
    props={
        "objects": arr("路径样条线对象名列表；省略则使用当前选择。",
                       "Path spline names; omit for selection.", items="string"),
        "section": s("截面样条线对象名（可选）。", "Section shape name (optional)."),
    },
))
