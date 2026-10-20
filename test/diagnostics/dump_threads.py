"""Walk every thread stack in a crash dump and report non-system frames."""
import struct
import sys

sys.path.insert(0, r"D:\Workspace\Dev\3dsmax-mcp\test")
from dump_unwind import Module, load_pe_sections  # noqa: E402


def main(path):
    f = open(path, "rb")
    head = f.read(4096)
    sig, ver, num_streams, rva = struct.unpack("<IIII", head[:16])
    off = rva
    streams = {}
    for _ in range(num_streams):
        stype, ssize, srva = struct.unpack("<III", head[off:off + 12])
        off += 12
        if stype:
            streams[stype] = (ssize, srva)

    ssize, srva = streams[4]
    f.seek(srva)
    total = struct.unpack("<I", f.read(4))[0]
    mods = []
    for _ in range(total):
        raw = f.read(108)
        base, size = struct.unpack_from("<QI", raw, 0)
        name_rva = struct.unpack_from("<I", raw, 20)[0]
        pos = f.tell()
        f.seek(name_rva)
        cb = struct.unpack("<I", f.read(4))[0]
        name = f.read(cb).decode("utf-16-le", "replace").rstrip("\x00")
        f.seek(pos)
        mods.append((base, size, name))
    modules = {b: Module(b, s, n, n) for b, s, n in mods}

    ssize, srva = streams[5]
    f.seek(srva)
    nranges = struct.unpack("<I", f.read(4))[0]
    mem = {}
    for _ in range(nranges):
        start = struct.unpack("<Q", f.read(8))[0]
        dsize, drva = struct.unpack("<II", f.read(8))
        mem[(start, start + dsize)] = drva

    def read_mem(a, n):
        for (s, e), drva in mem.items():
            if s <= a and a + n <= e:
                f.seek(drva + (a - s))
                return f.read(n)
        return None

    def find_mod(a):
        for base, size, name in mods:
            if base <= a < base + size:
                return modules[base], a - base
        return None, a

    # thread list stream = 3
    ssize, srva = streams[3]
    f.seek(srva)
    nthreads = struct.unpack("<I", f.read(4))[0]
    print("threads:", nthreads)
    interesting = ("3dsmax", "Autodesk", "EPoly", "stdplugs", "plugin", "core", "max")
    for t in range(nthreads):
        raw = f.read(48)
        tid = struct.unpack_from("<I", raw, 0)[0]
        ctx_size, ctx_rva = struct.unpack_from("<II", raw, 24)
        stack_size, stack_rva = struct.unpack_from("<II", raw, 32)
        f.seek(ctx_rva)
        ctx = f.read(ctx_size)
        rip = struct.unpack_from("<Q", ctx, 0xF8)[0]
        rsp = struct.unpack_from("<Q", ctx, 0x98)[0]
        m, o = find_mod(rip)
        where = "%s + 0x%x" % (m.name, o) if m else "0x%x" % rip
        keep = m and any(k in m.name for k in interesting)
        print("--- thread %d  RIP: %s%s" % (tid, where, "   <== INTERESTING" if keep else ""))
        if not keep:
            continue
        for _ in range(24):
            stack = read_mem(rsp, 8)
            if stack is None:
                break
            ret = struct.unpack("<Q", stack)[0]
            if ret == 0:
                break
            rm, ro = find_mod(ret)
            if rm and any(k in rm.name for k in interesting):
                print("      %s + 0x%x" % (rm.name, ro))
            rsp_next = None
            if m and m.funcs:
                delta = m.unwind(rip)
                if delta is not None:
                    rsp_next = rsp + delta
            if rsp_next is None:
                rsp_next = rsp + 8
            rip = ret
            rsp = rsp_next
            m = rm


if __name__ == "__main__":
    main(sys.argv[1])
