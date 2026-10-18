#!/usr/bin/env python3
"""3ds Max runtime health and crash-dump forensics (standard library only).

One toolbox for the questions the crash investigation keeps asking, with no
3ds Max and no third-party packages required:

    check           Environment snapshot: residual 3dsmax.exe processes, the
                    bridge port, a live bridge ping, free physical memory and
                    3dsmax.exe crash dumps written in the last hour.
    launch-watch    Start 3ds Max and watch it.  PASS means the process stayed
                    alive for --survive-seconds AND the bridge answered a ping.
                    On PASS 3ds Max is deliberately left running for the next
                    step; on crash the new dumps are reported.
    dump-analyze    Parse a Windows minidump (.mdmp) with struct alone:
                    exception code / address (resolved to module + offset),
                    the crashing thread's registers, a stack scan of the top
                    frames, every loaded module with its file version, and -
                    when the faulting module is a system DLL - the nearest
                    exported symbol for the fault offset.  Used to cross-check
                    the WER bucket offset (0xa527e) against the dump.

Usage:
    python scripts/max_health.py check [--json]
    python scripts/max_health.py launch-watch [--json]
    python scripts/max_health.py dump-analyze <dump.mdmp> [--json]

Exit codes: 0 ok / pass, 1 failed, 2 usage or harness error.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import mmap
import os
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

MAX_EXE = os.path.join("C:" + os.sep, "Program Files", "Autodesk",
                       "3ds Max 2020", "3dsmax.exe")
BRIDGE_PORT = 8765
SYSTEM32 = os.path.join("C:" + os.sep, "Windows", "System32")

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2


# --------------------------------------------------------------- small helpers
def _u32(buf, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def _u64(buf, off: int) -> int:
    return struct.unpack_from("<Q", buf, off)[0]


def _file_version(dwords: Tuple[int, int]) -> str:
    ms, ls = dwords
    return "{0}.{1}.{2}.{3}".format(ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)


def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


# ------------------------------------------------------------ process handling
def max_processes() -> List[Dict[str, Any]]:
    """Every running 3dsmax.exe process (empty list when none)."""
    if os.name != "nt":
        return []
    # tasklist speaks the system ANSI code page (GBK on a Chinese Windows),
    # so decode explicitly instead of relying on the locale-independent utf-8.
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq 3dsmax.exe", "/NH"],
            capture_output=True, timeout=20,
        ).stdout.decode("mbcs", "replace")
    except OSError:
        return []
    procs: List[Dict[str, Any]] = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].lower() == "3dsmax.exe":
            try:
                procs.append({"pid": int(parts[1]), "image": parts[0]})
            except ValueError:
                continue
    return procs


def port_open(host: str, port: int, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def bridge_ping(host: str = "127.0.0.1", port: int = BRIDGE_PORT,
                timeout: float = 3.0) -> Dict[str, Any]:
    """One bridge_status request on the newline-delimited JSON protocol."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            line = json.dumps({"id": 1, "method": "bridge_status", "params": {}},
                              ensure_ascii=True) + "\n"
            sock.sendall(line.encode("ascii"))
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
            raw = buf.split(b"\n", 1)[0].decode("ascii", "replace")
            data = json.loads(raw)
            if data.get("ok"):
                return {"connected": True, "port": port, "info": data.get("result")}
            return {"connected": False, "kind": "bridge_error",
                    "message": str(data.get("error"))[:400]}
    except OSError as exc:
        return {"connected": False, "kind": "not_running", "message": str(exc)}
    except ValueError as exc:
        return {"connected": False, "kind": "protocol_error", "message": str(exc)}


class _MemoryStatusEx(ctypes.Structure):
    _fields_ = [
        ("dwLength", ctypes.c_ulong),
        ("dwMemoryLoad", ctypes.c_ulong),
        ("ullTotalPhys", ctypes.c_ulonglong),
        ("ullAvailPhys", ctypes.c_ulonglong),
        ("ullTotalPageFile", ctypes.c_ulonglong),
        ("ullAvailPageFile", ctypes.c_ulonglong),
        ("ullTotalVirtual", ctypes.c_ulonglong),
        ("ullAvailVirtual", ctypes.c_ulonglong),
        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
    ]


