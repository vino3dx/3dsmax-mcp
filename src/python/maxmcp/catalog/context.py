"""Scene-context tools: one call for "what is in the scene right now".

These wrap the in-Max context store (`src/ms/mcp_context.ms`), which keeps a
revision counter and per-domain caches.  The point of the group is to replace
"call six tools and stitch the answers together" with one call that returns a
consistent snapshot plus the revision it was taken at.

Design notes that matter to a caller:

* every section carries `revision`, `builtAt`, `source`, `valid` and, on
  failure, `error` -- a section is never a fabricated zero;
* `since` is the incremental switch: sections whose revision did not move are
  listed under `unchanged` and are not sent at all;
* `client_*` drives the in-Max panel ("Vino 3dsMax MCP"), so an agent can open
  it when a user needs to see the same numbers.
"""

from __future__ import annotations

from .schema import arr, i, s, tool

TOOLS = [
    tool(
        "context_get", "context",
        """
        读取场景上下文快照。一次调用返回多个“域”的摘要（scene / selection / objects /
        materials / assets / animation / rigging / render / project），每个域带 revision、
        采集时间、来源和有效性；失败时带 error，不会用 0 冒充真实值。

        用 since=<上次的 revision> 只取变化的域（未变化的列在 unchanged 里，不返回内容）。
        detail:"full" 会让 selection 返回更完整的对象记录（包围盒、修改器列表等）。
        """,
        """
        Read a scene-context snapshot. One call returns several domains (scene / selection /
        objects / materials / assets / animation / rigging / render / project); every domain
        carries its revision, build time, source and validity, and reports `error` instead of
        inventing zeros.

        Pass since=<revision from the previous call> to receive only the domains that changed;
        unchanged ones are listed and not sent. detail:"full" widens the selection records
        (bounding box, modifier list, ...).
        """,
        props={
            "sections": arr(
                "要读取的域；省略=全部。可选：scene, selection, objects, materials, assets, animation, rigging, render, project。",
                "Domains to read; omit for all: scene, selection, objects, materials, assets, animation, rigging, render, project.",
            ),
            "since": i("只返回 revision 大于该值的域（增量模式）。", "Only return domains newer than this revision (incremental).", default=0),
            "detail": s("brief=摘要（默认）；full=更完整的记录。", "brief=summary (default); full=wider records.", default="brief", enum=["brief", "full"]),
        },
        mutating=False,
    ),
    tool(
        "context_refresh", "context",
        """
        强制重建上下文缓存（不做增量）。用于“我怀疑数据和 Max 不一致”时：会立即重新采集
        指定域并返回新的全局 revision。开销比 context_get 大，不要在高频循环里调用。
        """,
        """
        Force a rebuild of the context caches (no incremental shortcut). Use it when the data
        is suspected to be out of sync with Max: the given domains are re-collected and the
        new global revision is returned. Costlier than context_get; not for tight loops.
        """,
        props={
            "sections": arr("要重建的域；省略=全部。", "Domains to rebuild; omit for all."),
        },
        mutating=False,
    ),
    tool(
        "context_stats", "context",
        """
        查看上下文系统自身的状态：全局 revision、各域 revision、哪些域已过期、缓存条目数、
        构建次数、最慢构建耗时、最近错误，以及事件回调的可用性（本机实测结果，不是按版本猜的）。
        """,
        """
        Inspect the context system itself: global revision, per-domain revisions, which domains
        are stale, cache entries, build count, slowest build, last error, and which event
        callbacks this build actually offers (measured, not assumed from a version number).
        """,
        mutating=False,
    ),
    tool(
        "context_events", "context",
        """
        读取最近的变更事件（选择变化、重命名、增删对象、存盘、打开、渲染开始/结束、工具写入等），
        按时间倒序。用于回答“刚刚发生了什么”以及在场景异常时定位触发点。
        """,
        """
        Read the recent change ledger (selection, rename, node add/delete, save, open, render
        start/end, tool writes, ...), newest first. Answers "what just happened" and helps
        localise what triggered an unexpected scene state.
        """,
        props={
            "limit": i("返回条数上限（默认 50）。", "Maximum rows (default 50).", default=50, minimum=1, maximum=250),
        },
        mutating=False,
    ),
    tool(
        "client_ui", "context",
        """
        控制 3ds Max 内部的 “Vino 3dsMax MCP” 面板：open 打开、close 关闭、refresh 刷新当前页。
        面板展示的是与 MCP 工具相同的真实数据（连接、场景、选择、资源、监听、维护、日志）。
        """,
        """
        Control the in-Max "Vino 3dsMax MCP" panel: open, close or refresh. The panel shows the
        same live data the MCP tools read (connection, scene, selection, assets, monitor,
        maintenance, log).
        """,
        props={
            "action": s("open / close / refresh。", "open / close / refresh.", default="open", enum=["open", "close", "refresh"]),
        },
        mutating=False,
    ),
    tool(
        "client_status", "context",
        """
        查询内置客户端状态：面板是否已打开、事件层是否在运行、当前 revision、日志路径、
        桥接模块目录。用于确认“监听真的在跑”而不是假定它在跑。
        """,
        """
        Report the built-in client state: is the panel open, is the event layer running, current
        revision, log path and bridge directory. Confirms the monitor is actually alive instead
        of assuming it.
        """,
        mutating=False,
    ),
]
