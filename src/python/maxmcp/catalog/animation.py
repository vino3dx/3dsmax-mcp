"""Animation catalog: keyframes, controllers, constraints, rigging (bones, skin,
IK, morph).

Category key: ``animation``.

Every description below calls out the real pitfalls an agent hits when driving
3ds Max blind:

* Euler rotation controllers cannot interpolate past 180 degrees - spinning
  wheels and turntables need a Quaternion/TCB controller instead.
* Game engines (Unity/Unreal) cannot evaluate Max's procedural controllers,
  constraints or expressions, so you MUST ``anim_bake`` (or ``rig_skin_auto_weight``)
  before exporting to FBX.
* Skin weights are per-vertex and normalised to 1.0; setting one bone to 1.0
  removes the influence of every other bone on that vertex.
"""

from __future__ import annotations

from typing import List

from .schema import Tool, arr, b, i, n, s, tool

TOOLS: List[Tool] = []


# ============================================================ keyframes: writing
TOOLS.append(tool(
    "anim_set_key", "animation",
    "在指定帧为对象的某个属性写入一个关键帧（position / rotation / scale，或任意命名属性）。"
    "rotation 用欧拉角（度）表示。mode=relative 时在当前值上叠加。"
    "**欧拉旋转无法插值超过 180°：车轮、转盘要改用 Quaternion/TCB 控制器，否则会出现瞬移。**",
    "Write one keyframe for a property (position / rotation / scale, or any named "
    "property) at a given frame. Rotation is given as Euler angles in degrees. "
    "With relative=true the value is added on top of the current value. "
    "**Euler rotation cannot interpolate past 180 degrees - spinning wheels and "
    "turntables must use a Quaternion/TCB controller or they will snap.**",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "frame": i("关键帧所在的帧（基于场景帧率，不要假设 30fps）。",
                   "Frame of the keyframe (respects the scene frame rate, do not assume 30 fps)."),
        "value": arr("属性值。position/scale 为 [x,y,z]，rotation 为 [x,y,z] 欧拉角（度），"
                     "标量属性为单个数。",
                     "Property value. position/scale as [x,y,z], rotation as [x,y,z] Euler "
                     "degrees, scalar properties as a single number.", items="number"),
        "relative": b("true=在当前帧的值上叠加，false=绝对值。", "true=add to the value at that frame, false=absolute."),
    },
    required=["property", "frame", "value"],
))

TOOLS.append(tool(
    "anim_set_keys", "animation",
    "一次性为某个属性写入多个关键帧：keys 是 [{frame, value}] 列表。"
    "一个完整的行走循环用一次调用即可完成，比反复调 anim_set_key 高效得多。",
    "Write many keyframes for one property in a single call: keys is a list of "
    "{frame, value}. A whole walk cycle is one call, far cheaper than repeated "
    "anim_set_key invocations.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "keys": arr("关键帧列表，每项 {frame, value}。", "Keyframe list, each item {frame, value}.", items="object"),
        "relative": b("true=在每个帧的当前值上叠加。", "true=add on top of the value at each frame."),
    },
    required=["property", "keys"],
))

TOOLS.append(tool(
    "anim_get_keys", "animation",
    "读取某个属性的所有关键帧（帧号、值、进出切线类型），支持 limit/offset 分页。",
    "Read every keyframe of a property (frame, value, in/out tangent type). "
    "Paginated with limit/offset.",
    props={
        "objects": arr("对象名列表；省略则取选择中的第一个。", "Object names; the first of the selection if omitted."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "limit": i("最多返回条数，默认 200。", "Maximum entries, default 200."),
        "offset": i("跳过的条数，默认 0。", "Entries to skip, default 0."),
    },
    required=["property"],
    mutating=False,
))

TOOLS.append(tool(
    "anim_delete_keys", "animation",
    "删除某个属性的关键帧。给定 frames 则只删这些帧，否则删除该轨道上的全部关键帧。",
    "Delete keyframes of a property. With frames, only those frames are removed; "
    "otherwise every key on the track is deleted.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "frames": arr("要删除的帧号列表；省略则清空整条轨道。",
                      "Frames to delete; omit to clear the whole track.", items="integer"),
    },
    required=["property"],
))

TOOLS.append(tool(
    "anim_clear_animation", "animation",
    "清除对象上的动画关键帧。给定 properties 只清这些轨道，否则清空 position/rotation/scale 三条变换轨道。",
    "Clear animation keys on an object. With properties only those tracks are "
    "cleared, otherwise the position / rotation / scale transform tracks are.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "properties": arr("要清除的属性名列表；省略则清 position/rotation/scale。",
                          "Tracks to clear; omit for position/rotation/scale.", items="string"),
    },
))

TOOLS.append(tool(
    "anim_offset_keys", "animation",
    "把整条轨道在时间上整体平移 offset 帧（可为负），所有关键帧一起移动。",
    "Shift a whole track in time by offset frames (may be negative); every key "
    "moves together.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "offset": i("平移的帧数（可为负）。", "Frames to shift (may be negative)."),
    },
    required=["property", "offset"],
))