def free_memory() -> Dict[str, Any]:
    """GlobalMemoryStatusEx snapshot (zeros on non-Windows)."""
    if os.name != "nt":
        return {"avail_phys_gb": None, "total_phys_gb": None}
    stat = _MemoryStatusEx()
    stat.dwLength = ctypes.sizeof(_MemoryStatusEx)
    ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat))
    gib = 1024.0 ** 3
    return {"avail_phys_gb": round(stat.ullAvailPhys / gib, 2),
            "total_phys_gb": round(stat.ullTotalPhys / gib, 2)}


def crash_dump_dir() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", "")) / "CrashDumps"


def list_crash_dumps() -> List[Path]:
    folder = crash_dump_dir()
    if not folder.is_dir():
        return []
    return sorted(folder.glob("3dsmax.exe.*.dmp"), key=lambda p: p.stat().st_mtime)


def recent_crash_dumps(within_s: float = 3600.0) -> List[Dict[str, Any]]:
    now = time.time()
    out: List[Dict[str, Any]] = []
    for path in list_crash_dumps():
        try:
            st = path.stat()
        except OSError:
            continue
        if now - st.st_mtime <= within_s:
            out.append({"path": str(path), "size_bytes": st.st_size,
                        "mtime": _iso(st.st_mtime)})
    return out


# ------------------------------------------------------------------- subcommands
def cmd_check(args: argparse.Namespace) -> int:
    procs = max_processes()
    ping = bridge_ping(port=args.port)
    mem = free_memory()
    recent = recent_crash_dumps()
    snapshot = {
        "time": _iso(time.time()),
        "residual_processes": procs,
        "port_open": port_open("127.0.0.1", args.port),
        "bridge": ping,
        "memory": mem,
        "recent_crash_dumps": recent,
    }
    if args.json:
        print(json.dumps(snapshot, ensure_ascii=False, indent=2))
    else:
        print("time                : {0}".format(snapshot["time"]))
        print("residual 3dsmax.exe : {0}".format(
            ", ".join(str(p["pid"]) for p in procs) if procs else "none"))
        print("port {0:<15} : {1}".format(args.port, "open" if snapshot["port_open"] else "closed"))
        if ping.get("connected"):
            info = ping.get("info") or {}
            print("bridge ping         : ok (handlers={0}, max={1})".format(
                info.get("handlerCount"), (info.get("maxVersion") or {}).get("year")))
        else:
            print("bridge ping         : {0} ({1})".format(
                ping.get("kind"), str(ping.get("message"))[:120]))
        print("free memory         : {0} / {1} GB".format(
            mem.get("avail_phys_gb"), mem.get("total_phys_gb")))
        print("crashes last hour   : {0}".format(len(recent)))
        for item in recent:
            print("   {0}  {1}  {2:.1f} MB".format(
                item["mtime"], os.path.basename(item["path"]),
                item["size_bytes"] / 1048576.0))
    healthy = (not procs) or ping.get("connected")
    return EXIT_OK if healthy else EXIT_FAIL


