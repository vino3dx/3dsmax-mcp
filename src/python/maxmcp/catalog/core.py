"""Core catalog: bridge/system control, scene session management, file IO and
MAXScript introspection.

Category keys: ``system``, ``scene``, ``files``, ``introspection``.
"""

from __future__ import annotations

from typing import List

from .schema import Tool, arr, b, i, n, s, tool

TOOLS: List[Tool] = []


# =============================================================== system / bridge
TOOLS.append(tool(
    "bridge_status", "system",
    "查询 3ds Max 桥接的实时状态：是否在监听、端口、已连接客户端数、命令总数、"
    "Max 版本、当前场景、对象与选择数量。**在开始任何操作前调用它确认连接正常。**",
    "Report live bridge state: listening, port, connected clients, command count, "
    "Max version, current scene, object and selection counts. "
    "**Call this first to confirm the connection is healthy.**",
    mutating=False,
))

TOOLS.append(tool(
    "bridge_ping", "system",
    "轻量心跳，返回 Max 内部时间戳。用于确认桥接存活，不会改动场景。",
    "Lightweight heartbeat returning the Max internal timestamp. "
    "Use it to confirm the bridge is alive; it never touches the scene.",
    mutating=False,
))

TOOLS.append(tool(
    "bridge_stop", "system",
    "停止桥接并释放端口。停止后所有 MCP 工具都会失败，直到在 3ds Max 中重新运行 mcpBridgeStart()。",
    "Stop the bridge and release the port. Every MCP tool will fail afterwards until "
    "mcpBridgeStart() is run again inside 3ds Max.",
    mutating=False,
))

TOOLS.append(tool(
    "bridge_restart", "system",
    "重启桥接（默认沿用当前端口）。当 AI 客户端断连后无法恢复时使用。",
    "Restart the bridge (keeps the current port by default). Use it when an AI client "
    "lost the connection and cannot recover.",
    props={"port": i("要绑定的端口；省略则沿用当前端口。", "Port to bind; omit to keep the current one.")},
    mutating=False,
))

TOOLS.append(tool(
    "bridge_capabilities", "system",
    "列出 3ds Max 端实际注册的所有命令及其分类前缀。"
    "**当你不确定某个工具在当前 Max 版本上是否可用时，先调用它。**",
    "List every command actually registered on the 3ds Max side, grouped by prefix. "
    "**Call it first whenever you are unsure whether a tool exists on this Max version.**",
    mutating=False,
))

TOOLS.append(tool(
    "bridge_selftest", "system",
    "在 3ds Max 内部运行完整自检：JSON 编解码、中文往返、对象创建、撤销栈、TCP 监听。"
    "当任何工具莫名失败时先运行它，返回逐项结果，便于快速定位是环境问题还是参数问题。",
    "Run a full in-Max self test: JSON encode/decode, Chinese round trip, object creation, "
    "undo stack, TCP listener. Run it whenever a tool fails oddly - it returns per-check "
    "results so you can tell an environment problem from a bad argument.",
    props={
        "echoText": s("回显文本，用于验证中文/非 ASCII 字符的端到端编码。",
                      "Echo text used to verify end-to-end encoding of non-ASCII characters.",
                      examples=["模型测试"]),
    },
    mutating=False,
))

TOOLS.append(tool(
    "set_language", "system",
    "切换输出语言：zh（简体中文）、en（英文）或 auto（跟随 3ds Max 的界面语言）。"
    "本 MCP 服务自身的工具描述会立即切换；桥接端的提示、错误、日志信息也会同步切换。"
    "用 auto 可以让中英文用户各自看到自己语言的消息，无需手动设置。",
    "Switch the output language: zh (Simplified Chinese), en (English), or auto "
    "(follow the 3ds Max UI language). This server's tool descriptions switch immediately, "
    "and the wording of every message, error and log line produced inside 3ds Max follows. "
    "Use auto so Chinese and English users each get their own language without configuration.",
    props={"language": s("zh = 简体中文，en = English，auto = 跟随 3ds Max 界面语言。",
                         "zh = Simplified Chinese, en = English, auto = follow the 3ds Max UI language.",
                         enum=["zh", "en", "auto"])},
    required=["language"],
    mutating=False,
))

TOOLS.append(tool(
    "get_language", "system",
    "查询桥接当前使用的语言，以及它是被固定还是跟随 3ds Max 的界面语言。",
    "Return the language currently used by the bridge, and whether it is pinned "
    "or following the 3ds Max UI language.",
    mutating=False,
))