TOOLS.append(tool(
    "anim_scale_keys", "animation",
    "时间拉伸整条轨道：以 pivotFrame 为锚点，把所有关键帧时间乘以 factor（factor<1 变快，>1 变慢）。",
    "Time-stretch a whole track about pivotFrame: every key time is multiplied by "
    "factor (factor<1 speeds up, >1 slows down).",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "factor": n("时间缩放系数，1.0 不变。", "Time scale factor, 1.0 = unchanged.", minimum=0.0001),
        "pivotFrame": i("锚定帧，默认 0。", "Pivot frame, default 0."),
    },
    required=["property", "factor"],
))

TOOLS.append(tool(
    "anim_set_controller", "animation",
    "给某个属性指定控制器：Linear / Bezier / TCB / Euler / Position XYZ / List 等。"
    "位置用 bezier_position，旋转用 euler_xyz 或 tcb_rotation，标量用 bezier_float。"
    "切换控制器会清空该轨道已有的关键帧。",
    "Assign a controller to a property: Linear / Bezier / TCB / Euler / Position XYZ "
    "/ List. position uses bezier_position, rotation euler_xyz or tcb_rotation, "
    "scalars bezier_float. Switching controllers clears existing keys on the track.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "controller": s("控制器类型关键词。", "Controller type keyword.",
                        enum=["Linear", "Bezier", "TCB", "Euler", "PositionXYZ", "List"],
                        examples=["bezier_position", "euler_xyz", "tcb_rotation", "position_list"]),
    },
    required=["property", "controller"],
))

TOOLS.append(tool(
    "anim_get_controller", "animation",
    "返回某个属性当前使用的控制器类名及其关键帧数量。",
    "Return the controller class name currently used by a property and its key count.",
    props={
        "objects": arr("对象名列表；省略则取选择中的第一个。", "Object names; the first of the selection if omitted."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
    },
    required=["property"],
    mutating=False,
))

TOOLS.append(tool(
    "anim_set_out_of_range", "animation",
    "设置控制器在动画范围之外的行为：loop（循环）/ cycle（往复周期）/ pingpong（乒乓）/ constant（保持）/ linear（线性外推）。",
    "Set a controller's out-of-range behaviour: loop / cycle / pingpong / constant / linear.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "type": s("类型。", "Type.", enum=["loop", "cycle", "pingpong", "constant", "linear"]),
    },
    required=["property", "type"],
))

TOOLS.append(tool(
    "anim_ease", "animation",
    "设置某一帧关键帧的进出切线类型（smooth/linear/step/slow/fast）及可选手柄值，用于控制缓动。",
    "Set the in/out tangent type (smooth/linear/step/slow/fast) and optional handle "
    "values of the keyframe at a frame, to shape easing.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "frame": i("关键帧所在帧。", "Frame of the keyframe."),
        "inTangent": s("入切线类型。", "In tangent type.", enum=["smooth", "linear", "step", "slow", "fast"]),
        "outTangent": s("出切线类型。", "Out tangent type.", enum=["smooth", "linear", "step", "slow", "fast"]),
        "inHandle": n("入手柄值（可选）。", "In handle value (optional)."),
        "outHandle": n("出手柄值（可选）。", "Out handle value (optional)."),
    },
    required=["property", "frame"],
))

TOOLS.append(tool(
    "anim_bake", "animation",
    "把程序化/约束驱动的轨迹按帧采样并写入显式关键帧——这正是导出到游戏引擎前必须做的事。"
    "引擎无法求值 Max 的程序化控制器、约束、表达式，所以 FBX 导出前一定要先烘焙。"
    "返回写入的关键帧数量。",
    "Sample a procedural/constraint-driven track per frame and write explicit "
    "keyframes - this is exactly what you must do before exporting to a game engine. "
    "Engines cannot evaluate Max's procedural controllers, constraints or expressions, "
    "so ALWAYS bake before FBX export. Returns the number of keys written.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "startFrame": i("起始帧，默认动画范围起点。", "First frame, default animation range start."),
        "endFrame": i("结束帧，默认动画范围终点。", "Last frame, default animation range end."),
        "step": i("采样步长，默认 1。", "Sampling step, default 1.", minimum=1),
        "properties": arr("要烘焙的属性；省略则烘焙 position/rotation/scale。",
                          "Properties to bake; omit for position/rotation/scale.", items="string"),
    },
))

