# Bridge conventions

Everything in this document is a hard contract. The Python side and the
MAXScript side are written independently, so the only thing keeping them
consistent is a shared set of names and rules. Read this before adding a tool.

## 1. Two halves

```
AI client  ──stdio/JSON-RPC──▶  src/maxmcp/**          (external Python 3, stdlib only)
                                   │
                                   │ TCP, newline delimited JSON, ASCII only
                                   ▼
                                max/mcp_net.ms          (inside 3ds Max, main thread)
                                   │
                                   ▼
                                max/mcp_*.ms handlers   (MAXScript, touches the scene)
```

* **Python half** declares the public tool: name, bilingual description, JSON
  Schema, and which bridge command to call.
* **MAXScript half** implements the command and returns JSON-safe values.

A tool called `create_box` in the catalog **must** be registered as
`create_box` in MAXScript. When the two need different names, set
`bridge="..."` on the Python tool.

## 2. Naming

* Tool / command names: `snake_case`, no dots, no dashes. MCP forbids dots.
* Prefix with the area so `bridge_capabilities` grouping works:
  `bridge_`, `scene_`, `get_`/`set_`, `create_`, `delete_`, `poly_`, `mod_`,
  `mat_`, `light_`, `cam_`, `anim_`, `rig_`, `render_`, `bake_`, `export_`,
  `import_`, `uvw_`.
* MAXScript module files are `max/mcp_<area>.ms`. Each ends with a
  `mcpRegister<Area>()` function that it calls immediately.

## 3. Python side

Add a `Tool` to the `TOOLS` list of the right module in `src/maxmcp/catalog/`:

```python
from .schema import Tool, arr, b, i, n, num3, s, tool

TOOLS.append(tool(
    "create_box", "objects",
    "创建一个长方体。中文描述要写清楚用途和坑。",
    "Create a box. The English description should explain intent and pitfalls.",
    props={
        "length": n("长度。", "Length.", default=10.0),
        "name":   s("对象名。", "Object name."),
        "objects": arr("名称列表；省略则使用当前选择。",
                       "Names; omit to use the current selection."),
    },
    required=["length"],
    mutating=True,          # False for anything read-only
    bridge="create_box",    # optional, only when different from the tool name
    preset={"primitive": "box"},   # optional, merged under the caller's args
))
```

Rules:

* **Both** `description_zh` and `description_en` are mandatory and must be
  substantive (say what it does, when to use it, what it will destroy). The
  self test fails a tool whose description is empty.
* Every property needs a type helper (`s`, `n`, `i`, `b`, `arr`, `num3`).
* `arr(..., items="number")` when the array is numeric.
* `required=[...]` lists parameter names, not schema fragments.
* `mutating=False` for read-only tools - the client uses it to decide whether to
  ask the user for confirmation. Anything that changes the scene, files or
  settings is `mutating=True` (the default).
* Never name a parameter `undo` or `undo_label`; the transport reserves those.

## 4. MAXScript side

```maxscript
fn mcpH_create_box params =
(
    local len = mcpNum params "length" default:10.0
    local nm  = mcpStr params "name" default:""

    local obj = Box length:len width:20 height:10
    if nm != "" do obj.name = nm
    mcpRedraw()

    local p = #()
    mcpPair p "object" (mcpNodeInfo obj)
    mcpPair p "message" (mcpMsg "msg.created" a1:obj.name)
    mcpObj p
)

mcpRegister "create_box" mcpH_create_box label:"Create Box"
```

### 4.1 Only these constructs are allowed

The bridge must load on 3ds Max 2020 and every later release, and it is written
blind (no struct, no .NET collection, no closure edge cases). Use:

| Need | Use |
| --- | --- |
| JSON object | `mcpObj #(#("k", v), ...)` |
| Read a param | `mcpStr` / `mcpNum` / `mcpInt` / `mcpBool` / `mcpArr` / `mcpGet` |
| Required param | `mcpReqStr` / `mcpReqNum` / `mcpReqInt` |
| Localised message | `mcpMsg "key" a1:value` |
| Raise a localised error | `mcpFail "err.node_not_found" a1:name` |
| Resolve an object | `mcpResolveNode spec` / `mcpResolveNodes list` |
| Object summary | `mcpNodeInfo node` |
| Force a redraw | `mcpRedraw()` |
| Try something | `try ( ... ) catch ( ... )` |

**Forbidden** - these are the constructs that are not verifiable without a live
Max and are therefore not used anywhere in this codebase:

* `struct` definitions of any kind.
* Closures / lambdas (`fn = (...)`, `fn x = (...)`) used as thunks.
* Line continuation with a trailing backslash. Keep expressions on one line or
  wrap them in parentheses.
* `global X` immediately followed by `struct X`.
* `.NET` generic collections (`Dictionary<>`), preferring plain arrays.

### 4.2 Parameter helpers

