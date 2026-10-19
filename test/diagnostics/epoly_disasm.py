"""Disassemble EPoly.dlo around the crash return address (0xe0930)."""
import struct
import sys

import capstone

DLL = r"C:\Program Files\Autodesk\3ds Max 2020\stdplugs\EPoly.dlo"
TARGET = 0xE0930
BACK = 0x200

data = open(DLL, "rb").read()
pe_off = struct.unpack_from("<I", data, 0x3C)[0]
num_sections = struct.unpack_from("<H", data, pe_off + 6)[0]
size_opt = struct.unpack_from("<H", data, pe_off + 20)[0]
sections = []
sec_off = pe_off + 24 + size_opt
for i in range(num_sections):
    name = data[sec_off + i * 40: sec_off + i * 40 + 8].rstrip(b"\0").decode()
    vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, sec_off + i * 40 + 8)
    sections.append((name, vaddr, vsize, rawptr, rawsize))
print("sections:", [(n, hex(v), hex(vs)) for n, v, vs, rp, rs in sections])

def rva_to_off(rva):
    for name, vaddr, vsize, rawptr, rawsize in sections:
        if vaddr <= rva < vaddr + max(vsize, rawsize):
            return rawptr + (rva - vaddr)
    return None

off = rva_to_off(TARGET)
print("RVA 0x%x -> file offset 0x%x" % (TARGET, off))
start = off - BACK
code = data[start:off + 32]
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = False
for insn in md.disasm(code, TARGET - BACK):
    mark = "  <=== crash return address" if insn.address == TARGET else ""
    print("0x%08x  %-24s %s%s" % (insn.address, insn.mnemonic, insn.op_str, mark))
    if insn.address > TARGET + 16:
        break