TOOLS.append(tool(
    "anim_bake_range", "animation",
    "对整个层级（对象及其所有子对象）在帧范围内逐帧烘焙为显式关键帧。"
    "烘焙重骨骼/约束驱动的角色后再导出，可避免引擎端动画丢失。返回写入的关键帧数量。",
    "Bake an entire hierarchy (object and all descendants) into explicit keys over a "
    "frame range. Bake heavily rigged/constrained characters before export so the "
    "animation survives. Returns the number of keys written.",
    props={
        "objects": arr("层级根对象名列表；省略则用当前选择。", "Hierarchy root names; omit for the current selection."),
        "startFrame": i("起始帧，默认动画范围起点。", "First frame, default animation range start."),
        "endFrame": i("结束帧，默认动画范围终点。", "Last frame, default animation range end."),
        "step": i("采样步长，默认 1。", "Sampling step, default 1.", minimum=1),
        "properties": arr("要烘焙的属性；省略则烘焙 position/rotation/scale。",
                          "Properties to bake; omit for position/rotation/scale.", items="string"),
    },
))

TOOLS.append(tool(
    "anim_set_interpolation", "animation",
    "设置整条轨道（或指定帧）每个关键帧的插值切线类型：smooth/linear/step 等。",
    "Set the interpolation tangent type (smooth/linear/step ...) of every key on a "
    "track, or only the given frames.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale，或任意命名属性。",
                      "Property name: position / rotation / scale, or any named property."),
        "type": s("切线类型。", "Tangent type.", enum=["smooth", "linear", "step", "slow", "fast"]),
        "frames": arr("只对这些帧设置；省略则作用于整条轨道。",
                      "Only these frames; omit for the whole track.", items="integer"),
    },
    required=["property", "type"],
))


# ============================================================ playback & time
TOOLS.append(tool(
    "anim_goto_frame", "animation",
    "跳到指定帧（设置当前时间滑块位置）。不播放，仅定位。",
    "Jump to a frame (set the current time slider). Locates only, does not play.",
    props={
        "frame": i("目标帧。", "Target frame."),
    },
    required=["frame"],
))

TOOLS.append(tool(
    "anim_get_frame", "animation",
    "读取当前时间轴帧号与时间值。做关键帧操作前先确认当前帧，避免把关键帧写错位置。",
    "Read the current timeline frame and time value. Check it before keying, otherwise "
    "keys land on the wrong frame.",
    mutating=False,
))

TOOLS.append(tool(
    "anim_play", "animation",
    "播放 / 暂停 / 停止动画。action=play 开始播放，pause 暂停，stop 停止。",
    "Play / pause / stop the animation. action=play starts, pause pauses, stop stops.",
    props={
        "action": s("操作。", "Action.", enum=["play", "pause", "stop"]),
        "fromFrame": i("播放起始帧（可选）。", "Playback start frame (optional)."),
        "toFrame": i("播放结束帧（可选）。", "Playback end frame (optional)."),
    },
    required=["action"],
))

TOOLS.append(tool(
    "anim_play_preview", "animation",
    "生成一段实时预览动画文件（avi/影序）。可指定输出路径与帧范围。"
    "生成的预览用于快速检查，不是最终渲染。",
    "Generate a real-time preview animation file (avi / image sequence). Output path "
    "and frame range are optional. The preview is for quick checks, not final render.",
    props={
        "output": s("输出文件路径；省略则用临时目录。", "Output path; the temp folder if omitted."),
        "startFrame": i("起始帧，默认动画范围起点。", "First frame, default animation range start."),
        "endFrame": i("结束帧，默认动画范围终点。", "Last frame, default animation range end."),
        "percent": i("分辨率百分比，默认 100。", "Resolution percent, default 100.", minimum=1, maximum=100),
    },
    mutating=True,
))

TOOLS.append(tool(
    "anim_get_key_stats", "animation",
    "统计每个对象各变换轨道的关键帧数量，烘焙重角色前先评估规模很有用。支持分页。",
    "Count keyframes per object across transform tracks - useful to gauge the cost "
    "before baking a heavy rig. Paginated.",
    props={
        "objects": arr("对象名列表；省略则统计整个选择。", "Object names; the current selection if omitted."),
        "limit": i("最多返回条数，默认 200。", "Maximum entries, default 200."),
        "offset": i("跳过的条数，默认 0。", "Entries to skip, default 0."),
    },
    mutating=False,
))


# ============================================================ controllers / wiring
TOOLS.append(tool(
    "ctrl_list", "animation",
    "列出对象所有可动画轨道及其控制器类型与关键帧数。排查『为什么这个属性没动』时先看它。",
    "List every animatable track of an object with its controller type and key count. "
    "Check it first when wondering why a property will not animate.",
    props={
        "objects": arr("对象名列表；省略则取选择中的第一个。", "Object names; the first of the selection if omitted."),
        "limit": i("最多返回条数，默认 200。", "Maximum entries, default 200."),
        "offset": i("跳过的条数，默认 0。", "Entries to skip, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "ctrl_set_value", "animation",
    "在指定帧把一个可动画轨道的值写入为关键帧（相对 anim_set_key 更偏底层，专用于控制器轨道）。",
    "Write a keyframed value to an animatable controller track at a frame (lower level "
    "than anim_set_key, aimed at controller tracks).",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名（轨道）。", "Property / track name."),
        "value": arr("值，标量或 [x,y,z]。", "Value, scalar or [x,y,z].", items="number"),
        "frame": i("帧号；省略则用当前帧。", "Frame; current frame if omitted."),
        "relative": b("true=在当前值上叠加。", "true=add to the current value."),
    },
    required=["property", "value"],
))

TOOLS.append(tool(
    "ctrl_set_property", "animation",
    "设置对象的任意（含非动画）属性值，支持点号路径，如 material.diffuse。可选在指定帧写入。",
    "Set any object property (including non-animatable) with dotted paths such as "
    "material.diffuse. Optionally written at a given frame.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名或点号路径。", "Property name or dotted path."),
        "value": s("新值（字符串形式，按目标类型自动转换）。",
                  "New value as a string, coerced to the target type."),
        "frame": i("帧号；省略则用当前帧。", "Frame; current frame if omitted."),
    },
    required=["property", "value"],
))