def cmd_launch_watch(args: argparse.Namespace) -> int:
    residual = max_processes()
    if residual:
        report = {"result": "aborted", "reason": "residual 3dsmax.exe present",
                  "processes": residual}
        print(json.dumps(report, ensure_ascii=False) if args.json else str(report))
        return EXIT_FAIL

    before = {p.name for p in list_crash_dumps()}
    started = time.time()
    try:
        proc = subprocess.Popen([args.exe])
    except OSError as exc:
        report = {"result": "launch_failed", "reason": str(exc)}
        print(json.dumps(report, ensure_ascii=False) if args.json else str(report))
        return EXIT_FAIL

    ping: Dict[str, Any] = {"connected": False}
    last_ping = 0.0
    result = "watch_timeout"
    while True:
        time.sleep(args.poll_seconds)
        elapsed = time.time() - started
        if proc.poll() is not None:
            result = "process_exited"
            break
        if time.time() - last_ping >= args.ping_every:
            ping = bridge_ping(port=args.port)
            last_ping = time.time()
        if elapsed >= args.survive_seconds and ping.get("connected"):
            result = "PASS"
            break
        if elapsed >= args.watch_seconds:
            break

    elapsed = round(time.time() - started, 1)
    after = [p for p in list_crash_dumps() if p.name not in before]
    report: Dict[str, Any] = {
        "result": result,
        "pid": proc.pid,
        "exe": args.exe,
        "alive_seconds": elapsed,
        "survive_seconds": args.survive_seconds,
        "exit_code": proc.poll() if result == "process_exited" else None,
        "bridge": ping,
        "new_crash_dumps": [str(p) for p in after],
        "max_left_running": result == "PASS",
        "started": _iso(started),
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("launch-watch: {0} after {1}s (pid {2})".format(result, elapsed, proc.pid))
        for key in ("exit_code", "bridge", "new_crash_dumps"):
            print("  {0}: {1}".format(key, report[key]))
    return EXIT_OK if result == "PASS" else EXIT_FAIL


# ============================================================ minidump analysis
# Stream type ids (MINIDUMP_STREAM_TYPE), little-endian throughout.
_STREAM_THREADS = 3
_STREAM_MODULES = 4
_STREAM_MEMORY = 5
_STREAM_EXCEPTION = 6
_STREAM_MEMORY64 = 9

_EXCEPTION_CODE_NAMES = {
    0xC0000005: "STATUS_ACCESS_VIOLATION",
    0xC0000409: "STATUS_STACK_BUFFER_OVERRUN (fail-fast / control flow guard)",
    0xC0000374: "STATUS_HEAP_CORRUPTION",
    0x80000003: "STATUS_BREAKPOINT",
    0xE06D7363: "C++ exception (throw)",
}

# Parameter 0 of a 0xC0000409 record is the FAST_FAIL_* subcode (ntddk.h /
# winnt.h FAST_FAIL codes).  Only the ones that can plausibly end up in an
# application crash are named.
_FAIL_FAST_NAMES = {
    0: "FAST_FAIL_LEGACY_GS_VIOLATION",
    2: "FAST_FAIL_STACK_COOKIE_CHECK_FAILURE",
    3: "FAST_FAIL_CORRUPT_LIST_ENTRY",
    4: "FAST_FAIL_INCORRECT_STACK",
    5: "FAST_FAIL_INVALID_ARG",
    6: "FAST_FAIL_INVALID_POF_CALL",
    7: "FAST_FAIL_FATAL_APP_EXIT (abort / exit path)",
    8: "FAST_FAIL_RANGE_CHECK_FAILURE",
    10: "FAST_FAIL_GUARD_ICALL_CHECK_FAILURE (CFG)",
    11: "FAST_FAIL_GUARD_WRITE_CHECK_FAILURE",
    13: "FAST_FAIL_INVALID_SETOFCONTEXT",
    16: "FAST_FAIL_INVALID_IMAGE_BASE",
    17: "FAST_FAIL_DUPLICATE_HANDLE",
    18: "FAST_FAIL_INVALID_JUMP_BUFFER",
    0x14: "FAST_FAIL_INVALID_CONTROL_FLOW_TARGET (XFG)",
    0x1D: "FAST_FAIL_CET_HARDWARE_ENABLED",
}


class MiniDump:
    """Just enough minidump for crash forensics: streams, modules, threads."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._fh = open(path, "rb")
        try:
            self.mm = mmap.mmap(self._fh.fileno(), 0, access=mmap.ACCESS_READ)
        except ValueError as exc:  # empty file
            self._fh.close()
            raise ValueError("cannot map {0}: {1}".format(path, exc))
        if self.mm[:4] != b"MDMP":
            raise ValueError("not a minidump (bad signature)")
        self.version = _u32(self.mm, 0x04)
        self.num_streams = _u32(self.mm, 0x08)
        self.streams: Dict[int, Tuple[int, int]] = {}
        dir_rva = _u32(self.mm, 0x0C)
        for i in range(self.num_streams):
            off = dir_rva + i * 12
            stype = _u32(self.mm, off)
            size = _u32(self.mm, off + 4)
            rva = _u32(self.mm, off + 8)
            self.streams[stype] = (rva, size)

    def close(self) -> None:
        try:
            self.mm.close()
        finally:
            self._fh.close()

    def read(self, rva: int, size: int) -> bytes:
        return self.mm[rva:rva + size]

    def read_string(self, rva: int) -> str:
        length = _u32(self.mm, rva)
        return self.mm[rva + 4: rva + 4 + length].decode("utf-16le", "replace")

    # ------------------------------------------------------------- streams
    def exception(self) -> Optional[Dict[str, Any]]:
        if _STREAM_EXCEPTION not in self.streams:
            return None
        rva, size = self.streams[_STREAM_EXCEPTION]
        buf = self.read(rva, size)
        return {
            "thread_id": _u32(buf, 0x00),
            "exception_code": _u32(buf, 0x08),
            "exception_flags": _u32(buf, 0x0C),
            "exception_address": _u64(buf, 0x18),
            "number_parameters": _u32(buf, 0x20),
            "parameters": [_u64(buf, 0x28 + 8 * i) for i in range(15)],
            "context": {"data_size": _u32(buf, 0xA0), "rva": _u32(buf, 0xA4)},
        }

    def modules(self) -> List[Dict[str, Any]]:
        if _STREAM_MODULES not in self.streams:
            return []
        rva, size = self.streams[_STREAM_MODULES]
        buf = self.read(rva, size)
        count = _u32(buf, 0)
        out: List[Dict[str, Any]] = []
        for i in range(count):
            off = 4 + i * 108
            base = _u64(buf, off)
            ver_ms = _u32(buf, off + 0x18 + 0x08)
            ver_ls = _u32(buf, off + 0x18 + 0x0C)
            signature = _u32(buf, off + 0x18)
            out.append({
                "name": self.read_string(_u32(buf, off + 0x14)),
                "base": base,
                "size": _u32(buf, off + 0x08),
                "timestamp": _u32(buf, off + 0x10),
                "file_version": _file_version((ver_ms, ver_ls))
                if signature == 0xFEEF04BD else None,
            })
        return out

    def threads(self) -> List[Dict[str, Any]]:
        if _STREAM_THREADS not in self.streams:
            return []
        rva, size = self.streams[_STREAM_THREADS]
        buf = self.read(rva, size)
        count = _u32(buf, 0)
        out: List[Dict[str, Any]] = []
        for i in range(count):
            off = 4 + i * 56
            out.append({
                "thread_id": _u32(buf, off + 0x00),
                "teb": _u64(buf, off + 0x10),
                "stack_start": _u64(buf, off + 0x18),
                "stack_size": _u32(buf, off + 0x20),
                "stack_rva": _u32(buf, off + 0x24),
                "context_size": _u32(buf, off + 0x28),
                "context_rva": _u32(buf, off + 0x2C),
            })
        return out

    def memory_ranges(self) -> List[Tuple[int, int]]:
        """(start, size) pairs of every memory range stored in the dump."""
        out: List[Tuple[int, int]] = []
        if _STREAM_MEMORY in self.streams:
            rva, size = self.streams[_STREAM_MEMORY]
            buf = self.read(rva, size)
            count = _u32(buf, 0)
            for i in range(count):
                off = 4 + i * 16
                out.append((_u64(buf, off), _u32(buf, off + 8)))
        if _STREAM_MEMORY64 in self.streams:
            rva, size = self.streams[_STREAM_MEMORY64]
            buf = self.read(rva, size)
            count = _u64(buf, 0)
            for i in range(count):
                off = 16 + i * 16
                out.append((_u64(buf, off), _u32(buf, off + 8)))
        return out

    def context_registers(self, thread: Dict[str, Any]) -> Dict[str, Any]:
        """x64 CONTEXT subset (guarded by the stored context size)."""
        rva, size = thread["context_rva"], thread["context_size"]
        if not rva or not size:
            return {"available": False}
        buf = self.read(rva, size)
        regs: Dict[str, Any] = {
            "available": True, "data_size": size,
            "context_flags": _u32(buf, 0x30) if size > 0x34 else None,
        }
        if size >= 0x100:  # RIP/RSP present
            regs["rip"] = _u64(buf, 0xF8)
            regs["rsp"] = _u64(buf, 0x98)
            regs["rbp"] = _u64(buf, 0xA0)
            for name, off in (("rax", 0x78), ("rbx", 0x90), ("rcx", 0x80),
                              ("rdx", 0x88), ("rsi", 0xA8), ("rdi", 0xB0)):
                regs[name] = _u64(buf, off)
        return regs


def _module_for(modules: List[Dict[str, Any]], address: int) -> Optional[Dict[str, Any]]:
    for mod in modules:
        if mod["base"] <= address < mod["base"] + mod["size"]:
            return mod
    return None


def _scan_stack(dump: MiniDump, thread: Dict[str, Any],
                modules: List[Dict[str, Any]], limit: int = 24) -> List[Dict[str, Any]]:
    """Return-address candidates: qwords on the thread stack that point into
    a loaded module.  Nearest-to-RSP first; duplicates collapsed."""
    if not thread["stack_rva"] or not thread["stack_size"]:
        return []
    data = dump.read(thread["stack_rva"], thread["stack_size"])
    start = thread["stack_start"]
    seen = set()
    hits: List[Dict[str, Any]] = []
    for off in range(0, len(data) - 8, 8):
        value = struct.unpack_from("<Q", data, off)[0]
        if value < 0x10000:
            continue
        mod = _module_for(modules, value)
        if mod is None:
            continue
        key = (mod["name"], value - mod["base"])
        if key in seen:
            continue
        seen.add(key)
        hits.append({"stack_address": start + off, "value": value,
                     "module": mod["name"], "offset": value - mod["base"]})
    return hits[:limit]


def _pe_sections(data: bytes) -> Optional[List[Tuple[int, int, int, int]]]:
    """[(virtual_address, virtual_size, raw_pointer, raw_size)] or None."""
    if data[:2] != b"MZ":
        return None
    pe_off = _u32(data, 0x3C)
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        return None
    coff = pe_off + 4
    num_sections = _u16_at(data, coff + 2)
    size_opt = _u16_at(data, coff + 16)
    opt = coff + 20
    sections = []
    for i in range(num_sections):
        off = opt + size_opt + i * 40
        # IMAGE_SECTION_HEADER: Name[8], VirtualSize, VirtualAddress,
        # SizeOfRawData, PointerToRawData
        sections.append((_u32(data, off + 0x0C), _u32(data, off + 0x08),
                         _u32(data, off + 0x14), _u32(data, off + 0x10)))
    return sections


def _u16_at(data: bytes, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def _rva_to_offset(rva: int, sections: List[Tuple[int, int, int, int]]) -> Optional[int]:
    for va, vsize, raw, rsize in sections:
        if va <= rva < va + max(vsize, rsize):
            return raw + (rva - va)
    return None


def nearest_exports(dll_path: str) -> Optional[List[Tuple[int, str]]]:
    """[(rva, name)] of named exports from an on-disk PE, sorted by rva."""
    try:
        with open(dll_path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    sections = _pe_sections(data)
    if not sections:
        return None
    pe_off = _u32(data, 0x3C)
    coff = pe_off + 4
    size_opt = _u16_at(data, coff + 16)
    opt = coff + 20
    magic = _u16_at(data, opt)
    if magic not in (0x10B, 0x20B):
        return None
    dir_off = opt + (112 if magic == 0x20B else 96)
    export_rva = _u32(data, dir_off)
    if not export_rva:
        return None
    exp_off = _rva_to_offset(export_rva, sections)
    if exp_off is None:
        return None
    eat_rva = _u32(data, exp_off + 0x1C)
    npt_rva = _u32(data, exp_off + 0x20)
    ot_rva = _u32(data, exp_off + 0x24)
    num_names = _u32(data, exp_off + 0x18)
    eat_off = _rva_to_offset(eat_rva, sections)
    npt_off = _rva_to_offset(npt_rva, sections)
    ot_off = _rva_to_offset(ot_rva, sections)
    if None in (eat_off, npt_off, ot_off):
        return None
    out: List[Tuple[int, str]] = []
    for i in range(num_names):
        name_rva = _u32(data, npt_off + i * 4)
        name_off = _rva_to_offset(name_rva, sections)
        if name_off is None:
            continue
        end = data.find(b"\0", name_off)
        name = data[name_off:end].decode("ascii", "replace")
        ordinal = _u16_at(data, ot_off + i * 2)
        func_rva = _u32(data, eat_off + ordinal * 4)
        out.append((func_rva, name))
    out.sort()
    return out or None


def analyze_dump(path: str, wer_offset: Optional[int] = None) -> Dict[str, Any]:
    dump = MiniDump(path)
    try:
        report: Dict[str, Any] = {"file": path,
                                  "size_bytes": os.path.getsize(path),
                                  "dump_version": "{0}.{1}".format(
                                      dump.version >> 16, dump.version & 0xFFFF),
                                  "streams": {str(k): v[1] for k, v in
                                              sorted(dump.streams.items())}}
        exc = dump.exception()
        modules = dump.modules()
        threads = dump.threads()
        report["module_count"] = len(modules)
        report["thread_count"] = len(threads)

        fault = None
        mod = None
        if exc:
            code = exc["exception_code"]
            addr = exc["exception_address"]
            mod = _module_for(modules, addr)
            fault = {
                "exception_code": "0x{0:08X}".format(code),
                "exception_code_name": _EXCEPTION_CODE_NAMES.get(code, "unknown"),
                "exception_address": addr,
                "thread_id": exc["thread_id"],
                "number_parameters": exc["number_parameters"],
                "parameters": ["0x{0:x}".format(p) for p in exc["parameters"]
                               [:max(exc["number_parameters"], 0)]],
            }
            if code == 0xC0000409 and exc["number_parameters"] >= 1:
                # A fail-fast record: parameter 0 is the FAST_FAIL_* subcode.
                fault["fail_fast_code"] = exc["parameters"][0]
                fault["fail_fast_name"] = _FAIL_FAST_NAMES.get(
                    exc["parameters"][0], "unknown")
            if mod:
                fault["module"] = mod["name"]
                fault["offset"] = addr - mod["base"]
                fault["module_version"] = mod["file_version"]
                fault["module_base"] = mod["base"]
                fault["offset_hex"] = "0x{0:x}".format(fault["offset"])
            report["exception"] = fault

            thread = next((t for t in threads
                           if t["thread_id"] == exc["thread_id"]), None)
            if thread:
                regs = dump.context_registers(thread)
                report["crash_thread_registers"] = regs
                frames = _scan_stack(dump, thread, modules)
                report["stack_scan"] = frames
                report["stack_range"] = {
                    "start": thread["stack_start"], "size": thread["stack_size"]}
                # Name the frames: nearest export for every module that has an
                # on-disk twin in System32 (cache per DLL).
                cache: Dict[str, Optional[List[Tuple[int, str]]]] = {}

                def nearest(module: str, offset: int) -> Optional[Dict[str, Any]]:
                    base = os.path.basename(module)
                    if base not in cache:
                        dll = os.path.join(SYSTEM32, base)
                        cache[base] = (nearest_exports(dll)
                                       if os.path.isfile(dll) else None)
                    exports = cache[base]
                    if not exports:
                        return None
                    prev = None
                    for rva, name in exports:
                        if rva > offset:
                            break
                        prev = (rva, name)
                    if prev is None:
                        return None
                    return {"symbol": prev[1], "distance": offset - prev[0]}

                for frame in frames:
                    hit = nearest(frame["module"], frame["offset"])
                    if hit:
                        frame["symbol"] = hit["symbol"]
                        frame["symbol_distance"] = hit["distance"]
            report["threads"] = [{"thread_id": t["thread_id"]} for t in threads]

        report["modules"] = modules

        # .pdata availability: is the faulting module's image in the dump?
        ranges = dump.memory_ranges()
        if mod and ranges:
            covered = any(start <= mod["base"] and
                          mod["base"] + mod["size"] <= start + size
                          for start, size in ranges)
            report["pdata_image_in_dump"] = covered
            report["memory_ranges"] = len(ranges)

        # Nearest exported symbol for the fault offset (system DLLs only).
        if mod and fault and "offset" in fault:
            # Module names in the dump are full paths; the on-disk twin for a
            # system DLL lives in System32 under its basename.
            dll = os.path.join(SYSTEM32, os.path.basename(mod["name"]))
            exports = nearest_exports(dll) if os.path.isfile(dll) else None
            if exports:
                target = fault["offset"]
                prev = None
                for rva, name in exports:
                    if rva > target:
                        break
                    prev = (rva, name)
                if prev:
                    report["nearest_export"] = {
                        "name": prev[1], "export_rva": prev[0],
                        "distance_bytes": target - prev[0],
                        "source": dll}
        if wer_offset is not None and fault and "offset" in fault:
            report["wer_offset"] = "0x{0:x}".format(wer_offset)
            report["wer_offset_match"] = (fault["offset"] == wer_offset)
        return report
    finally:
        dump.close()


def cmd_dump_analyze(args: argparse.Namespace) -> int:
    try:
        report = analyze_dump(args.dump, wer_offset=args.wer_offset)
    except (OSError, ValueError) as exc:
        print("dump-analyze: cannot read {0}: {1}".format(args.dump, exc))
        return EXIT_FAIL
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return EXIT_OK
    print("file        : {0} ({1:.1f} MB)".format(
        report["file"], report["size_bytes"] / 1048576.0))
    print("modules     : {0}, threads: {1}".format(
        report.get("module_count"), report.get("thread_count")))
    exc = report.get("exception") or {}
    if exc:
        print("exception   : {0} ({1})".format(
            exc.get("exception_code"), exc.get("exception_code_name")))
        print("address     : 0x{0:x}".format(exc.get("exception_address", 0)))
        if "module" in exc:
            print("fault module: {0} + 0x{1:x}  (version {2}, base 0x{3:x})".format(
                exc["module"], exc["offset"], exc.get("module_version"),
                exc.get("module_base", 0)))
        if "fail_fast_name" in exc:
            print("fail-fast   : {0} (code {1})".format(
                exc["fail_fast_name"], exc.get("fail_fast_code")))
        if "nearest_export" in report:
            ne = report["nearest_export"]
            print("nearest sym : {0} + {1} bytes (from {2})".format(
                ne["name"], ne["distance_bytes"], os.path.basename(ne["source"])))
        if "wer_offset_match" in report:
            print("wer offset  : {0} -> {1}".format(
                report["wer_offset"],
                "MATCH" if report["wer_offset_match"] else "MISMATCH"))
        regs = report.get("crash_thread_registers") or {}
        if regs.get("available"):
            print("crash thread: rip=0x{0:x} rsp=0x{1:x}".format(
                regs.get("rip", 0), regs.get("rsp", 0)))
        print("top frames  :")
        for frame in (report.get("stack_scan") or [])[:12]:
            symbol = ""
            if "symbol" in frame:
                symbol = "  ~{0} + {1}".format(frame["symbol"],
                                               frame.get("symbol_distance", 0))
            print("   [0x{0:012x}] {1} + 0x{2:x}{3}".format(
                frame["stack_address"], os.path.basename(frame["module"]),
                frame["offset"], symbol))
    return EXIT_OK


# ------------------------------------------------------------------------ main
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="3ds Max runtime health and dump forensics (stdlib only).")
    parser.add_argument("--port", type=int, default=BRIDGE_PORT,
                        help="bridge TCP port (default 8765)")
    sub = parser.add_subparsers(dest="command")

    p_check = sub.add_parser("check", help="environment snapshot")
    p_check.add_argument("--json", action="store_true")
    p_check.set_defaults(func=cmd_check)

    p_watch = sub.add_parser("launch-watch", help="start Max and watch it")
    p_watch.add_argument("--json", action="store_true")
    p_watch.add_argument("--exe", default=MAX_EXE)
    p_watch.add_argument("--survive-seconds", type=float, default=120.0)
    p_watch.add_argument("--watch-seconds", type=float, default=300.0)
    p_watch.add_argument("--poll-seconds", type=float, default=1.0)
    p_watch.add_argument("--ping-every", type=float, default=5.0)
    p_watch.set_defaults(func=cmd_launch_watch)

    p_dump = sub.add_parser("dump-analyze", help="parse a .mdmp file")
    p_dump.add_argument("dump")
    p_dump.add_argument("--json", action="store_true")
    p_dump.add_argument("--wer-offset", type=lambda x: int(x, 0), default=None,
                        help="WER bucket offset to cross-check, e.g. 0xa527e")
    p_dump.set_defaults(func=cmd_dump_analyze)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return EXIT_USAGE
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
