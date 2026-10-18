"""Pipeline catalog: rendering, viewport capture, texture baking and
export/import to game engines.

Category key: ``pipeline``.

Every bridge command name matches a MAXScript ``mcpRegister`` entry in
``max/mcp_render.ms``, ``max/mcp_bake.ms`` and ``max/mcp_export.ms``.
"""

from __future__ import annotations

from typing import List

from .schema import Tool, arr, b, i, n, s, tool

TOOLS: List[Tool] = []


# ============================================================ renderer settings
TOOLS.append(tool(
    "render_set_engine", "pipeline",
    "按友好名称切换生产渲染器：scanline / arnold / vray / corona / fstorm / redshift / "
    "art / quicksilver。会先逐个探测候选类（用 mcpClassExists），若本机没有则报错并列出实际可用的渲染器。"
    "切换渲染器不会改变场景内容，但会重置部分渲染设置。",
    "Switch the production renderer by friendly name: scanline / arnold / vray / corona / "
    "fstorm / redshift / art / quicksilver. Each candidate class is probed with "
    "mcpClassExists; if the machine lacks it the call fails with a clear message listing "
    "the renderers this Max actually has. Switching does not alter the scene but may reset "
    "some render settings.",
    props={
        "engine": s("渲染器友好名。", "Friendly renderer name.",
                   enum=["scanline", "arnold", "vray", "corona", "fstorm", "redshift", "art", "quicksilver"],
                   examples=["arnold"]),
    },
    required=["engine"],
))

TOOLS.append(tool(
    "render_get_engine", "pipeline",
    "返回当前生产渲染器的类名。",
    "Return the class name of the current production renderer.",
    mutating=False,
))

TOOLS.append(tool(
    "render_get_settings", "pipeline",
    "返回渲染设置的快照：分辨率、像素比、输出路径与格式、时间范围类型、起止帧、"
    "选帧字符串、是否保存文件。用于确认导出/渲染前的配置。",
    "Return a snapshot of the render settings: resolution, pixel aspect, output path and "
    "format, time-range type, start/end frames, the selected-frames string and whether "
    "file saving is enabled. Use it to confirm the configuration before rendering.",
    mutating=False,
))

TOOLS.append(tool(
    "render_set_resolution", "pipeline",
    "设置渲染分辨率（宽、高、像素比）。任一项省略则保持不变。",
    "Set the render resolution (width, height, pixel aspect). Omit any field to leave it "
    "unchanged.",
    props={
        "width": i("像素宽。", "Pixel width."),
        "height": i("像素高。", "Pixel height."),
        "pixelAspect": n("像素宽高比，默认 1.0。", "Pixel aspect ratio, default 1.0."),
    },
))

TOOLS.append(tool(
    "render_set_output", "pipeline",
    "设置渲染输出文件路径与格式（png/jpg/tga/tif/exr/hdr）。会自动开启「保存到文件」。"
    "路径缺扩展名时会按格式补全。",
    "Set the render output file path and format (png/jpg/tga/tif/exr/hdr). Turns on "
    "\"save to file\" automatically. A missing extension is appended from the format.",
    props={
        "path": s("输出文件绝对路径（可带或不带扩展名）。", "Absolute output path (with or without extension)."),
        "format": s("图像格式。", "Image format.", enum=["png", "jpg", "tga", "tif", "exr", "hdr"]),
    },
    required=["path"],
))

TOOLS.append(tool(
    "render_set_quality", "pipeline",
    "设置一个通用的质量/采样旋钮，并尽可能写入渲染器特定的采样参数（aaSamples、samples 等）。"
    "不同渲染器的属性名差异很大，无法写入的会被忽略；用 render_get_settings 核对是否生效。",
    "Set a generic quality/sampling knob and, where the renderer exposes them, "
    "renderer-specific sampling properties (aaSamples, samples, ...). Property names vary "
    "greatly between renderers; anything it does not understand is silently ignored. "
    "Verify with render_get_settings.",
    props={
        "quality": s("质量档位（如 low/medium/high/production）；渲染器不支持则忽略。",
                    "Quality tier (e.g. low/medium/high/production); ignored if unsupported."),
        "samples": n("采样数/细分；渲染器不支持则忽略。", "Sample count / subdiv; ignored if unsupported."),
        "antialiasing": b("是否开启抗锯齿，默认是。", "Enable antialiasing, default true."),
    },
))