TOOLS.append(tool(
    "ctrl_add_list", "animation",
    "给轨道加一个 List 控制器（把程序化噪声叠加在已有动画之上的标准做法）。"
    "例如位置轨道叠加 noise_position，再用 constraint_set_weight 调权重。",
    "Add a List controller to a track - the standard way to layer procedural noise on "
    "top of an existing animation. E.g. stack noise_position on a position track, then "
    "tune the weight with constraint_set_weight.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性名：position / rotation / scale。", "Property: position / rotation / scale."),
        "layer": s("要加入的层控制器类，默认 noise_position。",
                   "Layer controller class, default noise_position.",
                   examples=["noise_position", "bezier_position", "noise_rotation"]),
        "weight": n("新层权重（0-100，UI 同款）。", "New layer weight (0-100, like the UI).", minimum=0.0, maximum=100.0),
    },
    required=["property"],
))

TOOLS.append(tool(
    "ctrl_wire", "animation",
    "把两个对象的参数用表达式连线（Wire Parameters）。典型用法：车轮旋转由车体位移驱动。"
    "sourceProperty/targetProperty 是相对节点的点号路径，例如 position.x_position 或 "
    "rotation.controller.z_rotation。",
    "Wire two objects' parameters together with an expression (Wire Parameters). "
    "Classic use: a wheel's rotation driven by the car's position. sourceProperty / "
    "targetProperty are dotted paths relative to the node, e.g. position.x_position or "
    "rotation.controller.z_rotation.",
    props={
        "source": s("源对象名（驱动方）。", "Source object name (driver)."),
        "sourceProperty": s("源属性点号路径。", "Source property dotted path."),
        "target": s("目标对象名（被驱动方）。", "Target object name (driven)."),
        "targetProperty": s("目标属性点号路径。", "Target property dotted path."),
        "expression": s("连线表达式（可选，默认 1:1 同向）。", "Wire expression (optional, default 1:1)."),
    },
    required=["source", "sourceProperty", "target", "targetProperty"],
))

TOOLS.append(tool(
    "ctrl_assign_expression", "animation",
    "给一个标量属性挂一个 Expression（表达式）控制器，用表达式驱动它。"
    "注意：表达式控制器对浮点/标量属性最可靠；变换轨道请改用 List 控制器加 Noise 层。",
    "Attach an Expression controller to a scalar property and drive it with an "
    "expression. Note: Expression controllers are most reliable on float/scalar "
    "properties; for transform tracks use a List controller with a Noise layer instead.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("标量属性名。", "Scalar property name."),
        "expression": s("表达式文本，例如 'x_position * 2.0'。",
                        "Expression text, e.g. 'x_position * 2.0'."),
    },
    required=["property", "expression"],
))


# ============================================================ constraints
TOOLS.append(tool(
    "constraint_look_at", "animation",
    "给对象加 LookAt 约束，使其始终朝向 target。可选 upNode 定上方向，keepOffset 保留初始朝向。",
    "Add a LookAt constraint so the object always faces target. Optional upNode sets "
    "the up direction; keepOffset preserves the initial orientation.",
    props={
        "objects": arr("被约束的对象名列表；省略则用当前选择。", "Constrained objects; omit for the current selection."),
        "target": s("朝向目标对象名。", "Look-at target object name."),
        "upNode": s("上方向参考对象名（可选）。", "Up-vector reference object (optional)."),
        "keepOffset": b("true=保留初始相对朝向。", "true=keep the initial relative orientation."),
    },
    required=["target"],
))

TOOLS.append(tool(
    "constraint_position", "animation",
    "给对象加 Position 约束，使其跟随 target 的位置（可多个目标加权混合）。",
    "Add a Position constraint so the object follows target's position (multiple "
    "targets can be blended by weight).",
    props={
        "objects": arr("被约束的对象名列表；省略则用当前选择。", "Constrained objects; omit for the current selection."),
        "target": s("跟随的目标对象名。", "Followed target object name."),
        "weight": n("目标权重（0-100，UI 同款），默认 100。", "Target weight (0-100, like UI), default 100.", minimum=0.0, maximum=100.0),
    },
    required=["target"],
))

