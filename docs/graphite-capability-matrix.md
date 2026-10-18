# Graphite Modeling Tools 能力矩阵（3ds Max 2020）

> 项目：3dsmax-mcp-plugin ｜ 日期：2026-10-18 ｜ 范围：Loop / Ring / Swift Loop / Cut / QuickSlice
> 性质：**只调研，不实现**。结论基于 Autodesk 官方 MAXScript 文档（2016–2018 版，API 在 2020 相同）、
> ScriptSpot 社区实践与 3ds Max 2020 的 PolyTools 架构。

---

## 0. 结论速览

| 工具 | 2020 是否存在 | 直接 MAXScript API | Action Manager / macros.run | 必须 UI 自动化 | 推荐方案 |
|---|---|---|---|---|---|
| Loop（选循环） | ✅ | ✅ `polyop.getEdgeLoop` | — | 否 | **已实现**：`poly_loop_select` |
| Ring（选环） | ✅ | ✅ `polyop.getEdgeRing` | — | 否 | **已实现**：`poly_ring_select` |
| Swift Loop | ✅ | ❌ 无 | ⚠️ `macros.run "PolyTools" "SwiftLoop"` 存在但为交互式，会阻塞/中断脚本 | 是（视口点击） | 脚本化等价：`polyop.divideEdge` + `polyop.createEdge`（+ 可选 SetFlow 近似） |
| Cut | ✅ | ✅ `polyop.cutVert` / `cutFace` / `cutEdge` | 有 Action Item 但交互式 | 否（用 API 可完全脚本化） | 新增 `poly_cut` 包装 polyop.cut* |
| QuickSlice | ✅ | ⚠️ 无专用 API；`polyop.slice`（任意平面）语义等价 | 交互式 | 否 | 扩展 `poly_slice` 支持任意平面法线/偏移 |

**PolyToolsModeling（GlobalUtilityPlugin，2011 起存在，2020 可用）已暴露 ~24 个 Graphite 方法**，
见 §3。注意：**SwiftLoop / Cut / QuickSlice 均不在其中**。

---

## 1. Loop / Ring 选择

| 维度 | 结论 |
|---|---|
| 2020 存在性 | 存在（Editable Poly / Edit Poly 的边子对象级；Graphite Loops 面板的 Loop/Ring 按钮） |
| MAXScript API | `polyop.getEdgeLoop <poly> <edgeBitArray>` → 返回整条循环的位数组；`polyop.getEdgeRing` 同理返回环 |
| Action Manager | 不需要 |
| UI 自动化 | 不需要 |
| 现状 | 已实现：`poly_loop_select` / `poly_ring_select`（mcp_poly.ms），种子边省略时用全部边 |
| 测试方法 | 建 10×10 分段 Plane → 转 EPoly → 选一条边跑 loop → 断言返回边数 = 10 且成环；ring 断言 = 10 |

**结论：无缺口。**

## 2. Swift Loop

| 维度 | 结论 |
|---|---|
| 2020 存在性 | 存在（Modeling Ribbon → Edit → Swift Loop；边子对象级交互工具） |
| 直接 API | **无**。`PolyToolsModeling` 没有 SwiftLoop 方法；polyop 也没有 |
| `macros.run "PolyTools" "SwiftLoop"` | 可调用，但工具进入交互模式等待视口点击，"awaits user input and / or cancels code execution"（社区实测）——**不能在无人值守脚本中使用** |
| Action Manager | Swift Loop 的 Action Item 同样只是触发同一个交互工具，无法参数化 |
| UI 自动化 | 可行但脆弱：需激活 Max 窗口 → 确保边子对象级 → 点击 Ribbon 按钮 → 在视口坐标点击 → 右键退出。屏幕坐标依赖布局/分辨率 |
| 推荐实现 | **脚本化等价**：Swift Loop 的本质 = 在边环上按位置插点并连成环：<br>1. 对目标边所在环（`getEdgeRing`）的每条边 `polyop.divideEdge poly edge t`（t 为插入比例）<br>2. 用 `polyop.createEdge` 连接新顶点成环<br>3. 可选：`PolyToolsModeling.SetFlow autoLoop:true` 拟合流线（2011+ API）<br>缺点：不理解"曲面流"的智能布点；复杂网格上结果与真工具有差距 |
| 自动化测试 | 20×20 分段 Plane → 脚本化插入一圈 → 断言边数增加且新边构成闭环；与真工具结果做目视比对（截图） |

## 3. Cut

| 维度 | 结论 |
|---|---|
| 2020 存在性 | 存在（Editable Poly 边子对象级 Cut；Graphite 也有 Cut） |
| 直接 API | **有，三个**：<br>`polyop.cutVert <poly> <int start_vert> <point3 destination> <point3 projdir> node:<node>`<br>`polyop.cutFace <poly> <int face> <point3 start> <point3 destination> <point3 projdir> node:<node>`<br>`polyop.cutEdge <poly> <int edge1> <float prop1> <int edge2> <float prop2> <point3 projdir> node:<node>`<br>返回新顶点索引（失败返回 undefined） |
| 坐标系 | 传 node 时 destination/projdir 用当前坐标系；只传 Editable_Poly 值时用局部坐标系。**调用方需显式约定** |
| Action Manager | 不需要 |
| UI 自动化 | 不需要 |
| 推荐实现 | 新增 `poly_cut`（参数：mode=vert/face/edge + 起终点/比例 + 投影方向）。注意与"Connect"的区别：Cut 是投影切割，CrossCut 社区脚本证明该 API 可稳定替代交互 Cut |
| 自动化测试 |  Plane 转 EPoly → cutEdge 横切 → 断言面数 +1、新顶点在边上；cutFace 在面内切 → 断言该面被分成两个 |