```maxscript
mcpStr  params "key" default:""      -- String
mcpNum  params "key" default:0.0     -- Float
mcpInt  params "key" default:0       -- Integer
mcpBool params "key" default:false   -- Boolean
mcpArr  params "key"                 -- Array (never undefined)
mcpGet  params "key"                 -- raw value or undefined
mcpHas  params "key"                 -- Boolean
```

To distinguish "not supplied" from "supplied as zero", test
`if (mcpGet params "key") != undefined do ...`.

### 4.3 Returning values

Return any of: `mcpObj #(...)`, `Array`, `String`, `Number`, `Boolean`,
`Point3`, `Color`, `undefined`. Node values are **not** serialisable - always
convert with `mcpNodeInfo`. Arrays larger than a few hundred entries should be
paginated with `limit` / `offset` parameters.

Guard numerically with `try/catch` when reading MAXScript properties that may
not exist on every release, for example:

```maxscript
local v = 0
try ( v = someNode.someProperty ) catch ( v = 0 )
```

### 4.4 Selection defaults

Any tool that operates on objects takes an optional `objects` array. When it is
missing the handler falls back to the current selection:

```maxscript
local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
```

If the selection is empty, `mcpResolveNodes` raises the localised
`err.no_selection` for you.

### 4.5 Static methods on .NET types

```maxscript
local ip = (dotNetClass "System.Net.IPAddress").Parse "127.0.0.1"
```

## 5. Localisation

* Tool descriptions: `description_zh` + `description_en` in the catalog.
  `i18n.render_description` picks the active one and appends the other.
* Parameter descriptions: `s("中文", "English")` renders as `中文 | English`.
* Messages produced inside Max: add a key to `mcpMessages` in `mcp_core.ms`
  with a `#(chinese, english)` pair, then call `mcpMsg "key" a1:value`.
  `%` is the placeholder.

Never hard-code a user visible string in a handler.

## 6. Worked example, both halves

Catalog:

```python
TOOLS.append(tool(
    "mod_add", "modeling",
    "给对象添加一个修改器。修改器名用 3ds Max 类名，例如 Bend、TurboSmooth、Shell。"
    "用 list_modifiers 查看已有的，用 get_class_properties 查看参数名。",
    "Add a modifier to an object. Use the 3ds Max class name, e.g. Bend, TurboSmooth, "
    "Shell. Inspect existing ones with list_modifiers and parameter names with "
    "get_class_properties.",
    props={
        "objects": arr("对象名列表；省略则用当前选择。", "Object names; omit for the selection."),
        "modifier": s("修改器类名。", "Modifier class name.", examples=["Bend", "TurboSmooth"]),
        "name": s("给修改器起的名字。", "Name to give the modifier."),
    },
    required=["modifier"],
))
```

MAXScript:

```maxscript
fn mcpH_mod_add params =
(
    local clsName = mcpReqStr params "modifier"
    local nodes = mcpResolveNodes (mcpArr params "objects") fallbackToSelection:true
    local customName = mcpStr params "name" default:""

    mcpEnsureClass clsName

    local applied = #()
    local failures = #()
    for n in nodes do
    (
        local ok = true
        try
        (
            local modClass = execute clsName
            local m = n.modifiers.count
            addModifier n (modClass())
            if customName != "" and n.modifiers.count > m do n.modifiers[n.modifiers.count].name = customName
            append applied n.name
        )
        catch ( ok = false; append failures (n.name + ": " + (getCurrentException())) )
    )

    local p = #()
    mcpPair p "applied" applied
    mcpPair p "failures" failures
    mcpPair p "message" (mcpMsg "msg.ok")
    mcpObj p
)

mcpRegister "mod_add" mcpH_mod_add label:"Add Modifier"
```

## 7. Checklist before you finish

1. Every catalog tool has a matching `mcpRegister "<name>"`.
2. `PYTHONPATH=src/python python -m maxmcp --selftest-python` prints *all checks passed*.
3. `PYTHONPATH=src/python python -m maxmcp --list-tools` shows the new names.
4. `python test/catalog_contract_test.py` (sixth static gate) reports *catalog
   contract holds*: schema legality, preset keys, required-parameter rejection
   and type coercion for every tool, via MockBridge -- no Max needed.  New
   naming or mutating-flag exceptions go into the whitelists in that file with
   a written reason.
5. `python test/offline_lint_helper.py` (seventh static gate) reports *offline
   lint: clean*: Python syntax / encoding / undefined names / hardcoded paths,
   MAXScript encoding and bracket balance, and the catalog tool definitions
   (bilingual descriptions, parameter types, default and enum value types).
   `scripts/verify.py` runs it in-process and prints the per-module
   distribution table.  Rules and rationale: `docs/OFFLINE_LINT_GUIDE.md`.
6. No forbidden constructs, no trailing backslash continuations.
7. Every user visible string goes through `mcpMsg` or the bilingual catalog.
