"""Unwind-based stack walk for x64 crash dumps using .pdata RUNTIME_FUNCTION."""
import struct
import sys


def load_pe_sections(data):
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    num_sections = struct.unpack_from("<H", data, pe_off + 6)[0]
    size_opt = struct.unpack_from("<H", data, pe_off + 20)[0]
    sections = []
    sec_off = pe_off + 24 + size_opt
    for i in range(num_sections):
        name = data[sec_off + i * 40: sec_off + i * 40 + 8].rstrip(b"\0").decode()
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, sec_off + i * 40 + 8)
        sections.append((name, vaddr, vsize, rawptr, rawsize))
    return sections


class Module:
    def __init__(self, base, size, name, path):
        self.base = base
        self.size = size
        self.name = name
        self.path = path
        self.sections = None
        self.funcs = None
        try:
            data = open(path, "rb").read()
            self.sections = load_pe_sections(data)
            # .pdata -> RUNTIME_FUNCTION array
            for sname, vaddr, vsize, rawptr, rawsize in self.sections:
                if sname == ".pdata":
                    n = vsize // 12
                    self.funcs = []
                    for i in range(n):
                        start, end, u = struct.unpack_from("<III", data, rawptr + i * 12)
                        self.funcs.append((start, end, u))
        except Exception:
            pass

    def rva_to_off(self, rva):
        if not self.sections:
            return None
        for name, vaddr, vsize, rawptr, rawsize in self.sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                return rawptr + (rva - vaddr)
        return None

    def read_rva(self, rva, n):
        off = self.rva_to_off(rva)
        if off is None:
            return None
        try:
            with open(self.path, "rb") as f:
                f.seek(off)
                return f.read(n)
        except Exception:
            return None

    def unwind(self, rip):
        """Return (next_rip, next_rsp) after the function containing rip, or None."""
        if not self.funcs:
            return None
        rva = rip - self.base
        fn = None
        for start, end, u in self.funcs:
            if start <= rva < end:
                fn = (start, end, u)
                break
        if fn is None:
            return None
        u = fn[2]
        uw = self.read_rva(u, 8)
        if uw is None or len(uw) < 4:
            return None
        ver_flags = uw[0]
        flags = ver_flags & 0x07
        if flags == 1:  # UWOP_PUSH_NONVOL only chain
            return None
        # we handle the common prologue patterns manually
        codes = uw[4:]
        rsp_delta = 0
        ripslot = None
        i = 0
        while i + 2 <= len(codes):
            off_in_pro, op, info = codes[i], codes[i + 1], codes[i + 2] if i + 2 < len(codes) else 0
            # UNWIND_CODE: offset_in_prolog(1), opcode(1), op_info(1)
            i += 3
            opc = op
            if opc == 0:  # UWOP_PUSH_NONVOL
                rsp_delta += 8
            elif opc == 1:  # UWOP_ALLOC_LARGE
                if info == 0:
                    rsp_delta += struct.unpack_from("<H", codes, i)[0] * 8
                    i += 2
                else:
                    rsp_delta += struct.unpack_from("<I", codes, i)[0]
                    i += 4
            elif opc == 2:  # UWOP_ALLOC_SMALL
                rsp_delta += (info + 1) * 8
            elif opc == 3:  # UWOP_SET_FPREG
                pass
            elif opc == 4:  # UWOP_SAVE_NONVOL
                i += 2
            elif opc == 5:  # UWOP_SAVE_NONVOL_FAR
                i += 4
            elif opc == 10:  # UWOP_PUSH_MACHFRAME
                rsp_delta += 40 + 8 * info
        return rsp_delta


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

    modules = {}
    for base, size, name in mods:
        modules[base] = Module(base, size, name, name)

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

    print("=" * 70)
    print("dump:", path)
    print("thread: %d code: 0x%08x faulting addr: 0x%x" % (thread_id, code, addr))
    m, o = find_mod(addr)
    if m:
        print("faulting module: %s + 0x%x" % (m.name, o))
    print("--- unwind walk ---")
    for _ in range(40):
        m, o = find_mod(rip)
        label = "%s + 0x%x" % (m.name, o) if m else "0x%x" % rip
        print("  RIP=0x%x  %s" % (rip, label))
        stack = read_mem(rsp, 8)
        if stack is None:
            print("  (stack unreadable)")
            break
        ret = struct.unpack("<Q", stack)[0]
        if ret == 0:
            break
        rm, ro = find_mod(ret)
        # find the function containing rip and its unwind info to advance rsp
        rsp_next = None
        if m and m.funcs:
            delta = m.unwind(rip)
            if delta is not None:
                rsp_next = rsp + delta
        if rsp_next is None:
            if m is None:
                print("  [unknown module]")
                break
            # No RUNTIME_FUNCTION covers this RIP: treat as a leaf function,
            # where the return address sits directly at [RSP].
            rsp_next = rsp + 8
        rip = ret
        rsp = rsp_next


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
