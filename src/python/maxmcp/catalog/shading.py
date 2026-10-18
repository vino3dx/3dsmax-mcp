"""Shading catalog: materials, texture maps, UVW, lights, cameras, environment.

Category key: ``shading``.
"""

from __future__ import annotations

from typing import List

from .schema import Tool, arr, b, i, n, s, tool

TOOLS: List[Tool] = []


# =============================================================== material inventory
TOOLS.append(tool(
    "mat_list", "shading",
    "列出场景中所有材质：类名、名称、被多少对象引用（usedBy）。结果分页。"
    "**改材质前先用它确认材质名，再传给 mat_get / mat_assign。**",
    "List every material in the scene with its class, name and how many objects use it "
    "(usedBy). Paginated. **Confirm the material name here before passing it to mat_get "
    "or mat_assign.**",
    props={
        "limit": i("最多返回条数，默认 100。", "Maximum entries to return, default 100."),
        "offset": i("起始偏移，默认 0。", "Starting offset, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "mat_get", "shading",
    "读取一个材质的完整信息：类名、漫反射/高光/粗糙度/金属度/IOR/不透明度/自发光，"
    "以及所有贴图槽（按名字列出槽名、贴图类、位图路径）。名称可用 mat_list 查到。"
    "StandardMaterial 的 diffuse 在 PBR 灯光下会偏暗；PhysicalMaterial 用 Base Color + "
    "Metallic + Roughness。",
    "Read full details of a material: class, diffuse/specular/roughness/metallic/IOR/opacity/"
    "emission, plus every map slot (slot name, map class, bitmap path). Names come from "
    "mat_list. A StandardMaterial's diffuse looks wrong under PBR lighting; PhysicalMaterial "
    "uses Base Color + Metallic + Roughness.",
    props={"material": s("材质名称（字符串）。", "Material name (string).")},
    required=["material"],
    mutating=False,
))

TOOLS.append(tool(
    "mat_get_for_object", "shading",
    "读取一个或多个对象当前使用的材质详情。省略对象则使用当前选择。",
    "Read the material currently assigned to one or more objects. Omit objects to use the "
    "current selection.",
    props={"objects": arr("对象名列表；省略则使用当前选择。",
                         "Object names; omit to use the current selection.")},
    mutating=False,
))

TOOLS.append(tool(
    "mat_slots", "shading",
    "读取材质编辑器（Material Editor）的 24 个槽位，返回每个已占用槽的类名与名称。"
    "这是把材质放进编辑器、或在 mat_set_slot 之前查看空槽的入口。",
    "Read the 24 Material Editor slots, returning the class and name of each occupied slot. "
    "Use it to place a material into the editor or to find an empty slot before mat_set_slot.",
    mutating=False,
))

TOOLS.append(tool(
    "mat_set_slot", "shading",
    "把一个材质放进材质编辑器的指定槽位（1..24）。常用于把新建材质显示到编辑器里。",
    "Put a material into a Material Editor slot (1..24). Handy to surface a freshly created "
    "material in the editor.",
    props={
        "material": s("材质名称。", "Material name."),
        "slot": i("槽位编号 1..24。", "Slot index 1..24.", minimum=1, maximum=24),
    },
    required=["slot", "material"],
))

TOOLS.append(tool(
    "mat_assign", "shading",
    "把材质赋给对象。可传对象列表，省略则赋给当前选择（assign-to-selection）。"
    "Multi/Sub-Object 的逐面分配需要给对象设置面材质 ID，这里只做整体赋值，逐面请配合 "
    "poly 工具设置面 ID。",
    "Assign a material to objects; pass a list or omit to assign to the current selection "
    "(assign-to-selection). Per-face assignment of a Multi/Sub-Object material requires face "
    "material IDs on the object - this tool does whole-object assignment only.",
    props={
        "material": s("材质名称。", "Material name."),
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection."),
    },
    required=["material"],
))

TOOLS.append(tool(
    "mat_set_property", "shading",
    "设置材质的任意命名属性，值会按目标属性的类型自动转换（颜色/数字/布尔/字符串）。"
    "当你要改的属性没有专用工具时用它。**先用 get_class_properties 查准属性名。**",
    "Set any named property of a material; the value is coerced to the target property's type "
    "(color/number/boolean/string). Use it for parameters without a dedicated tool. "
    "**Check the exact property name with get_class_properties first.**",
    props={
        "material": s("材质名称。", "Material name."),
        "property": s("属性名，例如 metallic、roughness、opacity。",
                      "Property name, e.g. metallic, roughness, opacity."),
        "value": s("新值：颜色用 [r,g,b]，数字直接给，布尔给 true/false。",
                   "New value: colour as [r,g,b], numbers directly, booleans true/false."),
    },
    required=["material", "property", "value"],
))

TOOLS.append(tool(
    "mat_set_diffuse", "shading",
    "设置材质的漫反射/基础色。对 StandardMaterial 写入 diffuse，对 PhysicalMaterial 写入 "
    "base_color，自动适配。颜色接受 [r,g,b]（0-255）或 \"#RRGGBB\"。",
    "Set the diffuse/base colour. Writes diffuse for a StandardMaterial and base_color for a "
    "PhysicalMaterial, auto-adapting. Accepts [r,g,b] (0-255) or a \"#RRGGBB\" string.",
    props={
        "material": s("材质名称。", "Material name."),
        "color": arr("漫反射颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Diffuse colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
    },
    required=["material", "color"],
))

TOOLS.append(tool(
    "mat_set_pbr", "shading",
    "一次性设置 PBR 参数：基础色 + 金属度 + 粗糙度 + IOR（反射折射率）。"
    "只对 PhysicalMaterial 等 PBR 材质有效；StandardMaterial 没有这些属性会被忽略。",
    "Set PBR parameters in one call: base colour + metallic + roughness + IOR. Only meaningful "
    "on PhysicalMaterial and similar PBR materials; StandardMaterial lacks these and is skipped.",
    props={
        "material": s("材质名称。", "Material name."),
        "baseColor": arr("基础色 [0-255]，也可传 \"#RRGGBB\"。",
                         "Base colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "metallic": n("金属度 0..1。", "Metallic 0..1.", minimum=0.0, maximum=1.0),
        "roughness": n("粗糙度 0..1。", "Roughness 0..1.", minimum=0.0, maximum=1.0),
        "ior": n("反射折射率，通常 1.0..2.5。", "Reflection/refraction IOR, usually 1.0..2.5."),
    },
    required=["material"],
))

TOOLS.append(tool(
    "mat_set_specular", "shading",
    "设置材质的高光颜色（StandardMaterial 的 specular，或无此属性时 reflection_color）。",
    "Set the specular colour (StandardMaterial's specular, or reflection_color when it has no "
    "specular).",
    props={
        "material": s("材质名称。", "Material name."),
        "color": arr("高光颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Specular colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
    },
    required=["material", "color"],
))

TOOLS.append(tool(
    "mat_set_opacity", "shading",
    "设置材质不透明度。注意 StandardMaterial 的 opacity 范围是 0..100，PhysicalMaterial 多为 "
    "0..1，传值时按目标材质约定给。",
    "Set material opacity. Note StandardMaterial's opacity is 0..100 while PhysicalMaterial is "
    "usually 0..1 - pass the value in the target material's range.",
    props={
        "material": s("材质名称。", "Material name."),
        "opacity": n("不透明度：StandardMaterial 用 0..100，PhysicalMaterial 用 0..1。",
                     "Opacity: 0..100 for StandardMaterial, 0..1 for PhysicalMaterial."),
    },
    required=["material", "opacity"],
))

TOOLS.append(tool(
    "mat_set_emission", "shading",
    "设置材质自发光：颜色（PhysicalMaterial 的 emission_color 或 StandardMaterial 的 "
    "selfIllumColor）以及自发光强度 amount。",
    "Set material emission: a colour (PhysicalMaterial's emission_color or StandardMaterial's "
    "selfIllumColor) and an emission amount.",
    props={
        "material": s("材质名称。", "Material name."),
        "color": arr("自发光颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Emission colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "amount": n("自发光强度；StandardMaterial 为 selfIllumAmount。",
                   "Emission amount; selfIllumAmount for StandardMaterial."),
    },
    required=["material"],
))

TOOLS.append(tool(
    "mat_set_sub_material", "shading",
    "给 Multi/Sub-Object 材质的某个子槽（index，从 1 开始）设置子材质。"
    "可新建一个 subClass 材质，或复用已存在的 sourceMaterial。",
    "Set a sub-material (index, 1-based) of a Multi/Sub-Object material. Creates a new "
    "subClass material or reuses an existing sourceMaterial.",
    props={
        "material": s("Multi/Sub-Object 材质名称。", "Multi/Sub-Object material name."),
        "index": i("子槽编号，从 1 开始。", "Sub-slot index, 1-based.", minimum=1),
        "subClass": s("要新建的子材质类名，例如 Standardmaterial。",
                      "Class name of a new sub-material, e.g. Standardmaterial."),
        "sourceMaterial": s("改为复用已存在的材质名称。", "Reuse an existing material by name instead."),
    },
    required=["material", "index"],
))

TOOLS.append(tool(
    "mat_rename", "shading",
    "重命名一个材质。", "Rename a material.",
    props={
        "material": s("原材质名称。", "Original material name."),
        "name": s("新名称。", "New name."),
    },
    required=["material", "name"],
))

TOOLS.append(tool(
    "mat_delete", "shading",
    "从场景中删除一个材质：把所有引用它的对象材质设为空，并清空编辑器里对应的槽位。"
    "**这会断开对象与材质的关联，但对象本身不会被删除。**",
    "Delete a material from the scene: unassign it from every object that uses it and clear the "
    "matching editor slots. **This detaches the material but does not delete the objects.**",
    props={"material": s("材质名称。", "Material name.")},
    required=["material"],
))

TOOLS.append(tool(
    "mat_duplicate", "shading",
    "克隆一个材质（深拷贝），可选新名称，返回新材质名。用于在不破坏原材质的前提下改一套变体。",
    "Clone a material (deep copy) with an optional new name; returns the new material name. "
    "Use it to derive variants without touching the original.",
    props={
        "material": s("要克隆的材质名称。", "Material to clone."),
        "name": s("新材质名称；省略则原名为加 _copy。", "New name; defaults to original + _copy."),
    },
    required=["material"],
))

TOOLS.append(tool(
    "mat_set_map_slot", "shading",
    "把一个贴图挂到材质的命名槽位（例如 \"diffuseMap\" / \"base_color_map\" / \"bumpMap\"）。"
    "可指定 mapClass（默认 Bitmaptexture）新建贴图，并用 path 指向位图文件。",
    "Attach a map to a named slot of a material (e.g. \"diffuseMap\", \"base_color_map\", "
    "\"bumpMap\"). Creates a map of mapClass (default Bitmaptexture) and points it at path.",
    props={
        "material": s("材质名称。", "Material name."),
        "slot": s("槽位名（材质属性名）。", "Slot name (material property name)."),
        "mapClass": s("贴图类名，默认 Bitmaptexture。", "Map class, default Bitmaptexture."),
        "path": s("位图文件路径（仅 Bitmaptexture 生效）。", "Bitmap file path (for Bitmaptexture)."),
    },
    required=["material", "slot"],
))

TOOLS.append(tool(
    "mat_get_map_slot", "shading",
    "读取材质某个命名槽位上的贴图：贴图类名与位图路径。",
    "Read the map on a named slot of a material: its class and bitmap path.",
    props={
        "material": s("材质名称。", "Material name."),
        "slot": s("槽位名。", "Slot name."),
    },
    required=["material", "slot"],
    mutating=False,
))


# =============================================================== material creation
TOOLS.append(tool(
    "mat_create_standard", "shading",
    "创建一个 StandardMaterial（经典标准材质），可选漫反射颜色，并可顺手赋给对象。"
    "**在 PBR/物理灯光下它表现偏旧；新项目优先用 mat_create_physical。**",
    "Create a StandardMaterial (classic standard) with an optional diffuse colour, optionally "
    "assigning it to objects. **Looks dated under PBR/physical lighting; prefer "
    "mat_create_physical for new work.**",
    props={
        "name": s("材质名称。", "Material name."),
        "diffuse": arr("漫反射颜色 [0-255]，也可传 \"#RRGGBB\"。",
                       "Diffuse colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
))

TOOLS.append(tool(
    "mat_create_physical", "shading",
    "创建一个 PhysicalMaterial（PBR 金属/粗糙度工作流）。可设基础色、金属度、粗糙度，"
    "并可顺手赋给对象。这是现代 3ds Max 的默认材质。",
    "Create a PhysicalMaterial (PBR metal/roughness workflow) with optional base colour, "
    "metallic and roughness, optionally assigning it to objects. This is modern 3ds Max's "
    "default material.",
    props={
        "name": s("材质名称。", "Material name."),
        "baseColor": arr("基础色 [0-255]，也可传 \"#RRGGBB\"。",
                         "Base colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "metallic": n("金属度 0..1。", "Metallic 0..1.", minimum=0.0, maximum=1.0),
        "roughness": n("粗糙度 0..1。", "Roughness 0..1.", minimum=0.0, maximum=1.0),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
))

TOOLS.append(tool(
    "mat_create_arnold", "shading",
    "创建一个 Arnold 材质（aiStandardSurface）。**只有当本机安装了 Arnold 时才可用**；"
    "否则返回 class_missing 错误。用 list_render_engines / does_class_exist 先探测。",
    "Create an Arnold material (aiStandardSurface). **Only available when Arnold is installed "
    "on this machine** - otherwise it returns a class_missing error. Probe first with "
    "list_render_engines / does_class_exist.",
    props={
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
    bridge="mat_create_guarded",
    preset={"className": "aiStandardSurface"},
))

TOOLS.append(tool(
    "mat_create_vray", "shading",
    "创建一个 V-Ray 材质（VRayMtl）。**只有当本机安装了 V-Ray 时才可用**；否则返回 "
    "class_missing。先探测再调用。",
    "Create a V-Ray material (VRayMtl). **Only available when V-Ray is installed** - otherwise "
    "it returns class_missing. Probe before calling.",
    props={
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
    bridge="mat_create_guarded",
    preset={"className": "VRayMtl"},
))

TOOLS.append(tool(
    "mat_create_corona", "shading",
    "创建一个 Corona 材质（CoronaMtl）。**只有当本机安装了 Corona 时才可用**；否则返回 "
    "class_missing。先探测再调用。",
    "Create a Corona material (CoronaMtl). **Only available when Corona is installed** - "
    "otherwise it returns class_missing. Probe before calling.",
    props={
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
    bridge="mat_create_guarded",
    preset={"className": "CoronaMtl"},
))

TOOLS.append(tool(
    "mat_create_fstorm", "shading",
    "创建一个 FStorm 材质（FStormMtl）。**只有当本机安装了 FStorm 时才可用**；否则返回 "
    "class_missing。先探测再调用。",
    "Create an FStorm material (FStormMtl). **Only available when FStorm is installed** - "
    "otherwise it returns class_missing. Probe before calling.",
    props={
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
    bridge="mat_create_guarded",
    preset={"className": "FStormMtl"},
))

TOOLS.append(tool(
    "mat_create_generic", "shading",
    "用任意材质类名创建材质（用 mcpEnsureClass 校验类存在）。"
    "适合创建没有专用工具的冷门材质；类名可通过 get_class_properties 探索。",
    "Create a material from any class name (validated with mcpEnsureClass). Use it for "
    "obscure materials that lack a dedicated tool; discover class names via "
    "get_class_properties.",
    props={
        "className": s("材质类名，例如 Shellac、DoubleSided、Top_Bottom。",
                      "Material class name, e.g. Shellac, DoubleSided, Top_Bottom."),
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
    required=["className"],
))

TOOLS.append(tool(
    "mat_create_multi_sub", "shading",
    "创建一个 Multi/Sub-Object（多维/子对象）材质，指定子槽数量 count。"
    "子槽先用默认占位，再用 mat_set_sub_material 逐个填入。配合对象的面材质 ID 使用。",
    "Create a Multi/Sub-Object material with a given number of sub-slots (count). The slots "
    "start empty; fill them with mat_set_sub_material. Use with face material IDs on objects.",
    props={
        "count": i("子材质数量。", "Number of sub-materials.", minimum=1, maximum=100),
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
    required=["count"],
))

TOOLS.append(tool(
    "mat_create_blend", "shading",
    "创建一个 Blend（混合）材质，用于把两种材质按遮罩混合。",
    "Create a Blend material that mixes two materials by a mask.",
    props={
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
))

TOOLS.append(tool(
    "mat_create_shellac", "shading",
    "创建一个 Shellac（虫漆）材质，用于叠加涂层效果。",
    "Create a Shellac material for layered coat effects.",
    props={
        "name": s("材质名称。", "Material name."),
        "objects": arr("创建后赋给这些对象；省略则不赋值。",
                       "Assign to these objects after creation; omit to skip."),
    },
))


# ============================================================================ maps
TOOLS.append(tool(
    "map_create_bitmap", "shading",
    "创建一个位图贴图（Bitmaptexture），可指定文件路径、是否真实世界缩放、U/V 平铺。"
    "这是最常用的贴图，挂在材质的命名槽位（如 diffuseMap）上。",
    "Create a bitmap texture (Bitmaptexture) with an optional file path, real-world scale and "
    "U/V tiling. The most common map, attached to a material's named slot (e.g. diffuseMap).",
    props={
        "path": s("位图文件路径。", "Bitmap file path."),
        "realWorldScale": b("是否使用真实世界缩放，默认否。", "Use real-world scale, default false."),
        "uTiling": n("U 方向平铺数，默认 1。", "U tiling, default 1."),
        "vTiling": n("V 方向平铺数，默认 1。", "V tiling, default 1."),
    },
))

TOOLS.append(tool(
    "map_set_bitmap_path", "shading",
    "设置材质某个槽位上位图贴图的文件路径。若槽位上还没有贴图，会自动新建一个 Bitmaptexture。",
    "Set the file path of the bitmap map on a material's slot. If there is no map yet, a "
    "Bitmaptexture is created automatically.",
    props={
        "material": s("材质名称。", "Material name."),
        "slot": s("槽位名。", "Slot name."),
        "path": s("位图文件路径。", "Bitmap file path."),
    },
    required=["material", "slot", "path"],
))

TOOLS.append(tool(
    "map_create_checker", "shading",
    "创建一个棋盘格贴图（Checker），可选两个颜色。常用于测试 UV。",
    "Create a Checker map with two optional colours. Useful for testing UVs.",
    props={
        "color1": arr("颜色 1 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 1 [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "color2": arr("颜色 2 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 2 [0-255], or a \"#RRGGBB\" string.", items="integer"),
    },
))

TOOLS.append(tool(
    "map_create_gradient", "shading",
    "创建一个渐变贴图（Gradient），可选三个颜色。",
    "Create a Gradient map with three optional colours.",
    props={
        "color1": arr("颜色 1 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 1 [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "color2": arr("颜色 2 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 2 [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "color3": arr("颜色 3 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 3 [0-255], or a \"#RRGGBB\" string.", items="integer"),
    },
))

TOOLS.append(tool(
    "map_create_gradient_ramp", "shading",
    "创建一个渐变坡度贴图（Gradient Ramp），比普通渐变更灵活（多色标、多种类型）。",
    "Create a Gradient Ramp map, more flexible than a plain gradient (multiple flags, types).",
))

TOOLS.append(tool(
    "map_create_noise", "shading",
    "创建一个噪波贴图（Noise），可选噪波类型（1=常规,2=分形,3=湍流）、尺寸、随机种子与两个颜色。",
    "Create a Noise map with optional noise type (1=regular, 2=fractal, 3=turbulence), size, "
    "seed and two colours.",
    props={
        "noiseType": i("噪波类型：1 常规 / 2 分形 / 3 湍流。", "Noise type: 1 regular / 2 fractal / 3 turbulent."),
        "size": n("噪波尺寸。", "Noise size."),
        "seed": i("随机种子。", "Random seed."),
        "color1": arr("颜色 1 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 1 [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "color2": arr("颜色 2 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 2 [0-255], or a \"#RRGGBB\" string.", items="integer"),
    },
))

TOOLS.append(tool(
    "map_create_falloff", "shading",
    "创建一个衰减贴图（Falloff），常用于 Fresnel 边缘效果，可选两个颜色。",
    "Create a Falloff map, commonly used for Fresnel edge effects, with two optional colours.",
    props={
        "color1": arr("颜色 1 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 1 [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "color2": arr("颜色 2 [0-255]，也可传 \"#RRGGBB\"。",
                      "Colour 2 [0-255], or a \"#RRGGBB\" string.", items="integer"),
    },
))

TOOLS.append(tool(
    "map_create_color_correct", "shading",
    "创建一个色彩校正贴图（Color Correction），可调节亮度等，用于后期调色。",
    "Create a Color Correction map (e.g. brightness) for look-dev colour grading.",
    props={"brightness": n("亮度偏移。", "Brightness offset.")},
))

TOOLS.append(tool(
    "map_create_normal", "shading",
    "创建一个法线贴图（Normal Bump），用于把高模细节烘焙的法线应用到低模。",
    "Create a Normal Bump map to apply baked high-poly normals onto a low-poly mesh.",
))


# ================================================================= material libs
TOOLS.append(tool(
    "mat_library_load", "shading",
    "加载一个 .mat 材质库到当前场景：把其中的材质放进材质编辑器空槽，并返回材质名列表。"
    "这是复用工作室已有 look-dev 的标准方式。",
    "Load a .mat material library into the current scene: its materials are placed into empty "
    "Material Editor slots and their names returned. The standard way to reuse a studio's "
    "existing look-dev.",
    props={"path": s(".mat 材质库文件路径。", ".mat material library file path.")},
    required=["path"],
))

TOOLS.append(tool(
    "mat_library_save", "shading",
    "把一组材质保存为 .mat 材质库文件。省略 materials 时保存材质编辑器所有槽位上的材质。",
    "Save a set of materials to a .mat library file. Omit materials to save everything in the "
    "Material Editor slots.",
    props={
        "path": s(".mat 文件保存路径。", ".mat save path."),
        "materials": arr("要保存的材质名称列表；省略则保存编辑器全部槽位。",
                         "Material names to save; omit to save all editor slots."),
    },
    required=["path"],
))


# ============================================================================= uvw
TOOLS.append(tool(
    "uvw_map", "shading",
    "给对象添加 UVW 贴图修改器（UVW Map），支持平面/圆柱/球/方形包裹/立方体/按面/XYZ 映射，"
    "可设 U/V/W 平铺与尺寸。省略对象则作用于当前选择。",
    "Add a UVW Map modifier with planar/cylindrical/spherical/shrink-wrap/box/face/XYZ mapping "
    "and U/V/W tiling and size. Omit objects to affect the current selection.",
    props={
        "objects": arr("对象名列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection."),
        "mapping": s("映射类型。", "Mapping type.",
                     enum=["planar", "cylindrical", "spherical", "shrink_wrap", "box", "face", "xyz"]),
        "uTiling": n("U 平铺。", "U tiling."),
        "vTiling": n("V 平铺。", "V tiling."),
        "wTiling": n("W 平铺。", "W tiling."),
        "sizeX": n("X 尺寸。", "X size."),
        "sizeY": n("Y 尺寸。", "Y size."),
        "sizeZ": n("Z 尺寸。", "Z size."),
    },
    required=["mapping"],
))

TOOLS.append(tool(
    "uvw_unwrap", "shading",
    "给对象添加 Unwrap UVW（UVW 展开）修改器，进入后可手动编辑 UV。省略对象则作用于当前选择。",
    "Add an Unwrap UVW modifier so UVs can be edited manually. Omit objects to affect the "
    "current selection.",
    props={"objects": arr("对象名列表；省略则使用当前选择。",
                         "Object names; omit to use the current selection.")},
))

TOOLS.append(tool(
    "uvw_quick_peel", "shading",
    "给对象添加 Unwrap UVW 并尝试一键快速剥皮（quick peel）展开。展开需要 UVW 编辑器会话，"
    "若不可用会静默跳过，仅添加修改器。省略对象则作用于当前选择。",
    "Add Unwrap UVW and attempt a one-click quick peel. Peeling needs a UVW editor session and "
    "is skipped silently if unavailable (the modifier is still added). Omit objects to affect "
    "the current selection.",
    props={"objects": arr("对象名列表；省略则使用当前选择。",
                         "Object names; omit to use the current selection.")},
))

TOOLS.append(tool(
    "uvw_get_channels", "shading",
    "查询对象存在哪些 UV 贴图通道（返回受支持的通道编号列表）。省略对象则作用于当前选择。",
    "Report which UV map channels an object has (returns the supported channel indices). Omit "
    "objects to affect the current selection.",
    props={"objects": arr("对象名列表；省略则使用当前选择。",
                         "Object names; omit to use the current selection.")},
    mutating=False,
))


# =========================================================================== lights
TOOLS.append(tool(
    "light_create", "shading",
    "通用灯光创建：支持 omni / free_spot / spot(目标聚光) / directional(目标平行) / "
    "mr_area_omni / mr_area_spot，以及 FStorm/VRay/Corona 面积光（需对应渲染器安装）。"
    "目标型灯光会在给定位置创建并自动偏移目标点。共享参数：名称、位置、颜色、强度/倍增、"
    "投影、衰减、聚光锥角与半影。",
    "Generic light creation: omni / free_spot / spot (target) / directional (target) / "
    "mr_area_omni / mr_area_spot, plus FStorm/VRay/Corona area lights (require the renderer "
    "installed). Target-type lights are created at the given position with an offset target. "
    "Shared params: name, position, colour, intensity/multiplier, shadows, decay, cone angle "
    "and penumbra.",
    props={
        "type": s("灯光类型。", "Light type.",
                  enum=["omni", "free_spot", "spot", "free_directional", "directional",
                        "target_directional", "mr_area_omni", "mr_area_spot",
                        "fstorm", "vray", "corona", "area", "sun"]),
        "name": s("灯光名称。", "Light name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "color": arr("颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "intensity": n("强度（等价于 multiplier，二选一）。", "Intensity (alias of multiplier)."),
        "multiplier": n("倍增/强度。", "Multiplier/intensity."),
        "castShadows": b("是否投影，默认否。", "Cast shadows, default false."),
        "decay": s("衰减类型。", "Decay type.", enum=["none", "inverse", "inverse_square"]),
        "coneAngle": n("聚光锥角（度）。", "Spot cone angle (degrees)."),
        "penumbra": n("聚光半影（度）。", "Spot penumbra (degrees)."),
        "azimuth": n("仅 sun 类型：方位角（度）。", "Sun only: azimuth (degrees)."),
        "altitude": n("仅 sun 类型：高度角（度）。", "Sun only: altitude (degrees)."),
    },
    required=["type"],
))

TOOLS.append(tool(
    "light_create_omni", "shading",
    "创建一个泛光点光源（Omni）。灯光在给定位置创建，可选颜色、倍增、投影、衰减。",
    "Create an Omni light at the given position, with optional colour, multiplier, shadows and "
    "decay.",
    props={
        "name": s("灯光名称。", "Light name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "color": arr("颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "multiplier": n("倍增/强度。", "Multiplier/intensity."),
        "castShadows": b("是否投影，默认否。", "Cast shadows, default false."),
        "decay": s("衰减类型。", "Decay type.", enum=["none", "inverse", "inverse_square"]),
    },
    bridge="light_create",
    preset={"type": "omni"},
))

TOOLS.append(tool(
    "light_create_spot", "shading",
    "创建一个目标聚光灯（Target Spot）。灯光在给定位置创建，目标点自动偏移；可设锥角与半影。",
    "Create a target Spot light at the given position with an auto-offset target. Set cone "
    "angle and penumbra.",
    props={
        "name": s("灯光名称。", "Light name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "color": arr("颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "multiplier": n("倍增/强度。", "Multiplier/intensity."),
        "castShadows": b("是否投影，默认否。", "Cast shadows, default false."),
        "decay": s("衰减类型。", "Decay type.", enum=["none", "inverse", "inverse_square"]),
        "coneAngle": n("聚光锥角（度）。", "Spot cone angle (degrees)."),
        "penumbra": n("聚光半影（度）。", "Spot penumbra (degrees)."),
    },
    bridge="light_create",
    preset={"type": "spot"},
))

TOOLS.append(tool(
    "light_create_directional", "shading",
    "创建一个目标平行光（Target Directional），类似太阳的平行光线。",
    "Create a target Directional light - parallel rays like the sun.",
    props={
        "name": s("灯光名称。", "Light name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "color": arr("颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "multiplier": n("倍增/强度。", "Multiplier/intensity."),
        "castShadows": b("是否投影，默认否。", "Cast shadows, default false."),
    },
    bridge="light_create",
    preset={"type": "directional"},
))

TOOLS.append(tool(
    "light_create_sun", "shading",
    "创建一个日光系统（Daylight，含太阳+天空+罗盘），可用方位角/高度角定位太阳。"
    "**Daylight 类需本机支持；方位/高度会尽力设置，不同版本属性名可能不同。**",
    "Create a Daylight system (sun + sky + compass) positioned by azimuth/altitude. "
    "**The Daylight class must be available; azimuth/altitude are set best-effort since the "
    "property names vary across releases.**",
    props={
        "name": s("日光系统名称。", "Daylight system name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "azimuth": n("方位角（度）。", "Azimuth (degrees)."),
        "altitude": n("高度角（度）。", "Altitude (degrees)."),
    },
    bridge="light_create",
    preset={"type": "sun"},
))

TOOLS.append(tool(
    "light_create_area", "shading",
    "创建一个面积光（默认用 mental ray 面积光 mr_Area_Omni；若装了 VRay/Corona 也可）。"
    "面积光能产生柔和的阴影，适合室内布光。",
    "Create an area light (defaults to the mental ray mr_Area_Omni; VRay/Corona area lights "
    "also work if installed). Area lights produce soft shadows, good for interior lighting.",
    props={
        "name": s("灯光名称。", "Light name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "color": arr("颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "multiplier": n("倍增/强度。", "Multiplier/intensity."),
    },
    bridge="light_create",
    preset={"type": "area"},
))

TOOLS.append(tool(
    "light_list", "shading",
    "列出场景所有灯光：名称、类名、位置。结果分页。",
    "List every light in the scene: name, class and position. Paginated.",
    props={
        "limit": i("最多返回条数，默认 200。", "Maximum entries, default 200."),
        "offset": i("起始偏移，默认 0。", "Starting offset, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "light_get", "shading",
    "读取一个灯光的详情：位置、倍增/强度（跨版本兼容读取）、颜色、是否投影、是否启用。",
    "Read a light's details: position, multiplier/intensity (read defensively across "
    "releases), colour, shadow state and enabled flag.",
    props={"light": s("灯光名称。", "Light name.")},
    required=["light"],
    mutating=False,
))

TOOLS.append(tool(
    "light_set", "shading",
    "修改一个灯光的属性：名称、颜色、倍增/强度、投影、启用、聚光锥角与半影、衰减、位置。"
    "强度在不同版本字段不同（multiplier 或 intensity），两个都接受，按目标灯光的字段写入。",
    "Modify a light: name, colour, multiplier/intensity, shadows, enabled, cone angle, "
    "penumbra, decay and position. Intensity differs across releases (multiplier vs intensity); "
    "both are accepted and written to whichever field the light has.",
    props={
        "light": s("灯光名称。", "Light name."),
        "name": s("新名称。", "New name."),
        "color": arr("颜色 [0-255]，也可传 \"#RRGGBB\"。",
                     "Colour [0-255], or a \"#RRGGBB\" string.", items="integer"),
        "multiplier": n("倍增/强度。", "Multiplier/intensity."),
        "intensity": n("强度（等价于 multiplier）。", "Intensity (alias of multiplier)."),
        "castShadows": b("是否投影。", "Cast shadows."),
        "enabled": b("是否启用。", "Enabled."),
        "coneAngle": n("聚光锥角（度）。", "Spot cone angle (degrees)."),
        "penumbra": n("聚光半影（度）。", "Spot penumbra (degrees)."),
        "decay": s("衰减类型。", "Decay type.", enum=["none", "inverse", "inverse_square"]),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
    },
    required=["light"],
))

TOOLS.append(tool(
    "light_delete", "shading",
    "删除一个灯光。**不可恢复，请谨慎调用。**",
    "Delete a light. **Not recoverable, use with care.**",
    props={"light": s("灯光名称。", "Light name.")},
    required=["light"],
))

TOOLS.append(tool(
    "light_align_to_object", "shading",
    "把一个灯光对准某个对象：灯光移到对象上方，目标型灯光的目标点对准对象位置。",
    "Aim a light at an object: the light moves above the target and a target-type light's "
    "target snaps to the object's position.",
    props={
        "light": s("灯光名称。", "Light name."),
        "objects": arr("目标对象名（取第一个）。", "Target object name (first used)."),
    },
    required=["light", "objects"],
))

TOOLS.append(tool(
    "light_set_sun", "shading",
    "当场景存在日光/太阳系统（Daylight/Sunlight/IES_Sun）时，用方位角/高度角重新定位太阳。"
    "若不存在此类系统则返回 class_missing。",
    "Reposition the sun via azimuth/altitude when a Daylight/Sunlight/IES_Sun system exists in "
    "the scene. Returns class_missing if no such system is present.",
    props={
        "azimuth": n("方位角（度）。", "Azimuth (degrees)."),
        "altitude": n("高度角（度）。", "Altitude (degrees)."),
        "timeOfDay": s("一天中的时间（部分系统支持，尽力设置）。",
                       "Time of day (some systems; best-effort)."),
    },
))


# ========================================================================= cameras
TOOLS.append(tool(
    "cam_create", "shading",
    "创建一个相机：free（自由）或 target（目标）。可设位置、目标点、视场角 fov。",
    "Create a camera: free or target. Set position, target and field-of-view.",
    props={
        "type": s("相机类型。", "Camera type.", enum=["free", "target"]),
        "name": s("相机名称。", "Camera name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "target": arr("目标点 [x,y,z]（仅目标相机）。", "Target [x,y,z] (target camera only).", items="number"),
        "fov": n("视场角（度）。", "Field of view (degrees)."),
    },
    required=["type"],
))

TOOLS.append(tool(
    "cam_create_physical", "shading",
    "创建一个 Physical Camera（物理相机），可设焦距、光圈 f-stop、快门、ISO、景深 DoF、视场角。",
    "Create a Physical Camera with focal length, f-stop, shutter, ISO, depth of field and FOV.",
    props={
        "name": s("相机名称。", "Camera name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "target": arr("目标点 [x,y,z]。", "Target [x,y,z].", items="number"),
        "focalLength": n("焦距（mm）。", "Focal length (mm)."),
        "fStop": n("光圈 f 值。", "Aperture f-stop."),
        "shutterSpeed": n("快门速度。", "Shutter speed."),
        "iso": n("ISO。", "ISO."),
        "depthOfField": b("是否开启景深，默认否。", "Enable depth of field, default false."),
        "fov": n("视场角（度）。", "Field of view (degrees)."),
    },
))

TOOLS.append(tool(
    "cam_get", "shading",
    "读取一个相机的详情：位置、视场角、焦距、是否为当前活动相机。"
    "焦距（focalLength）仅 Physical 相机可读：其他相机类返回 "
    "focalLengthSupported=false 且 focalLength=null（附 note 说明），不会用 0.0 冒充真实值。",
    "Read a camera's details: position, field of view, focal length and whether it is the "
    "active viewport camera. Focal length is only readable on Physical cameras: any other "
    "camera class returns focalLengthSupported=false with focalLength=null (plus a note) "
    "instead of a fake 0.0.",
    props={"camera": s("相机名称。", "Camera name.")},
    required=["camera"],
    mutating=False,
))

TOOLS.append(tool(
    "cam_set", "shading",
    "修改相机的属性：名称、位置、目标点、视场角、焦距、光圈、快门、ISO、景深。",
    "Modify a camera: name, position, target, FOV, focal length, f-stop, shutter, ISO and DOF.",
    props={
        "camera": s("相机名称。", "Camera name."),
        "name": s("新名称。", "New name."),
        "position": arr("位置 [x,y,z]。", "Position [x,y,z].", items="number"),
        "target": arr("目标点 [x,y,z]。", "Target [x,y,z].", items="number"),
        "fov": n("视场角（度）。", "Field of view (degrees)."),
        "focalLength": n("焦距（mm）。", "Focal length (mm)."),
        "fStop": n("光圈 f 值。", "Aperture f-stop."),
        "shutterSpeed": n("快门速度。", "Shutter speed."),
        "iso": n("ISO。", "ISO."),
        "depthOfField": b("是否开启景深。", "Enable depth of field."),
    },
    required=["camera"],
))

TOOLS.append(tool(
    "cam_look_through", "shading",
    "把当前活动视口切换为透过该相机观察（look-through）。",
    "Make the active viewport look through this camera.",
    props={"camera": s("相机名称。", "Camera name.")},
    required=["camera"],
))

TOOLS.append(tool(
    "cam_align_to_view", "shading",
    "把一个相机对齐到当前视口：相机位置与朝向匹配活动视图。目标相机会同步移动目标点。",
    "Align a camera to the current view: its position and orientation match the active view. "
    "A target camera's target is moved too.",
    props={"camera": s("相机名称。", "Camera name.")},
    required=["camera"],
))

TOOLS.append(tool(
    "cam_set_viewport", "shading",
    "把一个相机设为活动视口（可指定第几个视口 viewport）。等价于进入该相机的视图。",
    "Make a camera the active viewport (optionally a specific viewport index). Equivalent to "
    "entering that camera's view.",
    props={
        "camera": s("相机名称。", "Camera name."),
        "viewport": i("视口编号（>0 时指定具体视口）。", "Viewport index (>0 selects a specific one)."),
    },
    required=["camera"],
))

TOOLS.append(tool(
    "cam_list", "shading",
    "列出场景所有相机：名称、类名、位置。结果分页。",
    "List every camera in the scene: name, class and position. Paginated.",
    props={
        "limit": i("最多返回条数，默认 200。", "Maximum entries, default 200."),
        "offset": i("起始偏移，默认 0。", "Starting offset, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "cam_delete", "shading",
    "删除一个相机。**不可恢复，请谨慎调用。**",
    "Delete a camera. **Not recoverable, use with care.**",
    props={"camera": s("相机名称。", "Camera name.")},
    required=["camera"],
))


# ====================================================================== environment
TOOLS.append(tool(
    "env_get", "shading",
    "读取环境设置：背景色、环境光颜色、背景贴图（类名）、当前曝光控制器。",
    "Read the environment: background colour, ambient colour, background map (class) and the "
    "active exposure control.",
    mutating=False,
))

TOOLS.append(tool(
    "env_set_background_color", "shading",
    "设置场景背景色。颜色接受 [r,g,b]（0-255）或 \"#RRGGBB\"。",
    "Set the scene background colour. Accepts [r,g,b] (0-255) or a \"#RRGGBB\" string.",
    props={"color": arr("背景色 [0-255]，也可传 \"#RRGGBB\"。",
                        "Background colour [0-255], or a \"#RRGGBB\" string.", items="integer")},
    required=["color"],
))

TOOLS.append(tool(
    "env_set_background_map", "shading",
    "设置场景背景贴图（用 path 创建一个位图贴图作为 environmentMap）。",
    "Set the scene background map (creates a bitmap from path as the environmentMap).",
    props={"path": s("位图文件路径；省略则只创建空位图。", "Bitmap path; omit to create an empty bitmap.")},
))

TOOLS.append(tool(
    "env_set_ambient", "shading",
    "设置环境光颜色（影响所有未照亮区域的补光）。颜色接受 [r,g,b] 或 \"#RRGGBB\"。",
    "Set the ambient light colour (fills unlit areas). Accepts [r,g,b] or \"#RRGGBB\".",
    props={"color": arr("环境光色 [0-255]，也可传 \"#RRGGBB\"。",
                        "Ambient colour [0-255], or a \"#RRGGBB\" string.", items="integer")},
    required=["color"],
))

TOOLS.append(tool(
    "env_set_exposure", "shading",
    "设置曝光控制器：physical / logarithmic / automatic / linear / none，并可设曝光值 EV。"
    "**none 表示移除曝光控制；physical 为 3ds Max 默认。**",
    "Set the exposure control: physical / logarithmic / automatic / linear / none, with an "
    "optional exposure value (EV). **none removes the control; physical is 3ds Max's default.**",
    props={
        "type": s("曝光控制器类型。", "Exposure control type.",
                  enum=["physical", "logarithmic", "automatic", "linear", "none"]),
        "exposureValue": n("曝光值 EV。", "Exposure value (EV)."),
    },
    required=["type"],
))
