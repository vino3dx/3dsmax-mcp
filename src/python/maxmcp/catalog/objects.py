"""Objects catalog: primitives, splines, transforms, hierarchy, selection,
visibility and lifecycle, plus boolean ops.

Category key: ``objects``.

Every tool here has a matching ``mcpRegister "<name>"`` in ``max/mcp_objects.ms``.
Most primitive / spline wrappers are thin shells over a single generic MAXScript
handler driven by a ``preset={"class": "..."}`` so one handler serves many tools.
"""

from __future__ import annotations

from typing import Dict, List

from .schema import Tool, arr, b, i, n, num3, s, tool

TOOLS: List[Tool] = []


# ================================================================ shared props
def _prim_props() -> Dict[str, object]:
    """Dimension / placement properties accepted by every primitive wrapper.

    The MAXScript handler sets whichever of these are supplied (wrapped in
    try/catch so a version that lacks a property cannot throw).
    """
    return {
        "name": s("对象名称；省略则自动命名。", "Object name; auto-generated if omitted."),
        "position": num3("世界坐标位置 [x,y,z]。", "World position [x,y,z]."),
        "length": n("长度（Box/Plane/Rectangle/Cone 等）。分段数决定多边形数量，游戏资产保持 12-16。",
                    "Length (Box/Plane/Rectangle/Cone etc). Segments drive poly count - keep 12-16 for game assets."),
        "width": n("宽度。", "Width."),
        "height": n("高度。", "Height."),
        "depth": n("深度（Pyramid）。", "Depth (Pyramid)."),
        "radius": n("半径（Sphere/Torus/Cylinder 等）。", "Radius (Sphere/Torus/Cylinder etc)."),
        "radius1": n("第一半径（Donut/Tube/Helix/Cone 顶）。", "First radius (Donut/Tube/Helix/Cone top)."),
        "radius2": n("第二半径（Donut/Tube/Helix/Cone 底）。", "Second radius (Donut/Tube/Helix/Cone bottom)."),
        "segments": i("分段数；影响多边形数量，游戏资产保持低值。",
                      "Segment count; drives polygon count, keep low for game assets.", minimum=1),
        "sides": i("边数/管径向分段（Cylinder/Cone/NGon/Torus）。",
                  "Side / tube radial segments (Cylinder/Cone/NGon/Torus).", minimum=3),
        "chamfer": n("倒角量（ChamferBox）。", "Chamfer amount (ChamferBox)."),
        "fillet": n("圆角量（Capsule）。", "Fillet amount (Capsule)."),
        "turns": n("圈数（Helix）。", "Number of turns (Helix)."),
        "heightSegs": i("高度方向分段（Box/Cylinder/Cone）。", "Height segments (Box/Cylinder/Cone).", minimum=1),
        "widthSegs": i("宽度方向分段（Box/Plane）。", "Width segments (Box/Plane).", minimum=1),
        "lengthSegs": i("长度方向分段（Box/Plane）。", "Length segments (Box/Plane).", minimum=1),
        "capSegs": i("封顶分段（Cylinder/Cone/Tube）。", "Cap segments (Cylinder/Cone/Tube).", minimum=1),
        "cornerRadius": n("圆角半径（Rectangle）。", "Corner radius (Rectangle)."),
        "from": n("起始角（度，Arc）。", "Start angle in degrees (Arc)."),
        "to": n("结束角（度，Arc）。", "End angle in degrees (Arc)."),
        "smooth": b("是否平滑（Teapot 等）。", "Smooth the surface (Teapot etc)."),
        "axis": i("壶轴类型 1-4（Teapot）；忽略通常即可。", "Teapot axis 1-4; usually leave default."),
        "setName": s("创建后再改名为此名（name 的兜底写法）。", "Rename after creation (fallback for name)."),
    }


def _spline_props() -> Dict[str, object]:
    return {
        "name": s("图形名称；省略则自动命名。", "Shape name; auto-generated if omitted."),
        "position": num3("位置 [x,y,z]。", "Position [x,y,z]."),
        "length": n("长度（Rectangle/Ellipse）。", "Length (Rectangle/Ellipse)."),
        "width": n("宽度（Rectangle/Ellipse）。", "Width (Rectangle/Ellipse)."),
        "radius": n("半径（Circle/Arc/NGon）。", "Radius (Circle/Arc/NGon)."),
        "radius1": n("第一半径（Donut）。", "First radius (Donut)."),
        "radius2": n("第二半径（Donut）。", "Second radius (Donut)."),
        "sides": i("边数（NGon，至少 3）。", "Side count (NGon, >=3).", minimum=3),
        "segments": i("分段数。", "Segment count."),
        "height": n("高度（Helix）。", "Height (Helix)."),
        "turns": n("圈数（Helix）。", "Turns (Helix)."),
        "from": n("起始角（度，Arc）。", "Start angle in degrees (Arc)."),
        "to": n("结束角（度，Arc）。", "End angle in degrees (Arc)."),
        "cornerRadius": n("圆角半径（Rectangle）。", "Corner radius (Rectangle)."),
        "text": s("文本内容（Text）。", "Text content (Text)."),
        "size": n("字号（Text，对应 size 属性）。", "Font size (Text, maps to size)."),
        "thickness": n("描边粗细（Text）。", "Stroke thickness (Text)."),
    }