TOOLS.append(tool(
    "render_set_frame_range", "pipeline",
    "设置要渲染的帧范围：scene（活动时间段）/ single（单帧）/ range（起止帧）/ frames（选帧字符串）。"
    "single 可省略 mode 直接用 frame 指定帧号。",
    "Set which frames to render: scene (active time segment) / single (one frame) / range "
    "(start..end) / frames (a selected-frames string). For single you may skip mode and "
    "pass frame directly.",
    props={
        "mode": s("范围模式。", "Range mode.", enum=["scene", "single", "range", "frames"]),
        "start": i("range 模式的起始帧。", "Start frame for range mode."),
        "end": i("range 模式的结束帧。", "End frame for range mode."),
        "frame": i("single 模式的帧号。", "Frame number for single mode."),
        "frames": s("frames 模式的选帧字符串，例如 \"1,3,5-9\"。", "Selected-frames string for frames mode, e.g. \"1,3,5-9\"."),
    },
))

TOOLS.append(tool(
    "render_save_preset", "pipeline",
    "把当前渲染预设保存为 .rps 文件。缺扩展名会自动补 .rps。",
    "Save the current render preset to a .rps file. A missing extension is completed to "
    ".rps automatically.",
    props={"path": s("目标 .rps 文件路径。", "Destination .rps file path.")},
    required=["path"],
))

TOOLS.append(tool(
    "render_load_preset", "pipeline",
    "从 .rps 文件载入渲染预设。文件不存在时报错。",
    "Load a render preset from a .rps file. Fails if the file does not exist.",
    props={"path": s(".rps 预设文件路径。", ".rps preset file path.")},
    required=["path"],
))


# ================================================================ rendering
TOOLS.append(tool(
    "render_still", "pipeline",
    "渲染当前（或指定）帧到文件，并返回解析后的输出路径与文件是否真的写出来了。"
    "渲染会阻塞 3ds Max，调用会一直等到完成。省略 path 时写到渲染输出目录。",
    "Render the current frame (or a named frame) to a file and return the resolved output "
    "path plus whether the file was actually written. Rendering blocks 3ds Max, so the "
    "call waits until it finishes. Omit path to render into the render output folder.",
    props={
        "path": s("输出文件绝对路径；省略则写入渲染输出目录。", "Absolute output path; omit to use the render output folder."),
        "frame": i("要渲染的帧号；省略为当前帧。", "Frame to render; omit for the current frame."),
    },
))

TOOLS.append(tool(
    "render_frames", "pipeline",
    "渲染一串明确的帧号，每帧一个文件（文件名按帧号编号）。返回每个文件的写入结果。"
    "渲染一整批会非常慢，调用会阻塞直到全部完成。",
    "Render an explicit list of frames, one file per frame (numbered by frame index). "
    "Returns the write result for each file. A whole batch can take minutes and the call "
    "blocks until everything is done.",
    props={
        "frames": arr("要渲染的帧号列表。", "List of frame numbers to render.", items="integer"),
        "path": s("输出基准路径；省略则写入渲染输出目录。", "Base output path; omit to use the render output folder."),
    },
    required=["frames"],
))

TOOLS.append(tool(
    "render_animation", "pipeline",
    "渲染整个动画范围或其中的一个子区间，每帧一个文件。渲染整段会非常慢，调用阻塞直到完成。",
    "Render the whole animation range or a sub-range, one file per frame. Rendering a full "
    "sequence can take minutes; the call blocks until it finishes.",
    props={
        "start": i("起始帧；省略用场景动画范围起点。", "First frame; omit to use the scene animation range start."),
        "end": i("结束帧；省略用场景动画范围终点。", "Last frame; omit to use the scene animation range end."),
        "path": s("输出基准路径；省略则写入渲染输出目录。", "Base output path; omit to use the render output folder."),
    },
))

TOOLS.append(tool(
    "render_camera_view", "pipeline",
    "通过指定相机渲染一帧。相机名解析不到时报错。",
    "Render a single frame through a named camera. Fails if the camera name does not "
    "resolve to a node.",
    props={
        "camera": s("相机对象名。", "Camera object name."),
        "path": s("输出文件绝对路径；省略则写入渲染输出目录。", "Absolute output path; omit to use the render output folder."),
        "frame": i("要渲染的帧号；省略为当前帧。", "Frame to render; omit for the current frame."),
    },
    required=["camera"],
))

