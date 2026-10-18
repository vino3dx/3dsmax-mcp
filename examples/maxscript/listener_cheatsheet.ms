-- ============================================================================
--  3ds Max MCP bridge - MAXScript Listener cheatsheet
-- ============================================================================
--  Paste lines into the MAXScript Listener (F11) to inspect or drive the
--  bridge by hand. Useful when the AI client says it cannot reach Max, or when
--  you want to confirm the encoding codec survived an edit.
--
--  Nothing here is required for normal use. The bridge starts by itself.
-- ============================================================================

-- ---------------------------------------------------------------- is it alive?
mcpRunning                        -- true while the socket is listening
mcpPort                           -- the port the bridge bound, e.g. 8765
mcpHost                           -- "127.0.0.1"
mcpLang                           -- "zh" or "en"
mcpGetLanguage()                  -- same thing, as a function
mcpRegistry.count                 -- how many commands are registered (353)

-- detailed snapshot: running / host / port / clients / timerActive /
-- language / handlerCount / maxYear
mcpNetStatus()

-- which modules actually loaded (a failed module prints a warning at startup)
mcpBridgeModules
mcpBridgeRoot                     -- where the bridge files were loaded from


-- -------------------------------------------------------------- start / stop
mcpBridgeLoad()                   -- (re)load every module, no listening yet
mcpBridgeStart()                  -- listen on the configured port
mcpBridgeStart port:9000          -- ...or on a specific one
mcpBridgeStop()                   -- close the socket, keep modules loaded

-- If the autoloader did not fire (Max was running during the install), do this
-- and the bridge comes up in place:
-- fileIn @"C:\Users\<you>\AppData\Local\Autodesk\3dsMax\2020 - 64bit\ENU\scripts\3dsmax-mcp\mcp_bridge.ms"


-- ------------------------------------------------------------------- version
mcpMaxYear()                      -- 2020
mcpMaxMajor()                     -- 22
mcpVersionInfo()                  -- full record, as the AI sees it


-- --------------------------------------------------------------- self-test
-- 12 live checks: JSON round trip, Chinese round trip, object creation,
-- theHold behaviour, TCP listener, registry consistency, ...
mcpSelfTest()

-- pass a string to prove the codec: it must echo back byte for byte
mcpSelfTest echoText:"角色_头部模型"

-- Read the result programmatically - each entry is
--   #(check, name, ok, detail)
for c in mcpSelfTestLines do format "% : %\n" c[2] c[3]


-- ------------------------------------------------------------------ language
-- The bridge can follow this Max installation's UI language automatically.
-- The installer writes language=auto into 3dsmax-mcp.ini, which is the default.
mcpGetLanguage()                  -- what the bridge is speaking: "zh" or "en"
mcpIsLanguagePinned()             -- false = following Max, true = explicitly set

-- What Max itself is running in, and what that maps to for us.
mcpMaxLanguageCode()              -- "ENU", "CHS", "CHT", "JPN", ... or ""
mcpDetectLanguage()               -- resolves that to "zh" or "en"

-- Switch modes by hand:
mcpSetLanguage "en"               -- pin English (pins: stops following Max)
mcpSetLanguage "zh"               -- pin Chinese
mcpSetLanguageAuto()              -- hand control back to Max's own language
-- After either of the first two, mcpIsLanguagePinned() is true; after
-- mcpSetLanguageAuto() it is false again.

-- Force a specific answer without touching Max, useful when testing:
mcpLanguageLabel "CHT"            -- "Chinese"
mcpLanguageLabel ""               -- "English"


-- ------------------------------------------------- talk to the bridge directly
-- No JSON, no socket - dispatch a command and get the MAXScript value back.
mcpDispatch "scene_info" #()
mcpDispatch "create_sphere" (mcpObj #(#("name", "Test"), #("radius", 10.0)))
mcpDispatch "list_objects" (mcpObj #(#("kind", "geometry")))
mcpDispatch "get_object_info" (mcpObj #(#("name", "Sphere001")))

-- A failing command throws, so wrap it when experimenting:
try ( mcpDispatch "does_not_exist" #() )
catch ( format "as expected: %\n" (getCurrentException()) )


-- --------------------------------------------------------------- JSON engine
-- These are the pieces the wire protocol is built from. Handy for debugging.
mcpObj #(#("a", 1), #("b", "two"))            -- build an object
mcpJsonStringify (mcpObj #(#("名称", "球体")))  -- -> {"name":"..."}
mcpJsonParse "{\"a\":1,\"b\":[1,2,3]}"         -- -> parsed value

mcpIsObj someValue                            -- was this an object?
mcpGet someValue "key"                        -- object -> value (undefined if absent)
mcpHas someValue "key"                        -- does the object carry that key?

mcpStr  params "name"                         -- typed readers; default when absent
mcpNum  params "radius" default:10.0
mcpInt  params "segments" default:12
mcpBool params "smooth" default:true
mcpArr  params "objects"


-- ----------------------------------------------------- encoding (important!)
-- Chinese travels as ANSI code-page bytes escaped into \u00XX. If text ever
-- comes back as "?" or mojibake, test the codec in isolation here.
mcpAnsiBytesToString (mcpStringToAnsiBytes "角色_模型")
-- must print exactly: 角色_模型

mcpWireToAnsi "\u00c4\u00e3"                  -- wire escapes -> real string


-- ------------------------------------------------------------ scene plumbing
mcpResolveNode "Sphere001"                    -- name -> node (throws if absent)
mcpResolveNode $                              -- a node passes straight through
mcpResolveNodes #("A", "B") fallbackToSelection:true
mcpResolveNodes #() fallbackToSelection:true silent:true

mcpNodeInfo $                                 -- one node as a bridge-shaped object
mcpNodesInfo #($Box001, $Sphere001)           -- many
mcpSelectionInfo()                            -- the current selection
mcpSuperclass $                               -- "geometry", "light", ...
mcpIsPoly $                                   -- predicates
mcpIsMesh $
mcpLayerNodes "MyLayer"                       -- every node on a layer
mcpEnsureLayer "NewLayer"                     -- get-or-create


-- ---------------------------------------------------------- undo, by hand
-- The dispatcher wraps undoable commands automatically - you only need these
-- when scripting a sequence that should undo as ONE step.
mcpHoldBegin "Build the prop"
-- ... create/modify things ...
mcpHoldAccept()                               -- commit as a single undo
-- mcpHoldCancel()                            -- or throw it all away

theHold.Undo()                                -- same as the AI's undo_last


-- ------------------------------------------------------------ script escape
-- Anything without a dedicated tool still has a way through.
mcpDispatch "execute_maxscript" (mcpObj #(#("code", "$.count")))


-- ------------------------------------------------------------------ messages
-- mcpMessages is a table of #(key, #(中文, English)). Look a key up when a
-- bridge error is cryptic, or dump the whole table:
mcpMsg "err.unknown_method" a1:"bogus"
for e in mcpMessages do format "% = % | %\n" e[1] e[2][1] e[2][2]