# ================================================================== primitives
TOOLS.append(tool(
    "create_primitive", "objects",
    "按类名创建一个 3ds Max 基础体（Box/Sphere/Cylinder/Cone/ChamferBox/Capsule 等）。"
    "不熟悉的类先用 does_class_exist 探测是否可用。**分段数越高多边形越多，游戏资产保持 12-16。**",
    "Create any 3ds Max primitive by class name (Box/Sphere/Cylinder/Cone/ChamferBox/Capsule...). "
    "Probe availability with does_class_exist for unfamiliar classes first. "
    "**Higher segments mean more polygons; keep 12-16 for game assets.**",
    props=dict(_prim_props(), **{
        "class": s("3ds Max 基础体类名，例如 Box、Sphere、ChamferBox、Capsule。",
                  "3ds Max primitive class name, e.g. Box, Sphere, ChamferBox, Capsule.",
                  examples=["Box", "Sphere", "ChamferBox", "Capsule"]),
    }),
    required=["class"],
))


def _prim(name: str, cls: str, zh: str, en: str, extra: Dict[str, object] = None) -> None:
    props = _prim_props()
    if extra:
        props.update(extra)
    TOOLS.append(tool(name, "objects", zh, en, props=props, preset={"class": cls}))


_prim("create_box", "Box",
      "创建一个长方体。长度/宽度/高度可分别设分段；游戏资产分段保持 12-16，烘焙法线前用 reset_transform 清掉非均匀缩放。",
      "Create a box. Set length/width/height and their segment counts; keep 12-16 segments for game assets and call reset_transform before baking normals to clear non-uniform scale.")
_prim("create_sphere", "Sphere",
      "创建一个球体。segments 与 sides 共同决定多边形数，游戏资产保持低值。",
      "Create a sphere. segments and sides together drive polygon count; keep low for game assets.")
_prim("create_cylinder", "Cylinder",
      "创建一个圆柱。可设顶/底盖分段与边数；去掉封顶可当管道用。",
      "Create a cylinder. Control cap segments and sides; drop the caps to use it as a pipe.")
_prim("create_cone", "Cone",
      "创建一个圆锥/圆台。radius1 为顶半径、radius2 为底半径，把顶半径设为 0 即为尖锥。",
      "Create a cone / frustum. radius1 is the top radius and radius2 the bottom; set top to 0 for a pointed cone.")
_prim("create_torus", "Torus",
      "创建一个圆环。radius1 是主管半径、radius2 是管子半径；sides 控制管子圆滑度。",
      "Create a torus. radius1 is the major (ring) radius, radius2 the minor (tube) radius; sides controls tube smoothness.")
_prim("create_teapot", "Teapot",
      "创建一个茶壶（经典测试模型）。axis 选择壶身/壶盖/壶嘴/壶把，通常保持默认。",
      "Create a teapot (classic test mesh). axis picks body/lid/spout/handle; usually leave default.")
_prim("create_plane", "Plane",
      "创建一个平面（默认只有 1 段，渲染时常用作地面/水面）。lengthSegs/widthSegs 给细分。",
      "Create a plane (1 segment by default, common as ground/water). lengthSegs/widthSegs add subdivisions.")
_prim("create_tube", "Tube",
      "创建一个管状几何体。radius1 为外半径、radius2 为内半径；可控制封顶与边数。",
      "Create a tube. radius1 is outer, radius2 inner radius; control caps and sides.")
_prim("create_pyramid", "Pyramid",
      "创建一个四棱锥（方底金字塔）。用 width/height/depth 控制尺寸；也可当作低面数障碍体。",
      "Create a pyramid (square base). Use width/height/depth for size; handy as a low-poly obstacle.")
_prim("create_hedra", "Hedra",
      "创建一个多面体（异面体），可选 family 与顶点类型，适合做科幻晶体。",
      "Create a hedra (multifaceted solid) with selectable family; good for sci-fi crystals.")