TOOLS.append(tool(
    "render_region", "pipeline",
    "只渲染画面上的一个矩形区域（像素坐标 x,y,width,height）——典型的「先看看这块灯光对不对」工作流。",
    "Render only a rectangular region of the frame in pixel coordinates "
    "x,y,width,height - the classic \"check the lighting on this one area\" workflow.",
    props={
        "x": i("区域左上角 x（像素）。", "Region left x in pixels."),
        "y": i("区域左上角 y（像素）。", "Region top y in pixels."),
        "width": i("区域宽（像素）；省略用整宽。", "Region width in pixels; omit for full width."),
        "height": i("区域高（像素）；省略用整高。", "Region height in pixels; omit for full height."),
        "path": s("输出文件绝对路径；省略则写入渲染输出目录。", "Absolute output path; omit to use the render output folder."),
        "frame": i("要渲染的帧号；省略为当前帧。", "Frame to render; omit for the current frame."),
    },
))

TOOLS.append(tool(
    "render_preview", "pipeline",
    "生成一段预览动画文件（默认 .avi）。用于快速检查运动而不做正式渲染。",
    "Make a preview animation file (default .avi). Use it for a quick motion check without "
    "a full render.",
    props={"path": s("预览文件绝对路径；省略用预览目录。", "Absolute preview path; omit to use the preview folder.")},
))

TOOLS.append(tool(
    "render_batch", "pipeline",
    "一次调用里排队渲染多个「相机 + 路径 + 帧」组合。jobs 是对象数组，每项含 camera、path、frame。"
    "返回每项的写入结果。整批会较慢，调用阻塞直到完成。",
    "Queue several camera/path/frame combinations in one call. jobs is an array of objects, "
    "each with camera, path and frame. Returns the write result per job. The whole batch "
    "is slow and the call blocks until done.",
    props={
        "jobs": arr("渲染任务数组，每项 {camera, path, frame}。",
                    "Array of render jobs, each {camera, path, frame}.", items="object"),
    },
    required=["jobs"],
))