TOOLS.append(tool(
    "constraint_orientation", "animation",
    "给对象加 Orientation 约束，使其匹配 target 的旋转。",
    "Add an Orientation constraint so the object matches target's rotation.",
    props={
        "objects": arr("被约束的对象名列表；省略则用当前选择。", "Constrained objects; omit for the current selection."),
        "target": s("匹配的目标对象名。", "Matched target object name."),
        "weight": n("目标权重（0-100），默认 100。", "Target weight (0-100), default 100.", minimum=0.0, maximum=100.0),
    },
    required=["target"],
))

TOOLS.append(tool(
    "constraint_path", "animation",
    "给对象加 Path 约束，使其沿一条样条曲线运动。percent 是可在动画中驱动的运动百分比（0-100）。",
    "Add a Path constraint so the object follows a spline. percent is the animatable "
    "travel percentage (0-100) you can drive in the animation.",
    props={
        "objects": arr("被约束的对象名列表；省略则用当前选择。", "Constrained objects; omit for the current selection."),
        "path": s("路径样条对象名。", "Path spline object name."),
        "percent": n("初始运动百分比（0-100）。", "Initial travel percentage (0-100).", minimum=0.0, maximum=100.0),
        "follow": b("true=让对象朝向路径切线方向。", "true=orient the object along the path tangent."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "constraint_link", "animation",
    "给对象加 Link 约束，把对象在指定时间附着到 target（实现拾取/交接动画的关键）。",
    "Add a Link constraint, attaching the object to target at the current time - the "
    "key to pick-up / hand-off animations.",
    props={
        "objects": arr("被约束的对象名列表；省略则用当前选择。", "Constrained objects; omit for the current selection."),
        "target": s("附着目标对象名。", "Attachment target object name."),
        "frame": i("附着发生的帧；省略则用当前帧。", "Frame of attachment; current frame if omitted."),
    },
    required=["target"],
))

TOOLS.append(tool(
    "constraint_surface", "animation",
    "给对象加 Surface 约束，使其贴附在 target 曲面（网格/面片）上并随曲面变形而移动。",
    "Add a Surface constraint so the object sticks to target's surface (mesh/patch) and "
    "moves as the surface deforms.",
    props={
        "objects": arr("被约束的对象名列表；省略则用当前选择。", "Constrained objects; omit for the current selection."),
        "target": s("曲面对象名。", "Surface object name."),
        "u": n("U 参数（0-1）。", "U coordinate (0-1).", minimum=0.0, maximum=1.0),
        "v": n("V 参数（0-1）。", "V coordinate (0-1).", minimum=0.0, maximum=1.0),
    },
    required=["target"],
))

TOOLS.append(tool(
    "constraint_list", "animation",
    "列出对象上所有约束（控制器类型为 *constraint 的轨道）及其目标。只读，支持分页。",
    "List every constraint on an object (tracks whose controller is a *constraint) and "
    "their targets. Read-only, paginated.",
    props={
        "objects": arr("对象名列表；省略则取选择中的第一个。", "Object names; the first of the selection if omitted."),
        "limit": i("最多返回条数，默认 200。", "Maximum entries, default 200."),
        "offset": i("跳过的条数，默认 0。", "Entries to skip, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "constraint_remove", "animation",
    "移除对象某个属性上的约束，并把控制器恢复为默认的 Bezier 控制器（会丢失该约束产生的动画）。",
    "Remove the constraint on a property and reset its controller to the default Bezier "
    "controller (animation produced by the constraint is lost).",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("要解除约束的属性；省略则解除 position。",
                      "Property to free; position if omitted.",
                      enum=["position", "rotation", "scale"]),
    },
))

TOOLS.append(tool(
    "constraint_set_weight", "animation",
    "设置约束中某个目标的权重（0-100，与 UI 一致）。多个目标混合时靠它分配影响力。",
    "Set the weight (0-100, like the UI) of a target in a constraint. With multiple "
    "targets this distributes influence between them.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
        "property": s("属性：position / rotation / scale 等带约束的轨道。",
                      "Property: position / rotation / scale or other constrained track."),
        "targetIndex": i("目标在约束中的序号（从 1 起）。", "Target index in the constraint (1-based)."),
        "weight": n("新权重（0-100）。", "New weight (0-100).", minimum=0.0, maximum=100.0),
    },
    required=["property", "targetIndex", "weight"],
))


# ============================================================ rigging: bones & helpers
TOOLS.append(tool(
    "rig_create_bone", "animation",
    "从根位置沿 direction 方向创建一根骨骼，长度 length、宽 width、高 height。"
    "骨骼是绑定之基，先做这根再 rig_create_bone_chain 串成肢体。",
    "Create one bone from a root position along direction, with length, width and "
    "height. Bones are the basis of rigging - make one, then chain them with "
    "rig_create_bone_chain into a limb.",
    props={
        "position": arr("根位置 [x,y,z]，默认原点。", "Root position [x,y,z], default origin.", items="number"),
        "direction": arr("生长方向 [x,y,z]，默认 X 轴。", "Growth direction [x,y,z], default X axis.", items="number"),
        "length": n("骨骼长度。", "Bone length."),
        "width": n("骨骼宽度。", "Bone width."),
        "height": n("骨骼高度。", "Bone height."),
        "name": s("骨骼名。", "Bone name."),
    },
))

TOOLS.append(tool(
    "rig_create_bone_chain", "animation",
    "在 start 与 end 两点之间创建 count 根骨骼串成一条链——几乎所有肢体（手臂、腿、脊柱）都由它构成。"
    "每根骨的枢轴落在分段起点，并自动父子链接。",
    "Create a chain of count bones between start and end - nearly every limb (arm, leg, "
    "spine) is built from this. Each bone's pivot sits at its segment start and they "
    "are auto parented.",
    props={
        "start": arr("链起点 [x,y,z]。", "Chain start [x,y,z].", items="number"),
        "end": arr("链终点 [x,y,z]。", "Chain end [x,y,z].", items="number"),
        "count": i("骨骼数量（>=2）。", "Number of bones (>=2).", minimum=2),
        "width": n("骨骼宽度。", "Bone width."),
        "height": n("骨骼高度。", "Bone height."),
        "name": s("链根名前缀。", "Chain root name prefix."),
    },
    required=["start", "end", "count"],
))

TOOLS.append(tool(
    "rig_create_dummy", "animation",
    "创建一个虚拟体（Dummy），绑定中常作为控制器/枢轴点。",
    "Create a Dummy helper, commonly used as a rig control / pivot point.",
    props={
        "size": arr("盒体尺寸 [x,y,z]，默认 [10,10,10]。", "Box size [x,y,z], default [10,10,10].", items="number"),
        "position": arr("位置 [x,y,z]，默认原点。", "Position [x,y,z], default origin.", items="number"),
        "name": s("虚拟体名。", "Dummy name."),
    },
))

TOOLS.append(tool(
    "rig_create_point_helper", "animation",
    "创建一个 Point 辅助体，轻量且常作 IK 目标或约束目标。",
    "Create a Point helper, lightweight and often used as an IK or constraint target.",
    props={
        "size": n("显示尺寸。", "Display size."),
        "position": arr("位置 [x,y,z]，默认原点。", "Position [x,y,z], default origin.", items="number"),
        "name": s("辅助体名。", "Helper name."),
    },
))

TOOLS.append(tool(
    "rig_link_objects", "animation",
    "把对象父子链接到 parent，并保持其世界变换不变（即视觉位置/朝向不跳变）。",
    "Parent objects under parent while keeping their world transform unchanged (the "
    "visual position / orientation does not jump).",
    props={
        "objects": arr("要链接的子对象名列表；省略则用当前选择。", "Child object names; omit for the current selection."),
        "parent": s("父对象名。", "Parent object name."),
    },
    required=["parent"],
))

TOOLS.append(tool(
    "rig_set_bone_size", "animation",
    "批量设置骨骼的宽/高（仅影响显示，不影响绑定）。",
    "Set the width / height of bones in bulk (display only, does not affect skinning).",
    props={
        "objects": arr("骨骼名列表；省略则用当前选择。", "Bone names; omit for the current selection."),
        "width": n("宽度（>=0 才设置）。", "Width (set only if >=0)."),
        "height": n("高度（>=0 才设置）。", "Height (set only if >=0)."),
    },
))

TOOLS.append(tool(
    "rig_mirror_bone_chain", "animation",
    "沿某轴镜像一整条骨骼链，并自动重命名 _L/_R——手臂/腿镜像最常用也最繁琐的手工活。"
    "原链保持不动，新建的镜像链带新名。",
    "Mirror a whole bone chain across an axis and auto-rename _L/_R - the most common "
    "yet tedious manual job when mirroring arms/legs. The original chain is left "
    "untouched; the mirrored chain gets new names.",
    props={
        "objects": arr("要镜像的骨骼名列表；省略则用当前选择。", "Bones to mirror; omit for the current selection."),
        "axis": s("镜像轴。", "Mirror axis.", enum=["x", "y", "z"]),
        "suffixL": s("左侧后缀，默认 _L。", "Left suffix, default _L."),
        "suffixR": s("右侧后缀，默认 _R。", "Right suffix, default _R."),
    },
))

TOOLS.append(tool(
    "rig_list_bones", "animation",
    "列出场景中所有骨骼（BoneGeometry）。只读，支持分页。可选 root 只列其子树。",
    "List every bone (BoneGeometry) in the scene. Read-only, paginated. Optional root "
    "limits the listing to its subtree.",
    props={
        "root": s("只列该根下的骨骼（可选）。", "Only list bones under this root (optional)."),
        "limit": i("最多返回条数，默认 500。", "Maximum entries, default 500."),
        "offset": i("跳过的条数，默认 0。", "Entries to skip, default 0."),
    },
    mutating=False,
))


# ============================================================ rigging: skin
TOOLS.append(tool(
    "rig_skin_add", "animation",
    "给网格对象添加 Skin 修改器，为蒙皮做准备。",
    "Add a Skin modifier to a mesh object, preparing it for skinning.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
    },
))

TOOLS.append(tool(
    "rig_skin_add_bone", "animation",
    "把一个骨骼加入对象的 Skin 修改器（可指定 rigid/weighted 初始模式）。",
    "Add a bone to the object's Skin modifier (with an optional rigid / weighted mode).",
    props={
        "objects": arr("带 Skin 的对象名列表；省略则用当前选择。", "Skinned objects; omit for the current selection."),
        "bone": s("要加入的骨骼名。", "Bone name to add."),
        "rigid": b("true=刚性蒙皮（每顶点单一骨骼）。", "true=rigid skinning (one bone per vertex)."),
    },
    required=["bone"],
))

TOOLS.append(tool(
    "rig_skin_set_weight", "animation",
    "设置单个顶点对单个骨骼的权重。注意：顶点权重被归一化到 1.0，把某骨骼设成 1.0 会抹掉其它骨骼影响。",
    "Set one vertex's weight for one bone. Note: vertex weights are normalised to 1.0, "
    "so setting one bone to 1.0 removes every other bone's influence on that vertex.",
    props={
        "objects": arr("带 Skin 的对象名列表；省略则用当前选择。", "Skinned objects; omit for the current selection."),
        "bone": s("骨骼名。", "Bone name."),
        "vertex": i("顶点索引（从 1 起）。", "Vertex index (1-based)."),
        "weight": n("权重（0-1）。", "Weight (0-1).", minimum=0.0, maximum=1.0),
    },
    required=["bone", "vertex", "weight"],
))

TOOLS.append(tool(
    "rig_skin_auto_weight", "animation",
    "运行骨骼热（bone-heat）自动蒙皮权重——2015+ 可用。复杂网格上可能较慢，用 try/catch 保护。",
    "Run the bone-heat automatic skin weighting - available on 2015+. Can be slow on "
    "complex meshes; guarded with try/catch.",
    props={
        "objects": arr("带 Skin 的对象名列表；省略则用当前选择。", "Skinned objects; omit for the current selection."),
    },
))

TOOLS.append(tool(
    "rig_skin_weight_table", "animation",
    "读取对象的蒙皮权重表（顶点 x 骨骼）。只读，支持分页。导出前核对权重很有用。",
    "Read the skin weight table (vertices x bones). Read-only, paginated. Handy to "
    "verify weights before export.",
    props={
        "objects": arr("带 Skin 的对象名列表；省略则取选择中的第一个。",
                       "Skinned objects; the first of the selection if omitted."),
        "limit": i("最多返回顶点数，默认 200。", "Maximum vertices, default 200."),
        "offset": i("跳过的顶点数，默认 0。", "Vertices to skip, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "rig_skin_remove_bone", "animation",
    "从对象的 Skin 修改器移除一根骨骼（该骨骼对所有顶点的影响一并消失）。",
    "Remove a bone from the object's Skin modifier (its influence on all vertices is "
    "gone too).",
    props={
        "objects": arr("带 Skin 的对象名列表；省略则用当前选择。", "Skinned objects; omit for the current selection."),
        "bone": s("要移除的骨骼名。", "Bone name to remove."),
    },
    required=["bone"],
))

TOOLS.append(tool(
    "rig_skin_set_vertex_weights", "animation",
    "批量设置单个顶点对多根骨骼的权重（一组 {bone, weight}）。配合归一化，可一次配好一个顶点的完整影响。",
    "Set one vertex's weights across many bones in bulk (a list of {bone, weight}). "
    "Together with normalisation this configures a vertex's full influence at once.",
    props={
        "objects": arr("带 Skin 的对象名列表；省略则用当前选择。", "Skinned objects; omit for the current selection."),
        "vertex": i("顶点索引（从 1 起）。", "Vertex index (1-based)."),
        "weights": arr("权重列表，每项 {bone, weight}（weight 0-1）。",
                       "Weight list, each {bone, weight} (weight 0-1).", items="object"),
    },
    required=["vertex", "weights"],
))


# ============================================================ rigging: IK
TOOLS.append(tool(
    "rig_ik_solver", "animation",
    "给一根骨骼链加 IK 解算器：HI Solver / HD Solver / Spline IK。会创建并自动绑定 IK 目标（goal）。",
    "Add an IK solver to a bone chain: HI Solver / HD Solver / Spline IK. Creates and "
    "auto-binds the IK goal.",
    props={
        "objects": arr("骨骼链（从根到梢）名列表；省略则用当前选择。",
                       "Bone chain (root to tip) names; omit for the current selection."),
        "type": s("解算器类型。", "Solver type.", enum=["HI", "HD", "Spline"]),
    },
))

TOOLS.append(tool(
    "rig_set_ik_chain", "animation",
    "调整骨骼链的 IK 参数：preferredAngle（首选弯折角）与 swivelAngle（极向量/扭曲角），单位是度。",
    "Tune a bone chain's IK parameters: preferredAngle (the favoured bend) and "
    "swivelAngle (pole/twist angle), in degrees.",
    props={
        "objects": arr("骨骼链名列表；省略则用当前选择。", "Bone chain names; omit for the current selection."),
        "preferredAngle": n("首选弯折角（度）。", "Preferred bend angle (degrees)."),
        "swivelAngle": n("极向量/扭曲角（度）。", "Pole/twist angle (degrees)."),
    },
))

TOOLS.append(tool(
    "rig_ik_goal", "animation",
    "移动 IK 目标（goal）到指定位置；可选 frame 在该帧写入关键帧，从而驱动整条链。",
    "Move the IK goal to a position; with frame the move is keyed at that frame, "
    "driving the whole chain.",
    props={
        "objects": arr("IK 目标对象名列表；省略则用当前选择。", "IK goal object names; omit for the current selection."),
        "position": arr("目标位置 [x,y,z]。", "Goal position [x,y,z].", items="number"),
        "frame": i("写入关键帧的帧；省略则不记录。", "Frame to key at; not recorded if omitted."),
    },
    required=["position"],
))

TOOLS.append(tool(
    "rig_spline_ik", "animation",
    "给骨骼链加 Spline IK 解算器并绑定一条样条曲线，链会沿曲线分布（常用于尾巴、触手、绳索）。",
    "Add a Spline IK solver to a bone chain and bind a spline; the chain distributes "
    "along the curve (tails, tentacles, ropes).",
    props={
        "objects": arr("骨骼链名列表；省略则用当前选择。", "Bone chain names; omit for the current selection."),
        "path": s("样条曲线对象名。", "Spline object name."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "rig_ik_enable", "animation",
    "启用骨骼链上各骨骼的 IK（使其能被 IK 解算器驱动）。",
    "Enable IK on the bones of a chain (so they can be driven by the IK solver).",
    props={
        "objects": arr("骨骼名列表；省略则用当前选择。", "Bone names; omit for the current selection."),
    },
))

TOOLS.append(tool(
    "rig_ik_disable", "animation",
    "禁用骨骼链上各骨骼的 IK（恢复为 FK 手动摆放）。",
    "Disable IK on the bones of a chain (back to manual FK posing).",
    props={
        "objects": arr("骨骼名列表；省略则用当前选择。", "Bone names; omit for the current selection."),
    },
))


# ============================================================ morph
TOOLS.append(tool(
    "rig_morpher_add", "animation",
    "给对象加 Morpher 修改器，为变形目标（blendshape）动画做准备。",
    "Add a Morpher modifier to an object, preparing it for morph target animation.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the current selection."),
    },
))

TOOLS.append(tool(
    "rig_morpher_add_target", "animation",
    "向对象的 Morpher 添加一个变形目标网格（blendshape）。目标需与本体拓扑一致。",
    "Add a morph target mesh (blendshape) to the object's Morpher. The target must "
    "share the base mesh topology.",
    props={
        "objects": arr("带 Morpher 的对象名列表；省略则用当前选择。", "Morphed objects; omit for the current selection."),
        "target": s("变形目标网格名。", "Morph target mesh name."),
    },
    required=["target"],
))

TOOLS.append(tool(
    "rig_morpher_set_value", "animation",
    "设置某个 Morph 通道的权重（0-100）以驱动变形；可选 frame 在该帧写入关键帧。",
    "Set a morph channel's weight (0-100) to drive the deformation; with frame the "
    "value is keyed at that frame.",
    props={
        "objects": arr("带 Morpher 的对象名列表；省略则用当前选择。", "Morphed objects; omit for the current selection."),
        "channel": i("通道序号（从 1 起）。", "Channel index (1-based)."),
        "value": n("权重（0-100）。", "Weight (0-100).", minimum=0.0, maximum=100.0),
        "frame": i("写入关键帧的帧；省略则用当前帧。", "Frame to key at; current frame if omitted."),
    },
    required=["channel", "value"],
))

TOOLS.append(tool(
    "rig_morpher_list", "animation",
    "列出对象 Morpher 的所有通道名与当前值。只读，支持分页。",
    "List every morph channel name and its current value on an object. Read-only, "
    "paginated.",
    props={
        "objects": arr("带 Morpher 的对象名列表；省略则取选择中的第一个。",
                       "Morphed objects; the first of the selection if omitted."),
        "limit": i("最多返回条数，默认 100。", "Maximum entries, default 100."),
        "offset": i("跳过的条数，默认 0。", "Entries to skip, default 0."),
    },
    mutating=False,
))