_prim("create_geosphere", "GeoSphere",
      "创建一个几何球体（基于经纬/二十面体细分），比普通 Sphere 更均匀，更适合做行星与碰撞球。",
      "Create a geo sphere (icosa/geodesic subdivision) - more uniform than Sphere, good for planets and collision spheres.")
_prim("create_chamferbox", "ChamferBox",
      "创建一个带圆角的长方体（拓展基础体）。chamfer 控制倒角，圆角面会显著增加多边形数。若当前 Max 未启用拓展基础体则会报错提示。",
      "Create a chamfered box (extended primitive). chamfer controls the bevel; bevel faces add many polygons. Errors gracefully if Extended Primitives are not enabled in this Max.")
_prim("create_capsule", "Capsule",
      "创建一个胶囊体（拓展基础体）。fillet 控制端盖圆角；常用于角色碰撞体与道具。若当前 Max 未启用拓展基础体则会报错提示。",
      "Create a capsule (extended primitive). fillet controls end caps; common for character collision shapes and props. Errors gracefully if Extended Primitives are not enabled in this Max.")


# ===================================================================== splines
TOOLS.append(tool(
    "create_line", "objects",
    "用一组世界坐标点创建一条样条线（Line）。可闭合。点数量越多曲线越精细，"
    "之后用 spline_set_points 修改顶点、spline_get_points 读取顶点。**闭合样条可倒出成面片。**",
    "Create a Line spline from an array of world-space points. Can be closed. More points = finer curve. "
    "Edit vertices with spline_set_points and read them with spline_get_points. **A closed spline can be capped into a surface.**",
    props={
        "name": s("图形名称；省略则自动命名。", "Shape name; auto-generated if omitted."),
        "points": arr("顶点数组，每项为 [x,y,z]。", "Array of vertices, each [x,y,z].", items="number"),
        "closed": b("是否闭合样条，默认否。", "Close the spline, default false."),
        "position": num3("整体偏移 [x,y,z]，会叠加到每个点上。", "Offset added to every point [x,y,z]."),
    },
    required=["points"],
))

TOOLS.append(tool(
    "create_rectangle", "objects",
    "创建一个矩形样条。length/width 控制尺寸，cornerRadius 可倒圆角；常作墙体/地面的截面。",
    "Create a rectangle spline. length/width size it; cornerRadius rounds corners. Common as wall/floor profile.",
    props=dict(_spline_props(), **{
        "length": n("长度。", "Length."),
        "width": n("宽度。", "Width."),
        "cornerRadius": n("圆角半径。", "Corner radius."),
    }),
    preset={"class": "Rectangle"},
))

TOOLS.append(tool(
    "create_circle", "objects",
    "创建一个圆样条。radius 控制大小；常用于轮胎/孔洞轮廓。",
    "Create a circle spline. radius sizes it; common for tyres/hole outlines.",
    props=dict(_spline_props(), **{"radius": n("半径。", "Radius.")}),
    preset={"class": "Circle"},
))

TOOLS.append(tool(
    "create_ellipse", "objects",
    "创建一个椭圆样条。length/width 分别控制长、短轴。",
    "Create an ellipse spline. length/width are the major/minor axes.",
    props=dict(_spline_props(), **{
        "length": n("长轴长度。", "Major axis length."),
        "width": n("短轴长度。", "Minor axis length."),
    }),
    preset={"class": "Ellipse"},
))

TOOLS.append(tool(
    "create_ngon", "objects",
    "创建一个正多边形（NGon）样条。radius 为外接圆半径，sides 为边数（至少 3）。",
    "Create a regular polygon (NGon) spline. radius is the circumradius, sides the edge count (>=3).",
    props=dict(_spline_props(), **{
        "radius": n("外接圆半径。", "Circumradius."),
        "sides": i("边数，至少 3。", "Edge count, >=3."),
    }),
    preset={"class": "NGon"},
))

TOOLS.append(tool(
    "create_donut", "objects",
    "创建一个圆环（Donut）样条，即两个同心圆。radius1 外、radius2 内。",
    "Create a donut spline (two concentric circles). radius1 outer, radius2 inner.",
    props=dict(_spline_props(), **{
        "radius1": n("外圆半径。", "Outer radius."),
        "radius2": n("内圆半径。", "Inner radius."),
    }),
    preset={"class": "Donut"},
))

TOOLS.append(tool(
    "create_arc", "objects",
    "创建一段圆弧样条。radius 半径，from/to 起止角（度）；做扇形/弯管截面。",
    "Create an arc spline. radius plus from/to angles in degrees; good for sectors/bent profiles.",
    props=dict(_spline_props(), **{
        "radius": n("半径。", "Radius."),
        "from": n("起始角（度）。", "Start angle (degrees)."),
        "to": n("结束角（度）。", "End angle (degrees)."),
    }),
    preset={"class": "Arc"},
))