# ============================================================ render elements
TOOLS.append(tool(
    "render_elements_list", "pipeline",
    "列出当前场景已添加的渲染元素（ZDepth、Normal、ObjectID、Alpha、Reflection 等），支持 limit/offset 分页。",
    "List the render elements currently added to the scene (ZDepth, Normal, ObjectID, "
    "Alpha, Reflection, ...) with limit/offset pagination.",
    props={
        "limit": i("最多返回条数，默认 100。", "Maximum entries, default 100."),
        "offset": i("跳过条数，默认 0。", "Skip count, default 0."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "render_element_add", "pipeline",
    "添加一个渲染元素：zdepth / normal / objectid / materialid / alpha / reflection / "
    "refraction / specular / diffuse / lighting / shadows / ao / sss / uv / velocity 等。"
    "ZDepth、Normal 等需要显式输出路径，否则渲染会静默跳过——可在此用 output 指定。",
    "Add a render element: zdepth / normal / objectid / materialid / alpha / reflection / "
    "refraction / specular / diffuse / lighting / shadows / ao / sss / uv / velocity. "
    "ZDepth, Normal and friends need an explicit output path or the render silently skips "
    "them - pass output here to set one.",
    props={
        "element": s("渲染元素友好名。", "Render element friendly name.",
                    examples=["zdepth", "normal", "objectid", "alpha", "reflection"]),
        "output": s("可选的输出文件路径；建议对 ZDepth/Normal 等显式指定。",
                    "Optional output file path; recommended for ZDepth/Normal etc."),
    },
    required=["element"],
))

TOOLS.append(tool(
    "render_element_remove", "pipeline",
    "按索引或友好名移除一个渲染元素。",
    "Remove a render element by index or by friendly name.",
    props={
        "element": s("要移除的渲染元素友好名；与 index 二选一。", "Friendly name of the element to remove; alternative to index."),
        "index": i("要移除的渲染元素索引（0 起）；与 element 二选一。", "0-based index of the element to remove; alternative to element."),
    },
))

TOOLS.append(tool(
    "render_element_set_output", "pipeline",
    "给一个渲染元素设置输出文件路径。ZDepth、Normal 等若不设路径，渲染会静默跳过。",
    "Set the output file path for a render element. Without a path, ZDepth, Normal and "
    "friends are silently skipped by the render.",
    props={
        "element": s("渲染元素友好名；与 index 二选一。", "Friendly name; alternative to index."),
        "index": i("渲染元素索引（0 起）；与 element 二选一。", "0-based index; alternative to element."),
        "output": s("输出文件路径。", "Output file path."),
    },
    required=["output"],
))


# ============================================================ vision (images)
# The only three tools that return pictures.  Everything else answers in JSON,
# which is precise but blind: no JSON reply tells you the box is inside out, the
# material came out white, or the model sits half off-screen.  The MAXScript side
# parks base64 in the result's "_images" array and server._split_images turns it
# into real MCP image content blocks.

TOOLS.append(tool(
    "vision_capture", "pipeline",
    "抓取当前活动视口并直接返回图像本身（不是文件路径）。每次改动几何体、材质或灯光之后都该抓一张，"
    "确认这一步实际做成了什么样。长边默认压到 800px 以控制体积。",
    "Capture the active viewport and return the image itself, not a path. Grab one after "
    "every change to geometry, materials or lights to see what the edit actually produced. "
    "The long edge is downscaled to 800px to keep the payload small.",
    props={
        "max_edge": i("图片长边像素上限，默认 800。越大越清楚，也越慢、越占上下文。",
                      "Long-edge pixel budget, default 800. Larger is sharper but slower and eats context.",
                      default=800, minimum=64, maximum=2048),
        "format": s("图像格式：jpeg（默认，体积小）或 png（无损）。",
                    "Image format: jpeg (default, small) or png (lossless).",
                    enum=["jpeg", "png"]),
        "redraw": b("抓图前强制重绘，默认 true。关掉会拿到上一帧的画面。",
                    "Force a redraw before grabbing, default true. Off captures the previous frame.",
                    default=True),
        "path": s("可选：同时把图片另存到该绝对路径，方便人直接打开查看。",
                  "Optional: also write the image to this absolute path for a human to open."),
    },
    mutating=False,
))

TOOLS.append(tool(
    "vision_views", "pipeline",
    "依次切到多个标准视图各抓一张，一次返回多张独立图像（不拼成网格图——拼图会被整体降采样，"
    "每格细节损失数倍）。判断模型全貌、比例和空间关系时用它。默认 透视 + 前 + 左 + 顶。",
    "Sweep several standard views and return each as its own image instead of a grid - a "
    "mosaic gets downscaled as a whole and loses detail per cell. Use it to judge overall "
    "shape, proportion and spatial layout. Defaults to perspective + front + left + top.",
    props={
        "views": arr(
            "要抓的视图名列表，可选 perspective/front/back/left/right/top/bottom/orthographic/user。",
            "View names to capture: perspective/front/back/left/right/top/bottom/orthographic/user.",
            items="string",
        ),
        "max_edge": i("每张图的长边像素，默认 800。",
                      "Long edge per image, default 800.",
                      default=800, minimum=64, maximum=2048),
        "format": s("图像格式：jpeg（默认）或 png。", "Image format: jpeg (default) or png.",
                    enum=["jpeg", "png"]),
        "fit": b("抓图前把视图缩放到场景（有选择时缩放到选择），默认 true。",
                 "Frame the scene before each grab, or the selection when there is one; default true.",
                 default=True),
        "restore": b("抓完后恢复原来的视图类型和视角，默认 true。",
                     "Restore the original view type and framing afterwards; default true.",
                     default=True),
    },
    mutating=False,
))

TOOLS.append(tool(
    "vision_preview", "pipeline",
    "低分辨率渲染一张预览图。视口截图反映不了真实材质和灯光，确认灯光、材质和最终效果时用这个。"
    "注意：场景改动后第一次渲染可能要几十秒（着色器编译），别当成卡死。",
    "Render a low-resolution preview. A viewport grab does not show real shading - use this "
    "to verify lights, materials and the final look. The first render after a scene change "
    "can take tens of seconds while shaders compile; that is not a hang.",
    props={
        "max_edge": i("渲染图长边像素，默认 640，上限 1600。越大越慢。",
                      "Rendered long edge, default 640, max 1600. Larger is slower.",
                      default=640, minimum=64, maximum=1600),
    },
    mutating=False,
))


# ================================================================ viewport
TOOLS.append(tool(
    "viewport_capture", "pipeline",
    "把当前活动视口抓取到一张图片文件并返回路径——这是 AI「看到」自己刚搭建的场景的主要方式。",
    "Grab the active viewport into an image file and return the path - this is how the AI "
    "gets to see what it just built.",
    props={"path": s("输出图片绝对路径；省略则写入渲染输出目录（.png）。", "Absolute image path; omit to write to the render output folder (.png).")},
))

TOOLS.append(tool(
    "viewport_capture_all", "pipeline",
    "把当前所有视口拼到一张网格图里并保存。便于一次看清顶/前/透视图的布局。",
    "Capture every viewport into a single grid image and save it. Handy for seeing the "
    "top/front/perspective layout at once.",
    props={"path": s("输出图片绝对路径；省略则写入渲染输出目录（.png）。", "Absolute image path; omit to write to the render output folder (.png).")},
))

TOOLS.append(tool(
    "viewport_set_view", "pipeline",
    "切换活动视口为标准视图：top/bottom/front/back/left/right/orthographic/perspective/user。",
    "Switch the active viewport to a standard view: top/bottom/front/back/left/right/"
    "orthographic/perspective/user.",
    props={
        "view": s("目标视图。", "Target view.",
                  enum=["top", "bottom", "front", "back", "left", "right", "orthographic", "perspective", "user"]),
    },
    required=["view"],
))

TOOLS.append(tool(
    "viewport_set_layout", "pipeline",
    "切换视口布局：单视图 / 水平双格 / 垂直双格 / 三格 / 四格 / 最大化。",
    "Switch the viewport layout: single / horizontal split / vertical split / three / "
    "quad / maximize.",
    props={
        "layout": s("布局名。", "Layout name.",
                   enum=["single", "2h", "2v", "3", "4", "max"]),
    },
    required=["layout"],
))

TOOLS.append(tool(
    "viewport_zoom_extents", "pipeline",
    "把所有视口缩放到合适大小：selection=true 只框选当前选择，否则框整个场景。",
    "Zoom all viewports to fit: selection=true frames only the current selection, "
    "otherwise the whole scene.",
    props={"selection": b("是否只框选当前选择，默认否。", "Frame only the current selection, default false.")},
))

TOOLS.append(tool(
    "viewport_set_shading", "pipeline",
    "设置活动视口的着色方式：wireframe / flat / shaded / realistic / edged（带边面）/ noedges。",
    "Set the active viewport shading mode: wireframe / flat / shaded / realistic / edged "
    "(edge faces on) / noedges.",
    props={
        "mode": s("着色方式。", "Shading mode.",
                  enum=["wireframe", "flat", "shaded", "realistic", "edged", "noedges"]),
    },
    required=["mode"],
))

TOOLS.append(tool(
    "viewport_stats", "pipeline",
    "返回每个视口的分辨率、当前活动视口编号、当前视图类型与活动相机名。",
    "Return each viewport's resolution, the active viewport index, the current view type "
    "and the active camera name.",
    mutating=False,
))

TOOLS.append(tool(
    "viewport_toggle_grid", "pipeline",
    "显示或隐藏活动视口的网格。show=true 显示，false 隐藏。",
    "Show or hide the active viewport grid. show=true shows it, false hides it.",
    props={"show": b("是否显示网格，默认是。", "Show the grid, default true.")},
))


# ================================================================ texture bake
TOOLS.append(tool(
    "bake_texture", "pipeline",
    "Render To Texture：把选中对象当前材质的贴图烘焙到目标文件夹——把一个 Max 资产带外观送进游戏引擎最常用的工具。"
    "要求对象有 UVW 通道与合理的壳/偏移；否则会得到重叠 UV 与糊掉的贴图（可用 bake_set_output 先设输出）。",
    "Render To Texture: bake the selected objects' current material maps into a target "
    "folder - the single most used tool for getting a Max asset into a game engine with "
    "its look intact. The objects must have a UVW channel and a clean shell/offset, "
    "otherwise you get overlapping UVs and a smeared map. Set the output first with "
    "bake_set_output.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit to use the current selection."),
        "folder": s("输出文件夹；省略用上次 bake_set_output 的值或渲染输出目录。", "Output folder; omit to use the last bake_set_output value or the render output folder."),
        "size": i("贴图边长（像素）；省略用上次设置，默认 512。", "Map edge size in pixels; omit to use the last setting, default 512."),
        "format": s("贴图格式，默认 png。", "Map format, default png."),
        "template": s("文件名模板，%s=对象名 %e=元素名。", "Filename template, %s=object name %e=element name."),
        "elements": arr("要烘焙的元素；省略为 diffuse+lighting。", "Elements to bake; omit for diffuse+lighting.", items="string"),
    },
))

