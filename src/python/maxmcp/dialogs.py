"""Dismiss blocking modal dialogs owned by the running 3ds Max process.

3ds Max runs the MAXScript bridge on its main UI thread.  Any modal dialog --
a MAXScript error box, an FBX import prompt, a render-error report -- therefore
blocks that thread and the bridge stops answering until a human clicks it.
A single bad tool call can wedge the whole session, so the client side needs a
way to clear those boxes.

Only *known* dialog titles are touched.  Real crash dialogs (``Application
Error``) are deliberately left alone: the process is already gone, and closing
the box silently would hide the crash from the caller.

Windows only; on other platforms every entry point is a no-op.
"""

from __future__ import annotations

import ctypes
import subprocess
import sys
from typing import List, Optional, Sequence, Tuple

_IS_WINDOWS = sys.platform == "win32"

# Titles that only ever appear when something went wrong and nobody is going to
# click them.  Matched case-insensitively as substrings.
BLOCKING_TITLES: Tuple[str, ...] = (
    "maxscript macroscript error exception",
    "maxscript error",
    "maximum nested error dialog depth reached",
    "script error",
    "fbx import",
    "fbx export",
    "render message",
    "missing external files",
    "obsolete file",
    "file load:",
    "file save as",
    "unresolved external references",
    "mental ray",
    # A managed component blew up. 3ds Max shows a WinForms "Continue / Quit"
    # box that blocks the UI thread; without this the bridge looks dead.
    "microsoft .net framework",
)

# Buttons worth clicking when WM_CLOSE is ignored.  Ordered by preference: the
# "go away" option first so we never accidentally confirm a save or an overwrite.
BUTTON_TEXTS: Tuple[str, ...] = (
    "ok",
    "确定",
    "close",
    "关闭",
    "cancel",
    "取消",
    "no",
    "否",
    "continue",
    "继续",
    "don't save",
    "不保存",
)

_WM_CLOSE = 0x0010
_BM_CLICK = 0x00F5


def _user32():
    return ctypes.WinDLL("user32", use_last_error=True)


def max_pid() -> Optional[int]:
    """PID of the running 3ds Max, or None."""
    if not _IS_WINDOWS:
        return None
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq 3dsmax.exe", "/FO", "CSV", "/NH"],
            capture_output=True,
            timeout=10,
        ).stdout.decode("mbcs", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if "3dsmax" in line.lower():
            parts = line.split('","')
            if len(parts) > 1:
                try:
                    return int(parts[1].strip('"'))
                except ValueError:
                    return None
    return None


def _text(u, hwnd) -> str:
    n = u.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 2)
    u.GetWindowTextW(hwnd, buf, n + 2)
    return buf.value


def _children(u, hwnd) -> List[int]:
    found: List[int] = []
    proc_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def _cb(h, _l):
        found.append(h)
        return True

    u.EnumChildWindows(hwnd, proc_type(_cb), 0)
    return found


def list_windows(pid: Optional[int] = None) -> List[Tuple[int, str, str]]:
    """Visible top-level windows of the Max process as (hwnd, title, class)."""
    if not _IS_WINDOWS:
        return []
    pid = pid or max_pid()
    if not pid:
        return []
    u = _user32()
    hits: List[Tuple[int, str, str]] = []
    proc_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def _cb(hwnd, _l):
        owner = ctypes.c_ulong()
        u.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and u.IsWindowVisible(hwnd):
            cls = ctypes.create_unicode_buffer(128)
            u.GetClassNameW(hwnd, cls, 128)
            hits.append((hwnd, _text(u, hwnd), cls.value))
        return True

    u.EnumWindows(proc_type(_cb), 0)
    return hits


def _dismiss_one(u, hwnd, title: str) -> bool:
    """Close one dialog; fall back to clicking a safe button.

    Qt dialogs ignore WM_CLOSE in some builds and draw their own buttons, so
    neither mechanism works alone: WM_CLOSE first, then the native button for
    WinForms/MFC-style dialogs.  Only BUTTON-class children are clicked -- a
    static label can contain the word "Continue" and clicking it does nothing.
    """
    u.PostMessageW(hwnd, _WM_CLOSE, 0, 0)
    for child in _children(u, hwnd):
        cls = ctypes.create_unicode_buffer(128)
        u.GetClassNameW(child, cls, 128)
        if "button" not in cls.value.lower():
            continue
        label = _text(u, child).strip().lower().replace("&", "").strip()
        if label and label in BUTTON_TEXTS:
            u.PostMessageW(child, _BM_CLICK, 0, 0)
            return True
    return True


def dismiss(
    pid: Optional[int] = None,
    extra_titles: Sequence[str] = (),
    aggressive: bool = False,
) -> List[str]:
    """Close known blocking dialogs; return the titles that were dismissed.

    ``aggressive`` additionally closes every plain Win32 dialog window
    (class ``#32770``) owned by 3ds Max. Those windows only exist as modal
    dialogs or as the render-frame window, both of which run their own message
    loop -- the bridge cannot answer while one is up, and by the time the client
    is timing out a human is not going to close it. Only enable it on the
    timeout path, never for a routine probe.
    """
    if not _IS_WINDOWS:
        return []
    patterns = tuple(p.lower() for p in BLOCKING_TITLES) + tuple(
        p.lower() for p in extra_titles
    )
    dismissed: List[str] = []
    u = _user32()
    for hwnd, title, cls in list_windows(pid):
        low = title.lower()
        hit = bool(low) and any(p in low for p in patterns)
        if not hit and aggressive and cls == "#32770":
            hit = True
        if hit:
            if _dismiss_one(u, hwnd, title):
                dismissed.append(title or cls)
    return dismissed


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    pid = max_pid()
    if not pid:
        print("3ds Max is not running.")
        return 1
    if "--list" in argv:
        for hwnd, title, cls in list_windows(pid):
            print("%-10s %-28s %s" % (hwnd, cls, title))
        return 0
    closed = dismiss(pid)
    if closed:
        for t in closed:
            print("closed:", t)
    else:
        print("no blocking dialog found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