TOOLS.append(tool(
    "create_helix", "objects",
    "创建一条螺旋线。radius1/radius2 为上下半径，height 高度，turns 圈数；常用于弹簧/楼梯路径。",
    "Create a helix spline. radius1/radius2 top/bottom, height, turns; common for springs/stair paths.",
    props=dict(_spline_props(), **{
        "radius1": n("底部半径。", "Bottom radius."),
        "radius2": n("顶部半径。", "Top radius."),
        "height": n("高度。", "Height."),
        "turns": n("圈数。", "Turns."),
    }),
    preset={"class": "Helix"},
))

TOOLS.append(tool(
    "create_text", "objects",
    "创建文字样条（Text）。text 为内容，size 字号，可加厚描边；文字需转样条后才能挤出成面。",
    "Create a Text spline. text is the content, size the font size, thickness the stroke. Text must be a spline before extruding.",
    props=dict(_spline_props(), **{
        "text": s("要生成的文字内容。", "Text content to generate."),
        "size": n("字号。", "Font size."),
        "thickness": n("描边粗细。", "Stroke thickness."),
    }),
    preset={"class": "Text"},
    required=["text"],
))

TOOLS.append(tool(
    "spline_get_points", "objects",
    "读取样条线的所有顶点（按样条/节点编号）。用于检查或修改曲线，配合 spline_set_points 使用。",
    "Read all knot points of a spline (by spline/knot index). Inspect or prep a curve; pair with spline_set_points.",
    props={
        "objects": arr("样条名称列表；省略则用当前选择。", "Spline names; omit for the selection."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "spline_set_points", "objects",
    "替换/追加样条线的顶点。顶点数少于原有则覆盖前 N 个，多于则追加。**修改后 Max 会自动更新几何体。**",
    "Replace/append a spline's knot points. Fewer points overwrite the first N, more append. **Max updates the geometry automatically.**",
    props={
        "objects": arr("样条名称列表；省略则用当前选择。", "Spline names; omit for the selection."),
        "points": arr("新的顶点数组，每项 [x,y,z]。", "New vertices, each [x,y,z].", items="number"),
    },
    required=["points"],
))


# ================================================================== transforms
TOOLS.append(tool(
    "transform_object", "objects",
    "对对象做 移动/旋转/缩放，支持绝对或相对、世界或局部、欧拉角(度)或轴角。objects 省略则作用于当前选择。"
    "**缩放父级会连带扭曲子级，先 reset_transform 再缩放。**",
    "Move/rotate/scale objects, absolute or relative, world or local, euler(degrees) or axis-angle. "
    "Omit objects to act on the selection. **Scaling a parent skews children; reset_transform first.**",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "operation": s("操作类型。", "Operation.", enum=["move", "rotate", "scale"], default="move"),
        "value": num3("移动/缩放量，或旋转欧拉角 [x,y,z]（度）。", "Move/scale delta or euler rotation [x,y,z] (degrees)."),
        "mode": s("absolute=直接设值，relative=在现有值上叠加。", "absolute=set value, relative=add to current.",
                  enum=["absolute", "relative"], default="relative"),
        "space": s("world=世界坐标，local=局部坐标。", "world or local space.", enum=["world", "local"], default="world"),
        "rotationType": s("euler=欧拉角(度)，axisangle=绕轴旋转。", "euler angles(deg) or axis-angle.",
                          enum=["euler", "axisangle"], default="euler"),
        "axis": num3("轴角旋转的旋转轴 [x,y,z]。", "Axis-angle rotation axis [x,y,z]."),
        "angle": n("轴角旋转的角度（度）。", "Axis-angle rotation amount (degrees)."),
    },
))

TOOLS.append(tool(
    "align_objects", "objects",
    "把多个对象对齐到目标对象（位置/旋转/缩放可分别开关）。用于批量摆放道具、对齐相机与瞄准点。",
    "Align several objects to a target (position/rotation/scale toggles). Great for placing props or aligning cameras.",
    props={
        "objects": arr("要对齐的对象列表；省略则用当前选择。", "Objects to align; omit for the selection."),
        "target": s("对齐目标对象名。", "Target object name."),
        "position": b("是否对齐位置，默认是。", "Align position, default true."),
        "rotation": b("是否对齐旋转，默认否。", "Align rotation, default false."),
        "scale": b("是否对齐缩放，默认否。", "Align scale, default false."),
    },
    required=["target"],
))

TOOLS.append(tool(
    "mirror_object", "objects",
    "沿 X/Y/Z 平面镜像对象（翻转对应轴缩放并重新定位）。cloneType 可同时生成副本（copy/instance）。"
    "**镜像会翻转法线，导出前考虑翻转或加壳。**",
    "Mirror objects across the X/Y/Z plane (flips that axis scale and repositions). cloneType can also spawn copies. "
    "**Mirroring flips normals; consider flipping or adding a shell before export.**",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "axis": s("镜像轴。", "Mirror axis.", enum=["x", "y", "z"], default="x"),
        "offset": n("镜像平面所在坐标（该轴方向）。", "Coordinate of the mirror plane (along that axis).", default=0.0),
        "cloneType": s("none=原地镜像，copy/instance=同时生成副本。",
                       "none=in place, copy/instance=also spawn a copy.", enum=["none", "copy", "instance"], default="none"),
    },
))