TOOLS.append(tool(
    "bake_ao", "pipeline",
    "把环境光遮蔽（AO）烘焙成一张贴图。同 bake_texture 的要求：对象需有 UVW 通道与壳。",
    "Bake ambient occlusion (AO) into a single map. Same requirement as bake_texture: the "
    "objects need a UVW channel and a shell.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit to use the current selection."),
        "folder": s("输出文件夹；省略用上次设置或渲染输出目录。", "Output folder; omit to use the last setting or render output folder."),
        "size": i("贴图边长（像素），默认 512。", "Map edge size in pixels, default 512."),
        "format": s("贴图格式，默认 png。", "Map format, default png."),
    },
))

TOOLS.append(tool(
    "bake_normals", "pipeline",
    "把法线贴图从高模烘焙到低模壳（NormalMap）。需对象有 UVW 通道；高低模关系由 Max 的 RTT 投影设置决定。",
    "Bake a normal map from a high-poly cage to a low-poly shell (NormalMap). Requires a "
    "UVW channel; the high/low relationship is governed by Max's RTT projection setup.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit to use the current selection."),
        "folder": s("输出文件夹；省略用上次设置或渲染输出目录。", "Output folder; omit to use the last setting or render output folder."),
        "size": i("贴图边长（像素），默认 512。", "Map edge size in pixels, default 512."),
        "format": s("贴图格式，默认 png。", "Map format, default png."),
    },
))

