"""Type a MAXScript command into the running 3ds Max Listener.

Sequence: show + foreground the listener window, click inside it so the
Scintilla control takes keyboard focus, then type with SendInput and press
Enter.  (Posting WM_CHAR alone does not reach the Scintilla control, and
SendInput without an explicit click can land on the wrong pane.)
"""
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

LISTENER = 68978
MAIN = 68506

SW_SHOW = 5
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("union", _INPUTUNION)]


def _extra():
    e = ctypes.c_ulong(0)
    return ctypes.pointer(e)


def click(x, y):
    user32.SetCursorPos(x, y)
    time.sleep(0.1)
    pe = _extra()
    inp = INPUT(type=INPUT_MOUSE, union=_INPUTUNION(mi=MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, pe)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
    time.sleep(0.05)
    inp = INPUT(type=INPUT_MOUSE, union=_INPUTUNION(mi=MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, pe)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def send_text(text):
    pe = _extra()
    for ch in text:
        code = ord(ch)
        inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(0, code, KEYEVENTF_UNICODE, 0, pe)))
        user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.008)
        inp = INPUT(type=INPUT_KEYBOARD,
                    union=_INPUTUNION(ki=KEYBDINPUT(0, code, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, pe)))
        user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.008)


def send_key(vk):
    pe = _extra()
    inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(vk, 0, 0, 0, pe)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
    time.sleep(0.05)
    inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP, 0, pe)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


user32.ShowWindow(MAIN, 9)  # SW_RESTORE
time.sleep(0.4)
user32.ShowWindow(LISTENER, SW_SHOW)
time.sleep(0.4)
user32.SetForegroundWindow(LISTENER)
time.sleep(0.8)
print("foreground is listener:", user32.GetForegroundWindow() == LISTENER)

rect = wintypes.RECT()
user32.GetWindowRect(LISTENER, ctypes.byref(rect))
cx = (rect.left + rect.right) // 2
cy = rect.bottom - 40  # the input line sits near the bottom of the listener
click(cx, cy)
time.sleep(0.5)

command = sys.argv[1] if len(sys.argv) > 1 else (
    'fileIn @"C:\\Users\\Vino\\AppData\\Local\\Autodesk\\3dsMax\\2020 - 64bit\\ENU\\scripts\\3dsmax-mcp\\mcp_bridge.ms"'
)
send_text(command)
time.sleep(0.4)
send_key(0x0D)  # Enter
print("sent:", command)