TOOLS.append(tool(
    "get_max_version", "system",
    "返回 3ds Max 年份、内部主版本号、版本字符串、构建号、界面语言、系统语言和单位制。"
    "**在调用跨版本差异较大的功能（Substance、UV 展开、导出格式）前先确认版本。**",
    "Return the 3ds Max year, internal major version, version string, build number, "
    "UI language, system language and unit setup. **Check this before using features that "
    "differ between releases (UV unwrap, import/export formats, render engines).**",
    mutating=False,
))

TOOLS.append(tool(
    "get_paths", "system",
    "返回 3ds Max 的各类默认目录：安装目录、脚本目录、导出/导入目录、渲染输出、"
    "临时目录、自动备份、材质库。用于拼出正确的默认输出路径。",
    "Return the 3ds Max default folders: install, scripts, export/import, render output, "
    "temp, autoback and material library. Use it to build sensible default output paths.",
    mutating=False,
))

TOOLS.append(tool(
    "get_system_info", "system",
    "返回当前会话的完整环境快照：渲染器、单位、帧率、动画范围、场景路径、对象统计。",
    "Return a full snapshot of the session: renderer, units, frame rate, animation range, "
    "scene path and object statistics.",
    mutating=False,
))

TOOLS.append(tool(
    "list_render_engines", "system",
    "列出本机已安装并被检测到的渲染引擎（扫描线、Arnold、V-Ray、Corona、FStorm、"
    "Redshift、ART、Quicksilver）以及当前使用的渲染器。",
    "List the render engines detected on this machine (Scanline, Arnold, V-Ray, Corona, "
    "FStorm, Redshift, ART, Quicksilver) and the one currently assigned.",
    mutating=False,
))

TOOLS.append(tool(
    "execute_maxscript", "system",
    "直接执行一段 MAXScript 代码并把结果返回。"
    "这是万能逃生舱：当没有现成工具时用它访问任意 Max 功能。"
    "设置 asOneUndo=true 可让整段代码成为一步撤销。",
    "Execute a MAXScript snippet and return its result. This is the universal escape hatch: "
    "use it to reach any Max feature that has no dedicated tool. "
    "Set asOneUndo=true to make the whole snippet a single undo step.",
    props={
        "code": s("要执行的 MAXScript 代码。", "MAXScript code to execute.",
                  examples=["select $Box001", "(objects as array).count"]),
        "asOneUndo": b("是否把整段代码包成一步撤销（默认否）。",
                       "Wrap the whole snippet in one undo step (default false)."),
        "label": s("撤销步骤名称。", "Undo step label."),
    },
    required=["code"],
    bridge="execute_maxscript",
))

TOOLS.append(tool(
    "execute_python", "system",
    "在 3ds Max 内置 Python 中执行代码（需要该版本随附 Python）。"
    "注意：3ds Max 2020 出厂只有 Python 2.7，2021 及以后是 Python 3。"
    "若脚本需要 pymxs，请确认版本支持。",
    "Execute code in the Python interpreter embedded in 3ds Max (if that release ships one). "
    "Note: 3ds Max 2020 ships Python 2.7 only, 2021 and later ship Python 3. "
    "Check the version if your script needs pymxs.",
    props={"code": s("要执行的 Python 代码。", "Python code to execute.")},
    required=["code"],
))

TOOLS.append(tool(
    "undo_last", "system",
    "撤销最近一次（或最近 N 次）操作，等价于在 Max 中按 Ctrl+Z。",
    "Undo the last operation (or the last N), equivalent to pressing Ctrl+Z in Max.",
    props={"steps": i("撤销步数，默认 1。", "Number of steps, default 1.", minimum=1, maximum=50)},
    mutating=False,
))

TOOLS.append(tool(
    "redo_last", "system",
    "重做最近一次（或最近 N 次）被撤销的操作。",
    "Redo the last undone operation (or the last N).",
    props={"steps": i("重做步数，默认 1。", "Number of steps, default 1.", minimum=1, maximum=50)},
    mutating=False,
))

TOOLS.append(tool(
    "begin_undo", "system",
    "开启一个跨多次调用的撤销事务。之后的所有改动会合并为一次撤销，直到 end_undo。"
    "适合「建一个角色并绑定」这类多步骤操作。",
    "Open an undo transaction spanning several MCP calls. Everything you do until "
    "end_undo collapses into a single undo step - ideal for multi-step tasks such as "
    "building and rigging a character.",
    props={"label": s("事务名称，会显示在 Max 的撤销菜单里。", "Transaction label shown in Max's undo menu.")},
    mutating=False,
))

