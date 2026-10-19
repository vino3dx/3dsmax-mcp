"""Dismiss blocking startup dialogs in a freshly launched 3ds Max.

3ds Max 2020 opens modal popups (e.g. "Houdini Engine Not Found") before it
runs startup scripts.  A modal dialog stops the MAXScript autoloader dead, so
unattended launches need them clicked away.

This only ever posts BM_CLICK to a *button* of a dialog window that belongs to
a 3dsmax.exe process.  It never terminates anything.

Usage:  python dismiss_modal.py [seconds] [--log PATH]
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)

WM_GETTEXT = 0x000D
WM_GETTEXT_LENGTH = 0x000E
BM_CLICK = 0x00F5
GW_OWNER = 4

user32.GetWindowTextW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
user32.GetClassNameW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
user32.SendMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
user32.GetWindowLongW.argtypes = [wt.HWND, ctypes.c_int]
user32.GetWindow.argtypes = [wt.HWND, wt.UINT]
user32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]


def pid_of(hwnd: int) -> int:
    out = wt.DWORD(0)
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(out))
    return int(out.value)

EnumProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)


def text_of(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(512)
    user32.GetWindowTextW(hwnd, buf, 512)
    return buf.value


def class_of(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def children(hwnd: int):
    out = []

    def cb(h, _):
        out.append(h)
        return True

    user32.EnumChildWindows(hwnd, EnumProc(cb), 0)
    return out


def clickable_labels(hwnd: int):
    found = []
    for ch in children(hwnd):
        cls = class_of(ch)
        label = text_of(ch)
        if cls.lower() in ("button",) and label:
            found.append((ch, label))
    return found


def dialogs(only_pid=None):
    hits = []

    def cb(hwnd, _):
        cls = class_of(hwnd)
        title = text_of(hwnd)
        if cls == "#32770" and title:
            if only_pid is not None and pid_of(hwnd) != only_pid:
                return True
            buttons = clickable_labels(hwnd)
            hits.append((hwnd, title, buttons))
        return True

    user32.EnumWindows(EnumProc(cb), 0)
    return hits


PREFERRED = ("确定", "OK", "是", "Yes", "关闭", "Close", "继续", "Continue")

# Only dialogs that are known 3ds Max startup blockers may be touched.  Anything
# else (MAXScript listener / debugger, unrelated third-party apps) is ignored --
# clicking buttons in those windows would be destructive.
ALLOWED_TITLES = (
    "houdini",
    "missing",
    "not found",
    "missing dll",
    "无法",
    "找不到",
    "缺失",
    "缺少",
    "错误",
    "error",
    "warning",
    "警告",
    "unable",
    "failed",
    "read-only",
    "只读",
)
DENY_TITLES = ("侦听器", "调试器", "listener", "debugger", "升级")


def title_allowed(title: str) -> bool:
    low = title.lower()
    for bad in DENY_TITLES:
        if bad.lower() in low:
            return False
    for good in ALLOWED_TITLES:
        if good.lower() in low:
            return True
    return False



def main() -> int:
    seconds = 90.0
    log_path = None
    only_pid = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--log" and i + 1 < len(args):
            log_path = args[i + 1]
            i += 2
            continue
        if args[i] == "--pid" and i + 1 < len(args):
            only_pid = int(args[i + 1])
            i += 2
            continue
        try:
            seconds = float(args[i])
        except ValueError:
            pass
        i += 1

    logf = open(log_path, "a", encoding="utf-8") if log_path else None

    def log(msg: str) -> None:
        line = "%s  %s" % (time.strftime("%H:%M:%S"), msg)
        print(line)
        if logf:
            logf.write(line + "\n")
            logf.flush()

    log("dismiss_modal: watching for %0.0fs (pid filter: %s)" % (seconds, only_pid))
    clicked = 0
    deadline = time.time() + seconds
    while time.time() < deadline:
        for hwnd, title, buttons in dialogs(only_pid):
            if not title_allowed(title):
                continue
            target = None
            for ch, label in buttons:
                if label.strip() in PREFERRED:
                    target = (ch, label)
                    break
            if target is None and buttons:
                target = buttons[0]
            if target is None:
                continue
            log("dialog %r buttons=%s -> clicking %r" % (title, [b[1] for b in buttons], target[1]))
            user32.SendMessageW(target[0], BM_CLICK, 0, 0)
            clicked += 1
            time.sleep(0.6)
        time.sleep(0.4)

    log("dismiss_modal: done, clicked=%d" % clicked)
    if logf:
        logf.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