TOOLS.append(tool(
    "bake_lighting", "pipeline",
    "把灯光/完整贴图（LightingMap 或 CompleteMap）烘焙成贴图，用于静态光照。要求对象有 UVW 通道。",
    "Bake lighting / a complete map (LightingMap or CompleteMap) for static lighting. "
    "Requires a UVW channel on the objects.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit to use the current selection."),
        "folder": s("输出文件夹；省略用上次设置或渲染输出目录。", "Output folder; omit to use the last setting or render output folder."),
        "size": i("贴图边长（像素），默认 512。", "Map edge size in pixels, default 512."),
        "format": s("贴图格式，默认 png。", "Map format, default png."),
    },
))

TOOLS.append(tool(
    "bake_set_output", "pipeline",
    "设置烘焙的全局输出参数：文件夹、贴图尺寸、格式、文件名填充位数与模板（%s=对象名 %e=元素名）。",
    "Set the global bake output parameters: folder, map size, format, filename padding "
    "and template (%s=object name, %e=element name).",
    props={
        "folder": s("默认输出文件夹。", "Default output folder."),
        "size": i("贴图边长（像素），默认 512。", "Map edge size in pixels, default 512."),
        "format": s("贴图格式，默认 png。", "Map format, default png."),
        "padding": i("帧号/序号填充位数，默认 4。", "Number padding width, default 4."),
        "template": s("文件名模板，默认 %s_%e。", "Filename template, default %s_%e."),
    },
))

TOOLS.append(tool(
    "bake_objects", "pipeline",
    "底层烘焙调用：用显式的元素列表烘焙一组对象。elements 为必填（如 #(\"diffuse\",\"normal\")）。"
    "返回每个贴图的写入结果，缺失文件会列在 failures/written 里。",
    "Low level bake: bake a list of objects with an explicit element list. elements is "
    "required (e.g. [\"diffuse\",\"normal\"]). Returns per-map write results; missing files "
    "appear in failures/written.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit to use the current selection."),
        "elements": arr("要烘焙的元素名列表（必填）。", "Element names to bake (required).", items="string"),
        "folder": s("输出文件夹；省略用上次设置或渲染输出目录。", "Output folder; omit to use the last setting or render output folder."),
        "size": i("贴图边长（像素），默认 512。", "Map edge size in pixels, default 512."),
        "format": s("贴图格式，默认 png。", "Map format, default png."),
        "template": s("文件名模板，默认 %s_%e。", "Filename template, default %s_%e."),
    },
    required=["elements"],
))