TOOLS.append(tool(
    "end_undo", "system",
    "提交 begin_undo 开启的撤销事务。", "Commit the transaction opened by begin_undo.",
    props={"label": s("事务名称。", "Transaction label.")},
    mutating=False,
))

TOOLS.append(tool(
    "cancel_undo", "system",
    "取消 begin_undo 开启的事务并回滚其中的全部改动。",
    "Cancel the transaction opened by begin_undo, rolling back everything inside it.",
    mutating=False,
))

TOOLS.append(tool(
    "hold_scene", "system",
    "保存当前场景状态（相当于 Max 的 Hold）。在危险操作前使用，随时可用 fetch_scene 完整还原。",
    "Save the current scene state (Max's Hold). Use it before risky operations; "
    "fetch_scene restores it exactly.",
    mutating=False,
))

TOOLS.append(tool(
    "fetch_scene", "system",
    "把场景还原到最近一次 hold_scene 的状态。**会丢弃此后的全部改动。**",
    "Restore the scene to the last hold_scene. **Everything done since is discarded.**",
    mutating=False,
))

TOOLS.append(tool(
    "release_scene", "system",
    "释放 Hold 缓冲区，接受当前场景状态，使其不再能被 fetch 还原。",
    "Release the hold buffer and accept the current scene, so it can no longer be fetched back.",
    mutating=False,
))

TOOLS.append(tool(
    "set_units", "system",
    "设置场景单位制与显示方式。**建模前必须与目标引擎/项目约定一致**，"
    "否则导出的模型尺寸会差 100 倍。",
    "Set the scene unit system and display units. **Always align this with the target "
    "engine or project convention before modelling**, otherwise exported geometry will be "
    "off by a factor of 100.",
    props={
        "systemType": s("系统单位。", "System unit.",
                        enum=["millimeters", "centimeters", "meters", "kilometers",
                              "inches", "feet", "miles"]),
        "displayType": s("显示单位制。", "Display unit type.", enum=["metric", "us", "generic"]),
        "scale": n("系统单位比例，通常 1.0。", "System unit scale, usually 1.0.", minimum=0.0001),
    },
))

TOOLS.append(tool(
    "get_units", "system",
    "读取当前单位设置。", "Read the current unit setup.",
    mutating=False,
))

TOOLS.append(tool(
    "set_time_config", "system",
    "设置帧率与动画时间范围。做动画前必须先设定，否则关键帧会被重新采样。",
    "Set frame rate and the animation time range. Set this before animating, otherwise "
    "keyframes get resampled.",
    props={
        "frameRate": i("每秒帧数，常用 24 / 25 / 30 / 60。",
                       "Frames per second; 24 / 25 / 30 / 60 are typical.", minimum=1, maximum=480),
        "startFrame": i("起始帧。", "First frame."),
        "endFrame": i("结束帧。", "Last frame."),
        "playbackSpeed": n("回放倍速（可选）。", "Playback speed multiplier (optional)."),
    },
))

TOOLS.append(tool(
    "get_time_config", "system",
    "读取帧率、时间范围与当前帧。", "Read frame rate, time range and current frame.",
    mutating=False,
))


# ====================================================================== scene
TOOLS.append(tool(
    "scene_info", "scene",
    "返回当前场景的名字、路径、是否已修改、对象数量、选择、活动层与渲染器。",
    "Return the current scene name, path, modified flag, object count, selection, "
    "active layer and renderer.",
    mutating=False,
))

TOOLS.append(tool(
    "scene_statistics", "scene",
    "统计场景构成：按类型（几何体/图形/灯光/相机/辅助体）分组计数、"
    "总顶点数、面数、材质数、贴图数。**用于评估导出与渲染的规模。**",
    "Summarise the scene composition: counts grouped by type (geometry, shapes, lights, "
    "cameras, helpers), total vertices, faces, materials and texture maps. "
    "**Use it to gauge the scale of a render or export.**",
    props={"includeHidden": b("是否把隐藏对象也计入，默认是。",
                              "Include hidden objects in the counts, default true.")},
    mutating=False,
))

TOOLS.append(tool(
    "scene_new", "scene",
    "新建空场景。可选保留当前场景的某些设置。**未保存的改动会丢失。**",
    "Create a new empty scene. Some session settings can be carried over. "
    "**Unsaved changes are lost.**",
    props={"keepScene": b("是否保留当前场景的设置（单位、渲染参数等），默认否。",
                          "Keep current session settings such as units and render setup, default false.")},
))