TOOLS.append(tool(
    "set_pivot", "objects",
    "移动或居中对象的轴点（pivot）。place=放到指定坐标，center=几何中心，origin=世界原点。"
    "烘焙动画/父子链接前先定好轴点，否则旋转会绕错位置。",
    "Move or center an object's pivot. place=given coord, center=geometric center, origin=world origin. "
    "Set the pivot before baking animation or parenting or rotation spins around the wrong spot.",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "mode": s("place/center/origin。", "place/center/origin.", enum=["place", "center", "origin"], default="place"),
        "position": num3("place 模式下轴点坐标 [x,y,z]。", "Pivot coord for place mode [x,y,z]."),
    },
))

TOOLS.append(tool(
    "reset_transform", "objects",
    "清零对象的旋转与缩放（或位置），把变换烘焙回对象自身。**缩放父级会连带扭曲子级，先调用它再缩放。**",
    "Reset an object's rotation and scale (or position), baking the transform into the object. "
    "**Scaling a parent skews children; call this before scaling.**",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "rotation": b("是否清零旋转，默认是。", "Reset rotation, default true."),
        "scale": b("是否清零缩放，默认是。", "Reset scale, default true."),
        "position": b("是否清零位置，默认否。", "Reset position, default false."),
    },
))

TOOLS.append(tool(
    "snap_objects_to_grid", "objects",
    "把对象位置吸附到指定间距的网格点上。用于规整摆放、对齐棋盘/阵列起点。",
    "Snap object positions to a grid of the given spacing. Tidy placement, align chessboard/array origins.",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "spacing": n("网格间距，默认 10。", "Grid spacing, default 10.", minimum=0.0001, default=10.0),
    },
))

TOOLS.append(tool(
    "scatter_objects", "objects",
    "在盒状区域内（或某个表面之上）随机散布对象副本，可随机旋转/缩放，并用 seed 保证结果可复现。"
    "用于做草地、碎石、观众席等大量重复物。**数量很大时会卡，建议分批。**",
    "Scatter copies of objects randomly inside a box (or over a surface), with optional random rotation/scale and a seed for reproducibility. "
    "Great for grass, rubble, crowds. **Huge counts lag; scatter in batches.**",
    props={
        "objects": arr("原型对象列表；省略则用当前选择。", "Prototype objects; omit for the selection."),
        "count": i("生成的实例总数，默认等于原型数。", "Total instances, default = prototype count.", minimum=1, default=1),
        "region": s("box=盒内随机，surface=投影到 surface 对象表面。",
                    "box=random in box, surface=project onto the surface object.", enum=["box", "surface"], default="box"),
        "surface": s("surface 模式下的承载对象名（地面/地形）。", "Surface carrier name for surface mode (ground/terrain)."),
        "center": num3("散布区域中心 [x,y,z]。", "Scatter region center [x,y,z]."),
        "size": num3("盒状区域尺寸 [x,y,z]。", "Box region size [x,y,z]."),
        "seed": i("随机种子，相同种子结果一致。", "Random seed; same seed = same result.", default=12345),
        "randomRotation": b("是否随机旋转，默认是。", "Random rotation, default true."),
        "randomScale": b("是否随机缩放，默认否。", "Random scale, default false."),
        "scaleMin": n("随机缩放下限。", "Random scale lower bound.", default=0.8),
        "scaleMax": n("随机缩放上限。", "Random scale upper bound.", default=1.2),
    },
))


