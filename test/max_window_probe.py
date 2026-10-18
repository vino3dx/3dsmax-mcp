"""Window automation helper for the running 3ds Max instance.

Restores the Max main window, brings it to the foreground and screenshots it.
No keystrokes are sent by this script - it only reports the current state.
"""
import ctypes
import struct
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

SW_RESTORE = 9
HWND = int(sys.argv[1]) if len(sys.argv) > 1 else 68506

user32.ShowWindow(HWND, SW_RESTORE)
time.sleep(0.5)
user32.SetForegroundWindow(HWND)
time.sleep(1.0)

fg = user32.GetForegroundWindow()
print("foreground hwnd:", fg, "target:", HWND, "match:", fg == HWND)

# screenshot the Max window rect
rect = wintypes.RECT()
user32.GetWindowRect(HWND, ctypes.byref(rect))
x, y = rect.right - rect.left, rect.bottom - rect.top
print("window rect:", rect.left, rect.top, x, y)

dc = user32.GetWindowDC(HWND)
bmp = gdi32.CreateCompatibleDC(dc)
hbmp = gdi32.CreateCompatibleBitmap(dc, x, y)
gdi32.SelectObject(bmp, hbmp)
gdi32.BitBlt(bmp, 0, 0, x, y, dc, 0, 0, 0x00CC0020)


class BITMAPINFO(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD),
    ]


bi = BITMAPINFO()
bi.biSize = ctypes.sizeof(BITMAPINFO)
bi.biWidth = x
bi.biHeight = -y
bi.biPlanes = 1
bi.biBitCount = 32
bi.biCompression = 0
buf = ctypes.create_string_buffer(x * y * 4)
gdi32.GetDIBits(bmp, hbmp, 0, y, buf, ctypes.byref(bi), 0)
out = r"D:\Workspace\Dev\3dsmax-mcp\test\logs\max_window_state.bmp"
with open(out, "wb") as f:
    f.write(b"BM" + struct.pack("<IHHI", 14 + 40 + x * y * 4, 0, 0, 54))
    f.write(struct.pack("<IiiHHIIiiII", 40, x, y, 1, 32, 0, x * y * 4, 0, 0, 0, 0))
    f.write(buf.raw)
print("saved:", out)