TOOLS.append(tool(
    "scene_reset", "scene",
    "把 Max 重置到出厂状态。**会清空一切，包括单位、渲染器、自定义设置。**",
    "Reset 3ds Max to factory state. **This wipes everything including units, renderer "
    "and custom settings.**",
))

TOOLS.append(tool(
    "scene_open", "scene",
    "打开一个 .max 场景文件（默认不弹出保存提示）。",
    "Open a .max scene file (no save prompt by default).",
    props={
        "path": s("场景文件的绝对路径。", "Absolute path of the .max file."),
        "quiet": b("是否静默打开（不询问是否保存当前场景），默认是。",
                   "Open quietly without asking to save the current scene, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "scene_save", "scene",
    "保存当前场景。若从未保存过则等同于另存为。",
    "Save the current scene. If it has never been saved this behaves like save-as.",
    mutating=False,
))

TOOLS.append(tool(
    "scene_save_as", "scene",
    "把当前场景另存到指定路径（自动创建缺失的目录）。",
    "Save the current scene to a given path, creating missing folders.",
    props={
        "path": s("目标 .max 文件路径。", "Destination .max path."),
        "keepPath": b("是否把新路径设为当前场景路径，默认是。",
                      "Adopt the new path as the current scene path, default true."),
    },
    required=["path"],
))

TOOLS.append(tool(
    "scene_merge", "scene",
    "把另一个 .max 文件里的内容合并进当前场景（不会清空现有对象）。",
    "Merge the contents of another .max file into the current scene without clearing it.",
    props={
        "path": s("要合并的 .max 文件路径。", "Path of the .max file to merge."),
        "objects": arr("只合并指定名称的对象；省略则合并全部。",
                       "Merge only these object names; omit to merge everything."),
        "quiet": b("是否静默合并，默认是。", "Merge quietly, default true."),
    },
    required=["path"],
))


# --------------------------------------------------------------------- layers
TOOLS.append(tool(
    "list_layers", "scene",
    "列出场景所有层及其子对象数量、隐藏/冻结状态。**用层来组织大型场景是最可靠的做法。**",
    "List every scene layer with its child count and hidden/frozen state. "
    "**Layers are the most reliable way to organise a large scene.**",
    mutating=False,
))

TOOLS.append(tool(
    "create_layer", "scene",
    "新建一个层，可选设置颜色与初始隐藏状态。",
    "Create a layer, optionally with a colour and initial hidden state.",
    props={
        "name": s("层名称。", "Layer name."),
        "color": arr("RGB 颜色 [0-255]，可选。", "RGB colour [0-255], optional.", items="integer"),
        "hidden": b("是否隐藏该层，默认否。", "Hide the layer, default false."),
    },
    required=["name"],
))

TOOLS.append(tool(
    "delete_layer", "scene",
    "删除一个层。可选连同层内对象一起删除。",
    "Delete a layer, optionally deleting the objects inside it too.",
    props={
        "name": s("层名称。", "Layer name."),
        "deleteObjects": b("是否同时删除层内对象，默认否（对象会被移到默认层）。",
                           "Also delete the objects it contains, default false "
                           "(otherwise they move to the default layer)."),
    },
    required=["name"],
))

TOOLS.append(tool(
    "set_layer_properties", "scene",
    "修改层的属性：隐藏、冻结、线框色、渲染可见性。",
    "Change layer properties: hidden, frozen, wire colour and render visibility.",
    props={
        "name": s("层名称。", "Layer name."),
        "hidden": b("隐藏。", "Hidden."),
        "frozen": b("冻结（不可选中）。", "Frozen (unselectable)."),
        "renderable": b("是否参与渲染。", "Participates in rendering."),
        "color": arr("线框颜色 [0-255]。", "Wire colour [0-255].", items="integer"),
    },
    required=["name"],
))

TOOLS.append(tool(
    "assign_to_layer", "scene",
    "把指定对象移动到目标层。层不存在时会自动创建。",
    "Move objects into a target layer, creating the layer if needed.",
    props={
        "objects": arr("对象名称列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection."),
        "layer": s("目标层名称。", "Target layer name."),
    },
    required=["layer"],
))

TOOLS.append(tool(
    "move_objects_to_new_layer", "scene",
    "一步完成：新建层并把指定对象放进去。",
    "One step: create a layer and move the given objects into it.",
    props={
        "layer": s("新层名称。", "New layer name."),
        "objects": arr("对象名称列表；省略则使用当前选择。",
                       "Object names; omit to use the current selection."),
    },
    required=["layer"],
))


# ------------------------------------------------------------------- assets
TOOLS.append(tool(
    "get_scene_assets", "scene",
    "列出场景引用的所有外部资源（贴图、代理、点缓存、XRef）及其解析状态。"
    "**在打包、迁移或渲染前检查，可避免丢贴图。**",
    "List every external asset the scene references (bitmaps, proxies, point caches, XRefs) "
    "with its resolved status. **Check this before packaging, moving or rendering a project "
    "to avoid missing textures.**",
    mutating=False,
))

TOOLS.append(tool(
    "find_missing_assets", "scene",
    "只列出丢失（无法解析路径）的资源，并给出每个文件的引用次数。",
    "List only the assets whose paths cannot be resolved, with a reference count per file.",
    mutating=False,
))

TOOLS.append(tool(
    "relink_assets", "scene",
    "批量重新链接丢失的贴图/资源：在指定目录（可递归）中按文件名查找并替换路径。"
    "等价于 Max 的「资源追踪」批量重链接，是修复丢贴图场景最常用的操作。",
    "Batch relink missing bitmaps/assets: search the given folder (recursively) for files "
    "with matching names and repoint the scene. Equivalent to Max's Asset Tracking batch "
    "relink, and the standard fix for scenes with missing textures.",
    props={
        "searchPaths": arr("要搜索的根目录（可多个），会递归查找同名文件。",
                           "Root folders to search (multiple allowed); searched recursively "
                           "for files with matching names."),
        "onlyMissing": b("只处理已丢失的资源，默认是。", "Only relink currently missing assets, default true."),
        "dryRun": b("只报告将要做的替换而不真正执行，默认否。**建议先跑一次 true 确认结果。**",
                    "Report the replacements without applying them, default false. "
                    "**Run once with true first to confirm the mapping.**"),
    },
    required=["searchPaths"],
))


# ======================================================================= files
TOOLS.append(tool(
    "read_text_file", "files",
    "读取一个文本文件（脚本、配置、日志）。用于检查导出的 .ini 或 MAXScript 片段。",
    "Read a text file (script, config, log). Handy for inspecting exported .ini files or "
    "MAXScript snippets.",
    props={
        "path": s("文件绝对路径。", "Absolute file path."),
        "maxChars": i("最多读取的字符数，默认 200000。", "Maximum characters to read, default 200000."),
    },
    required=["path"],
    mutating=False,
))

TOOLS.append(tool(
    "write_text_file", "files",
    "写入一个文本文件（自动创建父目录，可选 UTF-8 编码）。"
    "用于生成批处理脚本、导出清单、自定义配置。",
    "Write a text file, creating parent folders automatically (optional UTF-8). "
    "Use it to emit batch scripts, export manifests or custom configs.",
    props={
        "path": s("文件绝对路径。", "Absolute file path."),
        "content": s("要写入的文本内容。", "Text content to write."),
        "append": b("是否追加而非覆盖，默认否。", "Append instead of overwrite, default false."),
        "encoding": s("编码，默认 utf-8；可选 ansi（跟随系统代码页）。",
                      "Encoding, default utf-8; use ansi for the system code page.",
                      enum=["utf-8", "ansi"], default="utf-8"),
    },
    required=["path", "content"],
))

TOOLS.append(tool(
    "list_directory", "files",
    "列出目录内容，可按扩展名过滤，支持递归。用于批量处理贴图或代理文件。",
    "List a directory, optionally filtered by extension and recursive. "
    "Use it to batch process textures or proxy files.",
    props={
        "path": s("目录绝对路径。", "Absolute directory path."),
        "pattern": s("通配符，例如 *.jpg 或 *.max。", "Wildcard such as *.jpg or *.max."),
        "recursive": b("是否递归子目录，默认否。", "Recurse into subfolders, default false."),
        "limit": i("最多返回条数，默认 500。", "Maximum entries to return, default 500."),
    },
    required=["path"],
    mutating=False,
))

TOOLS.append(tool(
    "file_exists", "files",
    "判断文件是否存在。", "Check whether a file exists.",
    props={"path": s("文件绝对路径。", "Absolute file path.")},
    required=["path"],
    mutating=False,
))

TOOLS.append(tool(
    "make_directory", "files",
    "创建目录（含所有上级目录）。", "Create a directory including all parents.",
    props={"path": s("目录绝对路径。", "Absolute directory path.")},
    required=["path"],
))

TOOLS.append(tool(
    "copy_file", "files",
    "复制文件（可选覆盖）。", "Copy a file (optionally overwriting).",
    props={
        "source": s("源文件。", "Source file."),
        "destination": s("目标文件或目录。", "Destination file or directory."),
        "overwrite": b("是否覆盖已存在的目标，默认是。", "Overwrite an existing destination, default true."),
    },
    required=["source", "destination"],
))

TOOLS.append(tool(
    "delete_file", "files",
    "删除文件。**不可恢复，请谨慎调用。**",
    "Delete a file. **Not recoverable, use with care.**",
    props={"path": s("要删除的文件。", "File to delete.")},
    required=["path"],
))

TOOLS.append(tool(
    "get_file_info", "files",
    "返回文件大小与修改时间。", "Return file size and modification time.",
    props={"path": s("文件绝对路径。", "Absolute file path.")},
    required=["path"],
    mutating=False,
))


# =============================================================== introspection
TOOLS.append(tool(
    "list_max_classes", "system",
    "按关键字搜索 3ds Max 的类注册表，返回匹配的类名。"
    "**这是发现「本机到底装了什么插件」的核心手段**：例如搜索 Vray、FStorm、Corona、"
    "Substance、RailClone 就能得知可用材质与插件。",
    "Search the 3ds Max class registry by keyword and return matching class names. "
    "**This is the primary way to discover what plugins a machine actually has**: search "
    "for Vray, FStorm, Corona, Substance or RailClone to find available materials and tools.",
    props={
        "keyword": s("关键字，不区分大小写，例如 Vray。", "Keyword, case-insensitive, e.g. Vray."),
        "limit": i("最多返回条数，默认 100。", "Maximum results, default 100."),
    },
    required=["keyword"],
    mutating=False,
))

TOOLS.append(tool(
    "get_class_properties", "system",
    "列出某个类的所有可读写属性及其当前值。"
    "**在设置不熟悉的参数前先用它确认属性名，可避免大量试错。**",
    "List every readable/writable property of a class with its current value. "
    "**Check this before setting unfamiliar parameters - it removes most trial and error.**",
    props={
        "className": s("类名，例如 Spherical_Light 或 VRayMtl。", "Class name, e.g. Spherical_Light or VRayMtl."),
        "limit": i("最多返回条数，默认 200。", "Maximum results, default 200."),
    },
    required=["className"],
    mutating=False,
))

TOOLS.append(tool(
    "get_class_methods", "system",
    "列出某个类可用的方法/函数及其参数签名。",
    "List the methods/functions available on a class with their signatures.",
    props={"className": s("类名。", "Class name.")},
    required=["className"],
    mutating=False,
))

TOOLS.append(tool(
    "does_class_exist", "system",
    "判断某个类在本机 3ds Max 中是否存在，用于在调用前探测插件可用性。",
    "Check whether a class exists in this 3ds Max installation, so plugin availability can "
    "be probed before use.",
    props={"className": s("类名。", "Class name.")},
    required=["className"],
    mutating=False,
))

TOOLS.append(tool(
    "list_scene_classes", "system",
    "统计当前场景中实际出现的所有类及其数量。",
    "Count every class actually present in the current scene.",
    mutating=False,
))

TOOLS.append(tool(
    "get_property_value", "system",
    "读取任意对象的任意属性值，支持点号路径（例如 material.diffuse）。"
    "配合 get_class_properties 使用可完成绝大多数参数读取。",
    "Read any property of any object, supporting dotted paths such as material.diffuse. "
    "Together with get_class_properties this covers almost every parameter read.",
    props={
        "object": s("对象名称。", "Object name."),
        "property": s("属性名或点号路径。", "Property name or dotted path."),
    },
    required=["object", "property"],
    mutating=False,
))

TOOLS.append(tool(
    "set_property_value", "system",
    "设置任意对象的任意属性值，支持点号路径。值会按目标属性类型自动转换。"
    "**这是给未提供专用工具的参数赋值时的通用手段。**",
    "Set any property of any object, supporting dotted paths. The value is coerced to the "
    "target property's type. **This is the generic way to touch parameters that have no "
    "dedicated tool.**",
    props={
        "object": s("对象名称。", "Object name."),
        "property": s("属性名或点号路径。", "Property name or dotted path."),
        "value": s("新值（字符串形式，自动转换类型）。",
                   "New value as a string; the type is coerced automatically."),
    },
    required=["object", "property", "value"],
))