# =================================================================== hierarchy
TOOLS.append(tool(
    "parent_objects", "objects",
    "把对象链接到父对象下（建立层级）。keepTransform 保持世界变换不变。"
    "**父子层级下，缩放父级会连带扭曲子级，必要时先 reset_transform。**",
    "Link objects under a parent (build a hierarchy). keepTransform preserves world transform. "
    "**Under parenting, scaling the parent skews children; reset_transform if needed.**",
    props={
        "objects": arr("子对象列表；省略则用当前选择。", "Child objects; omit for the selection."),
        "parent": s("父对象名。", "Parent object name."),
        "keepTransform": b("保持世界变换，默认是。", "Keep world transform, default true."),
    },
    required=["parent"],
))

TOOLS.append(tool(
    "unparent_objects", "objects",
    "把对象从父级解绑（取消层级）。keepTransform 保持世界位置/旋转不变。",
    "Unlink objects from their parent. keepTransform keeps world position/rotation.",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "keepTransform": b("保持世界变换，默认是。", "Keep world transform, default true."),
    },
))

TOOLS.append(tool(
    "get_hierarchy", "objects",
    "返回场景层级树（递归子级）。root 省略或为 scene 时从根节点开始。只读。",
    "Return the scene hierarchy tree (children recursed). Omit root or pass scene to start at the root. Read-only.",
    props={
        "root": s("根对象名；scene 或省略表示整个场景。", "Root object name; scene or omitted = whole scene."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "group_objects", "objects",
    "把多个对象编组为一个组（Group），便于整体移动/隐藏。返回组头名称。",
    "Group several objects into one Group for moving/hiding together. Returns the group head name.",
    props={
        "objects": arr("要编组的对象列表；省略则用当前选择。", "Objects to group; omit for the selection."),
        "name": s("组名。", "Group name."),
    },
))

TOOLS.append(tool(
    "ungroup_objects", "objects",
    "解散组（保留成员对象）。传组头或组内任意成员均可。",
    "Ungroup (keeps the member objects). Pass the group head or any member.",
    props={
        "objects": arr("要解散的组/对象列表；省略则用当前选择。", "Groups/objects to ungroup; omit for the selection."),
    },
))

TOOLS.append(tool(
    "open_group", "objects",
    "打开组（临时解组以便编辑成员，关闭后恢复）。", "Open a group (temporarily ungroup for editing; close to restore).",
    props={
        "objects": arr("要打开的组列表；省略则用当前选择。", "Groups to open; omit for the selection."),
    },
))

TOOLS.append(tool(
    "close_group", "objects",
    "关闭（重新合上）之前打开的组。", "Close a previously opened group (re-collapse it).",
    props={
        "objects": arr("要关闭的组列表；省略则用当前选择。", "Groups to close; omit for the selection."),
    },
))


# ============================================================ selection & query
TOOLS.append(tool(
    "list_objects", "objects",
    "列出场景对象，可按 superclass/class/layer/名称通配符过滤，支持 limit/offset 分页并返回 count。"
    "只读，适合先摸清场景再决定操作。**namePattern 用 * 作通配，例如 Box*。**",
    "List scene objects, filterable by superclass/class/layer/name wildcard, paginated with limit/offset and a count field. "
    "Read-only, use it to survey the scene first. **namePattern uses * as wildcard, e.g. Box*.**",
    props={
        "superClass": s("按 superclass 过滤，例如 GeometryClass、Shape、Light、Camera、Helper。",
                        "Filter by superclass, e.g. GeometryClass, Shape, Light, Camera, Helper."),
        "type": s("superClass 的别名。", "Alias of superClass."),
        "class": s("按确切类名过滤，例如 Box、Editable_Poly。", "Filter by exact class, e.g. Box, Editable_Poly."),
        "layer": s("按层名过滤。", "Filter by layer name."),
        "namePattern": s("名称通配符，例如 Box*、*prop*。", "Name wildcard, e.g. Box*, *prop*."),
        "limit": i("每页最多条数，默认 200。", "Max per page, default 200.", minimum=1, default=200),
        "offset": i("分页偏移，默认 0。", "Pagination offset, default 0.", minimum=0, default=0),
    },
    mutating=False,
))

TOOLS.append(tool(
    "find_objects", "objects",
    "按名称精确或模糊查找对象，返回命中列表与 count。只读。exact=true 时只匹配完全相同名称。",
    "Find objects by exact or fuzzy name; returns hits and a count. Read-only. exact=true matches only identical names.",
    props={
        "name": s("要查找的名称或关键字。", "Name or keyword to find."),
        "pattern": s("通配符形式，例如 *prop*（与 name 二选一）。", "Wildcard form, e.g. *prop* (alternative to name)."),
        "exact": b("是否精确匹配，默认否（模糊包含）。", "Exact match, default false (fuzzy contains).", default=False),
    },
    required=["name"],
    mutating=False,
))

TOOLS.append(tool(
    "get_object_info", "objects",
    "返回单个对象的完整信息：类、层级、变换、隐藏/冻结、材质、顶点/面数等。只读。",
    "Return full info for one object: class, hierarchy, transform, hidden/frozen, material, vertex/face counts. Read-only.",
    props={
        "name": s("对象名。", "Object name."),
    },
    required=["name"],
    mutating=False,
))

TOOLS.append(tool(
    "get_selection", "objects",
    "返回当前选择的对象列表及概要。只读。", "Return the current selection with summaries. Read-only.",
    mutating=False,
))

TOOLS.append(tool(
    "select_objects", "objects",
    "选择对象。mode=replace 替换、add 追加、subtract 移除、invert 反选。",
    "Select objects. mode=replace/add/subtract/invert.",
    props={
        "objects": arr("对象名称列表。", "Object name list."),
        "mode": s("replace/add/subtract/invert。", "replace/add/subtract/invert.",
                  enum=["replace", "add", "subtract", "invert"], default="replace"),
    },
))

TOOLS.append(tool(
    "deselect_all", "objects",
    "清空当前选择。批量操作前先清空可避免误伤上一次选择的对象。",
    "Clear the current selection. Useful before a batch operation so you do not "
    "accidentally operate on whatever was selected earlier.",
    mutating=False,
))

TOOLS.append(tool(
    "select_all", "objects",
    "选择场景中所有对象。", "Select every object in the scene.",
))

TOOLS.append(tool(
    "select_by_superclass", "objects",
    "按 superclass 全选（例如 Shape 选中所有图形、Light 选中所有灯光）。",
    "Select all by superclass (e.g. Shape selects every spline, Light every light).",
    props={
        "superClass": s("要选中的 superclass，例如 GeometryClass、Shape、Light、Camera、Helper。",
                        "superClass to select, e.g. GeometryClass, Shape, Light, Camera, Helper."),
        "type": s("superClass 的别名。", "Alias of superClass."),
    },
    required=["superClass"],
))


# ========================================================== visibility & lifecycle
TOOLS.append(tool(
    "hide_objects", "objects",
    "隐藏指定对象（省略则隐藏当前选择）。隐藏对象仍参与渲染，除非层/对象设为不可渲染。",
    "Hide the given objects (or the current selection). Hidden objects still render unless set non-renderable.",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
    },
))

TOOLS.append(tool(
    "unhide_all", "objects",
    "显示场景中所有被隐藏的对象。", "Show every hidden object in the scene.",
))

TOOLS.append(tool(
    "unhide_objects", "objects",
    "显示指定对象；若不传 objects 则显示全部。", "Show the given objects; show all if none specified.",
    props={
        "objects": arr("要显示的对象列表。", "Objects to show."),
    },
))

TOOLS.append(tool(
    "freeze_objects", "objects",
    "冻结指定对象（不可选中、不可变换，但仍可见/可渲染）。适合锁定背景参考物。",
    "Freeze the given objects (unselectable/untransformable but still visible/renderable). Lock reference props.",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
    },
))

