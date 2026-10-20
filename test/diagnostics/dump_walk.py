"""Parse a WER crash dump: exception info, module list and stack frames."""
import struct
import sys


def parse(path, max_frames=120):
    f = open(path, "rb")
    head = f.read(4096)
    sig, ver, num_streams, rva = struct.unpack("<IIII", head[:16])
    if sig != 0x504D444D:
        print(path, ": not a minidump")
        return
    off = rva
    streams = {}
    for _ in range(num_streams):
        stype, ssize, srva = struct.unpack("<III", head[off:off + 12])
        off += 12
        if stype:
            streams[stype] = (ssize, srva)

    ssize, srva = streams[6]
    f.seek(srva)
    exc = f.read(ssize)
    thread_id = struct.unpack_from("<I", exc, 0)[0]
    code = struct.unpack_from("<I", exc, 8)[0]
    addr = struct.unpack_from("<Q", exc, 24)[0]
    ctx_size, ctx_rva = struct.unpack_from("<II", exc, 160)
    f.seek(ctx_rva)
    ctx = f.read(ctx_size)
    rip = struct.unpack_from("<Q", ctx, 0xF8)[0]
    rsp = struct.unpack_from("<Q", ctx, 0x98)[0]
    rbp = struct.unpack_from("<Q", ctx, 0xA0)[0]

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

    ssize, srva = streams[5]
    f.seek(srva)
    nranges = struct.unpack("<I", f.read(4))[0]
    mem = {}
    for _ in range(nranges):
        start = struct.unpack("<Q", f.read(8))[0]
        dsize, drva = struct.unpack("<II", f.read(8))
        mem[(start, start + dsize)] = drva

    def sym(a):
        for base, size, name in mods:
            if base <= a < base + size:
                return name, a - base
        return None, a

    def read_mem(a, n):
        for (s, e), drva in mem.items():
            if s <= a and a + n <= e:
                f.seek(drva + (a - s))
                return f.read(n)
        return None

    print("=" * 70)
    print("dump:", path)
    print("thread: %d  code: 0x%08x  addr: 0x%x" % (thread_id, code, addr))
    name, o = sym(addr)
    if name:
        print("faulting: %s + 0x%x" % (name, o))
    print("RIP=0x%x RSP=0x%x RBP=0x%x" % (rip, rsp, rbp))

    stack = read_mem(rsp, max_frames * 8)
    if stack is None:
        print("stack not in dump")
        return
    print("--- frames ---")
    for i in range(max_frames):
        v = struct.unpack_from("<Q", stack, i * 8)[0]
        if v == 0:
            continue
        nm, o2 = sym(v)
        if nm and not nm.lower().startswith("c:\\windows\\system32") and "microsoft.net" not in nm.lower() and "winsxs" not in nm.lower() and "nativeimages" not in nm.lower():
            print("  [%3d] %s + 0x%x" % (i, nm, o2))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        parse(p)
