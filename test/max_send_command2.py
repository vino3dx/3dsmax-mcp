"""Type a MAXScript command into the running 3ds Max Listener via WM_CHAR.

SendInput did not reach the Scintilla control; posting WM_CHAR / WM_KEYDOWN
straight at the listener HWND is the reliable path for Scintilla.
"""
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

LISTENER = 68978
WM_CHAR = 0x0102
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
VK_RETURN = 0x0D

user32.ShowWindow(LISTENER, 5)  # SW_SHOW
time.sleep(0.3)
user32.SetForegroundWindow(LISTENER)
time.sleep(0.7)

command = sys.argv[1] if len(sys.argv) > 1 else (
    'fileIn @"C:\\Users\\Vino\\AppData\\Local\\Autodesk\\3dsMax\\2020 - 64bit\\ENU\\scripts\\3dsmax-mcp\\mcp_bridge.ms"'
)

for ch in command:
    user32.PostMessageW(LISTENER, WM_CHAR, ord(ch), 0)
    time.sleep(0.005)
time.sleep(0.3)
user32.PostMessageW(LISTENER, WM_KEYDOWN, VK_RETURN, 0)
time.sleep(0.05)
user32.PostMessageW(LISTENER, WM_KEYUP, VK_RETURN, 0)
print("posted:", command)