## 4. QuickSlice

| 维度 | 结论 |
|---|---|
| 2020 存在性 | 存在（Edit Geometry 卷展栏 → QuickSlice；也可在 Edit Poly 修改器上用） |
| 直接 API | **无专用 API**。QuickSlice 是"点击起点→拖拽→释放"的屏幕空间交互切片 |
| 语义等价 API | `polyop.slice <poly> <matrix3 plane> <edgeBitArray> split:<bool>` —— 接受**任意**平面（matrixFromNormal + row4 偏移），比现有 `poly_slice` 的轴对齐平面更通用；QuickSlice 的拖拽线在屏幕空间等价于一个过视口、法线为视方向的平面 |
| Action Manager | QuickSlice 有 Action Item，但同样是交互工具 |
| UI 自动化 | 不推荐 |
| 推荐实现 | **扩展 `poly_slice`**：增加 `normal:[x,y,z]` + `offset`（或 `planePoint`）参数，用 `matrixFromNormal` 构造任意平面后调 `polyop.slice`。这覆盖 QuickSlice 的绝大部分无人值守用例（按平面切分）；需要"屏幕空间拖拽"语义时再评估 UI 自动化 |
| 自动化测试 | Box → 斜平面 slice → 断言顶点/边数增加且切口平面方程一致；split:true → 断言元素数 2 |

## 5. PolyToolsModeling 已暴露方法清单（2011+，2020 可用）

可直接 `PolyToolsModeling.<Method>()` 调用，多数返回 bool（失败返回 false）。**类实例不可由 MAXScript 创建。**

| 面板 | 方法 | 子对象级 |
|---|---|---|
| Loops | `DistanceConnect()` | Edge/Vertex |
| Loops | `RemoveLoop()` | Poly/Edge/Vertex |
| Loops | `SetFlow(autoLoop)` / `SetFlowVertex()` | Edge/Vertex |
| Loops | `BuildEnd()` / `BuildCorner()` | Edge/Vertex |
| Loops | `RandomConnect(jitter, autoLoop)` | Edge |
| Edges | `SpinEdge(alternativeDir)` | Edge |
| Edges | `InsertVertex(number)` | Edge |
| Geometry | `Quadrify(withinSel, selectOnly)` | — |
| Polygons | `GeoPoly()` | Poly |
| Loop Tools | `CenterLoop` / `SpaceLoop` / `CurveLoop` / `StraightLoop` / `CircleLoop` / `RelaxLoop`（均带 autoLoop） | Edge 循环 |
| Symmetry | `SymmetryGather` / `SymmetryPosToNeg` / `SymmetryNegToPos` / `SymmetryFlip` / `SymmetryCopy` / `SymmetryPaste` | Vertex |
| Other | `MultiHide()` / `RotateSelection(degree, coordsys, viewDirection)` / `MirrorElement(axis, clone)` / `CreateFace(bitArray)` | 混合 |

另有 `PolyToolsPaintDeform` / `PolyToolsPolyDraw` / `PolyToolsSelect` / `PolyToolsShift` / `PolyToolsTopology` /
`PolyToolsUVWTweak` 等同族接口（Paint Deform、PolyDraw、选择、Shift、拓扑、UVW Tweak）。

## 6. 下一阶段建议（按投入产出排序）

1. **`poly_slice` 扩展任意平面**（小改动，直接扩大无人值守切片能力）— 对应 §4。
2. **新增 `poly_cut`**（包装 polyop.cutVert/cutFace/cutEdge，含坐标系文档）— 对应 §3。
3. **Swift Loop 脚本化等价**（divideEdge+createEdge，先在 Plane/Box 上验证拓扑正确性再推广）— 对应 §2。
4. **PolyToolsModeling 试点**：`SetFlow`、`RemoveLoop`、`BuildEnd/BuildCorner` 这类"选完边一次调用"的工具最适合 MCP 化；
   先各写一个最小验证脚本确认 2020 上可用（本机 Max 环境恢复后执行）。
5. **UI 自动化**：仅作为最后手段，且只对确无 API 的工具；需要先解决"激活窗口 + 坐标定位"的稳定性问题。

## 7. 未决问题

- 本机 3ds Max 2020 当前无法启动（启动即崩，见交付报告 §未解决问题），所有结论基于文档与社区验证，
  **尚未在本机实测**；建议环境恢复后按 §1–§4 的测试方法逐项验证。
- `polyop.getBorderSelection` / `setBorderSelection` 不存在（已由文档确认）；边界选择需用
  `polyop.getOpenEdges` / `getBorderFromEdge` 或 `Editable_Poly.ConvertSelection #Edge #Border` 近似。
- Swift Loop 脚本化等价在非平面/高曲率网格上的质量未验证。