TOOLS.append(tool(
    "unfreeze_all", "objects",
    "解冻场景中所有被冻结的对象。", "Unfreeze every frozen object in the scene.",
))

TOOLS.append(tool(
    "rename_object", "objects",
    "重命名一个对象。返回旧名与新名。", "Rename one object. Returns old and new name.",
    props={
        "name": s("原对象名。", "Original object name."),
        "newName": s("新名称。", "New name."),
    },
    required=["name", "newName"],
))

TOOLS.append(tool(
    "delete_objects", "objects",
    "删除指定对象（省略则删除当前选择）。**不可恢复，危险操作前建议 hold_scene。**",
    "Delete the given objects (or the selection). **Not recoverable; call hold_scene before risky deletes.**",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
    },
))

TOOLS.append(tool(
    "clone_objects", "objects",
    "克隆对象：copy 独立副本、instance 关联实例、reference 参考。count>1 时按 offset 间隔摆放。",
    "Clone objects: copy (independent), instance (linked), reference. count>1 spaces them by offset.",
    props={
        "objects": arr("对象名称列表；省略则用当前选择。", "Object names; omit for the selection."),
        "cloneType": s("copy/instance/reference。", "copy/instance/reference.",
                       enum=["copy", "instance", "reference"], default="copy"),
        "count": i("每个对象克隆几份，默认 1。", "Copies per object, default 1.", minimum=1, default=1),
        "offset": num3("多份之间的位移间隔 [x,y,z]。", "Spacing between copies [x,y,z]."),
    },
))

