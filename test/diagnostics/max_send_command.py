"""Send a MAXScript command to the running 3ds Max instance via the Listener.

Steps: foreground the Max main window, press F11 (MAXScript Listener), type the
command, press Enter. Uses SendInput with Unicode events so the text arrives
exactly as written.
"""
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

HWND = 68506
SW_RESTORE = 9

user32.ShowWindow(HWND, SW_RESTORE)
time.sleep(0.5)
user32.SetForegroundWindow(HWND)
time.sleep(1.0)

# The MAXScript Listener is a separate Scintilla window; show and focus it.
LISTENER = int(sys.argv[2]) if len(sys.argv) > 2 else 68978
user32.ShowWindow(LISTENER, 5)  # SW_SHOW
time.sleep(0.5)
user32.SetForegroundWindow(LISTENER)
time.sleep(1.0)


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", ctypes.c_byte * 24), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("union", _INPUTUNION)]


INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004


def send_key(vk):
    extra = ctypes.c_ulong(0)
    pextra = ctypes.pointer(extra)
    inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(vk, 0, 0, 0, pextra)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
    time.sleep(0.05)
    inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP, 0, pextra)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def send_text(text):
    extra = ctypes.c_ulong(0)
    pextra = ctypes.pointer(extra)
    for ch in text:
        code = ord(ch)
        inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(0, code, KEYEVENTF_UNICODE, 0, pextra)))
        user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.01)
        inp = INPUT(type=INPUT_KEYBOARD, union=_INPUTUNION(ki=KEYBDINPUT(0, code, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, pextra)))
        user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.01)


VK_F11 = 0x7A
command = sys.argv[1] if len(sys.argv) > 1 else (
    'fileIn @"C:\\Users\\Vino\\AppData\\Local\\Autodesk\\3dsMax\\2020 - 64bit\\ENU\\scripts\\3dsmax-mcp\\mcp_bridge.ms"'
)

print("foreground:", user32.GetForegroundWindow() == LISTENER)
send_text(command)
time.sleep(0.5)
send_key(0x0D)  # Enter
print("sent:", command)