TOOLS.append(tool(
    "bake_get_settings", "pipeline",
    "返回烘焙的当前全局输出设置（文件夹、尺寸、格式、填充、模板）。",
    "Return the current global bake output settings (folder, size, format, padding, "
    "template).",
    mutating=False,
))


# ================================================================ export
TOOLS.append(tool(
    "export_fbx", "pipeline",
    "主力导出：FBX，可选 Unity/Unreal/Maya 预设、只导出选择、烘焙动画、动画开关、上轴与单位。"
    "警告：units=automatic 且场景是 1 单位时，会导出成 1 单位模型——Unity 与 Unreal 都用米，"
    "所以先用 set_units 设好单位比例再导出。",
    "The workhorse: FBX, with optional Unity/Unreal/Maya preset, selection-only, animation "
    "baking, animation toggle, up-axis and units. WARNING: with units=automatic and a "
    "1-unit scene you export a 1-unit model - both Unity and Unreal expect metres, so set "
    "the unit scale first with set_units before exporting.",
    props={
        "path": s("输出 .fbx 文件路径（缺扩展名自动补）。", "Output .fbx path (extension added if missing)."),
        "preset": s("目标预设。", "Target preset.", enum=["unity", "unreal", "maya", "generic"], default="unreal"),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
        "bakeAnimation": b("是否烘焙动画，默认否。", "Bake animation, default false."),
        "animation": b("是否包含动画，默认否。", "Include animation, default false."),
        "upAxis": s("上轴 y/z，默认 z（Unreal 用 z，Unity 用 y）。", "Up axis y/z, default z (Unreal z, Unity y).", enum=["y", "z"]),
        "units": s("单位 automatic/meters/centimeters；建议先 set_units。", "Units automatic/meters/centimeters; prefer set_units first."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_obj", "pipeline",
    "导出 Wavefront OBJ（可选只导出选择）。无动画/无材质实例，适合静态网格。",
    "Export a Wavefront OBJ (optionally selection only). No animation or material "
    "instances - fine for static meshes.",
    props={
        "path": s("输出 .obj 文件路径。", "Output .obj path."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_gltf", "pipeline",
    "导出 glTF / GLB。glTF 是插件，若本机未安装会直接报错（err.class_missing）。",
    "Export glTF / GLB. glTF is a plugin - if this Max lacks it the call fails with "
    "err.class_missing.",
    props={
        "path": s("输出 .gltf 或 .glb 文件路径。", "Output .gltf or .glb path."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_usd", "pipeline",
    "导出 USD。USD 是插件，若本机未安装会直接报错（err.class_missing）。",
    "Export USD. USD is a plugin - if this Max lacks it the call fails with "
    "err.class_missing.",
    props={
        "path": s("输出 .usd/.usda/.usdc 文件路径。", "Output .usd/.usda/.usdc path."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_abc", "pipeline",
    "导出 Alembic (.abc)。Alembic 是插件，若本机未安装会直接报错（err.class_missing）。",
    "Export Alembic (.abc). Alembic is a plugin - if this Max lacks it the call fails "
    "with err.class_missing.",
    props={
        "path": s("输出 .abc 文件路径。", "Output .abc path."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_stl", "pipeline",
    "导出 STL（3D 打印/逆向常用）。若本机没有对应导出器会报错。",
    "Export STL (common for 3D printing / reverse engineering). Fails if this Max has no "
    "matching exporter.",
    props={
        "path": s("输出 .stl 文件路径。", "Output .stl path."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_3ds", "pipeline",
    "导出旧的 3DS 格式。若本机没有对应导出器会报错。",
    "Export the legacy 3DS format. Fails if this Max has no matching exporter.",
    props={
        "path": s("输出 .3ds 文件路径。", "Output .3ds path."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "export_engine_preset", "pipeline",
    "一键为指定目标引擎选好格式与选项的便捷调用：unity / unreal / godot / maya / blender / generic。"
    "目前统一走 FBX 并套用对应上轴与预设（Blender/Godot 也用 FBX，更稳）。",
    "One call that picks the right format and options for a named target engine: unity / "
    "unreal / godot / maya / blender / generic. Currently routes through FBX with the "
    "matching up-axis and preset (Blender/Godot also use FBX for robustness).",
    props={
        "engine": s("目标引擎。", "Target engine.", enum=["unity", "unreal", "godot", "maya", "blender", "generic"]),
        "path": s("输出基准路径；省略用导出目录。", "Base output path; omit to use the export folder."),
        "selected": b("是否只导出当前选择，默认是。", "Export only the current selection, default true."),
        "animation": b("是否包含动画，默认否。", "Include animation, default false."),
        "bakeAnimation": b("是否烘焙动画，默认否。", "Bake animation, default false."),
        "units": s("单位 automatic/meters/centimeters。", "Units automatic/meters/centimeters."),
    },
    required=["engine"],
))

TOOLS.append(tool(
    "export_selection", "pipeline",
    "把当前选择按文件扩展名对应的格式导出（引擎未知时很有用）。导出器不存在会报错。",
    "Export the current selection using the format implied by the file extension (handy "
    "when the engine is unknown). Fails if the exporter for that extension is missing.",
    props={"path": s("输出文件路径，扩展名决定格式。", "Output path; the extension decides the format.")},
    required=["path"],
))

TOOLS.append(tool(
    "export_get_last_report", "pipeline",
    "返回上一次导出调用的结果摘要（路径、预设等）。便于排查导出失败。",
    "Return the result summary of the last export call (path, preset, ...). Useful for "
    "troubleshooting a failed export.",
    mutating=False,
))


# ================================================================ import
TOOLS.append(tool(
    "import_fbx", "pipeline",
    "导入 FBX。file 不存在则报错；merge=true 时合并进当前场景，否则替换。",
    "Import an FBX. Fails if the file is missing; with merge=true it merges into the "
    "current scene, otherwise it replaces it.",
    props={
        "path": s("要导入的 .fbx 文件路径。", "FBX file path to import."),
        "merge": b("是否合并进当前场景，默认否（替换）。", "Merge into the current scene, default false (replace)."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "import_obj", "pipeline",
    "导入 Wavefront OBJ。file 不存在则报错；支持 merge。",
    "Import a Wavefront OBJ. Fails if the file is missing; merge is supported.",
    props={
        "path": s("要导入的 .obj 文件路径。", "OBJ file path to import."),
        "merge": b("是否合并进当前场景，默认否。", "Merge into the current scene, default false."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "import_gltf", "pipeline",
    "导入 glTF / GLB。glTF 是插件，若本机未安装会直接报错（err.class_missing）。",
    "Import glTF / GLB. glTF is a plugin - if this Max lacks it the call fails with "
    "err.class_missing.",
    props={
        "path": s("要导入的 .gltf/.glb 文件路径。", "glTF/GLB file path to import."),
        "merge": b("是否合并进当前场景，默认否。", "Merge into the current scene, default false."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "import_usd", "pipeline",
    "导入 USD。USD 是插件，若本机未安装会直接报错（err.class_missing）。",
    "Import USD. USD is a plugin - if this Max lacks it the call fails with "
    "err.class_missing.",
    props={
        "path": s("要导入的 USD 文件路径。", "USD file path to import."),
        "merge": b("是否合并进当前场景，默认否。", "Merge into the current scene, default false."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "import_merge_scene", "pipeline",
    "把一个文件合并进当前场景（不会清空现有对象）。按扩展名探测对应导入器，缺失则报错。",
    "Merge a file into the current scene without clearing existing objects. The importer "
    "is probed from the extension; missing importers fail with err.class_missing.",
    props={"path": s("要合并的文件路径。", "File path to merge.")},
    required=["path"],
))

TOOLS.append(tool(
    "import_get_formats", "pipeline",
    "探测本机实际可用的导入/导出插件：用 mcpClassExists 检查 FBX/OBJ/glTF/USD/Alembic/STL/3DS 等类。"
    "在依赖特定格式前先调用它，避免盲猜。",
    "Report which importer/exporter plugins this Max can actually use: mcpClassExists is "
    "checked against the FBX/OBJ/glTF/USD/Alembic/STL/3DS classes. Call it before "
    "depending on a specific format instead of guessing.",
    mutating=False,
))