TOOLS.append(tool(
    "array_objects", "objects",
    "按 1D/2D/3D 网格（grid）或绕轴环形（radial）阵列复制对象。grid 用 count1/2/3 与 spacing1/2/3；radial 用 count1、axis、radius 绕轴均布。",
    "Array-clone objects in a 1D/2D/3D grid or radially around an axis. grid uses count1/2/3 + spacing1/2/3; radial uses count1, axis, radius.",
    props={
        "objects": arr("要阵列的对象列表；省略则用当前选择。", "Objects to array; omit for the selection."),
        "mode": s("grid=网格阵列，radial=绕轴环形。", "grid or radial.", enum=["grid", "radial"], default="grid"),
        "count1": i("第 1 轴数量，默认 3。", "Count on axis 1, default 3.", minimum=1, default=3),
        "count2": i("第 2 轴数量，默认 1。", "Count on axis 2, default 1.", minimum=1, default=1),
        "count3": i("第 3 轴数量，默认 1。", "Count on axis 3, default 1.", minimum=1, default=1),
        "spacing1": n("第 1 轴间距。", "Spacing on axis 1.", default=10.0),
        "spacing2": n("第 2 轴间距。", "Spacing on axis 2.", default=10.0),
        "spacing3": n("第 3 轴间距。", "Spacing on axis 3.", default=10.0),
        "center": num3("阵列中心 [x,y,z]。", "Array center [x,y,z]."),
        "axis": s("radial 模式下的旋转轴 x/y/z，默认 z。", "radial rotation axis x/y/z, default z."),
        "radius": n("radial 模式下的环形半径。", "radial ring radius.", default=50.0),
    },
))

TOOLS.append(tool(
    "attach_objects", "objects",
    "把一个或多个样条合并进目标样条（Editable Spline 的 attach），用于把多条线合成一条轮廓再挤出。",
    "Attach one or more splines into a target spline (Editable Spline attach); combine profiles before extruding.",
    props={
        "target": s("目标样条名，会被转为可编辑样条并接收其余样条。", "Target spline; converted to editable spline and receives the others."),
        "objects": arr("要并入的样条列表；省略则用当前选择。", "Splines to attach; omit for the selection."),
    },
    required=["target"],
))

TOOLS.append(tool(
    "detach_elements", "objects",
    "把一个可编辑多边形按元素拆分，每个元素拆成独立对象（Det_<原名>_<序号>）。适合把合并网格重新拆开。",
    "Split an editable poly by element, each element becomes its own object (Det_<name>_<n>). Re-separate merged meshes.",
    props={
        "name": s("要拆分的 editable poly 对象名。", "Editable poly object name to split."),
    },
    required=["name"],
))

TOOLS.append(tool(
    "count_objects", "objects",
    "统计场景对象数量，可按 superclass 过滤。只读。", "Count scene objects, optionally by superclass. Read-only.",
    props={
        "superClass": s("按 superclass 统计，例如 GeometryClass、Shape。", "Count by superclass, e.g. GeometryClass, Shape."),
    },
    mutating=False,
))


# ================================================================== booleans
TOOLS.append(tool(
    "boolean_operation", "objects",
    "对选中的两个及以上对象做布尔运算（union/subtract/intersect/merge）。"
    "第 1 个对象是 A，其余依次作用于它；subtract 即 A 减后面所有。**布尔结果依赖水密网格，破面会失败。**",
    "Boolean operation on two or more selected objects (union/subtract/intersect/merge). "
    "The first object is A; the rest apply to it; subtract = A minus all others. "
    "**Booleans need watertight meshes; broken faces fail.**",
    props={
        "objects": arr("操作对象列表（第 1 个为 A）；省略则用当前选择。", "Operands (first is A); omit for the selection."),
        "operation": s("union/subtract/intersect/merge。", "union/subtract/intersect/merge.",
                      enum=["union", "subtract", "intersect", "merge"], default="union"),
    },
))

TOOLS.append(tool(
    "proboolean", "objects",
    "使用 3ds Max 的 ProBoolean 做更鲁棒的布尔（支持多 operands、交集/减集/合并）。"
    "第 1 个对象为基，其余并入。若当前 Max 未启用 ProBoolean 会报错提示。",
    "Use 3ds Max ProBoolean for a more robust boolean (multi-operand, union/subtract/intersect/merge). "
    "First object is the base; the rest are added. Errors gracefully if ProBoolean is unavailable.",
    props={
        "objects": arr("操作对象列表（第 1 个为基）；省略则用当前选择。", "Operands (first is base); omit for the selection."),
        "operation": s("union/subtract/intersect/merge。", "union/subtract/intersect/merge.",
                      enum=["union", "subtract", "intersect", "merge"], default="union"),
    },
))
