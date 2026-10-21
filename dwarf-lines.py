#!/usr/bin/env python3
"""Standalone DWARF line-program reader for Nsight cubins -- no dependencies.

Scope
-----
Reads an NVIDIA cubin (ELF64, e_machine 0xBE), applies its `.rel.debug_line`
relocations, and parses the DWARF v2 line program into
(address, file, line, column, is_stmt, end_sequence) rows.

Why standalone
--------------
The rest of the toolchain needs protobuf and LZ4; this does not.  Keeping the
line reader dependency-free means the SASS-to-source step can always be checked,
re-verified and cited even when the surrounding environment is incomplete.

The bug this file exists to keep fixed
--------------------------------------
`header_length` in a DWARF line header counts the bytes *after* the
header_length field itself, so the line program begins at

    4 (unit_length) + 2 (version) + 4 (header_length) + header_length

Using `4 + header_length` slips 6 bytes, desynchronises the opcode stream and
sends line numbers into the millions -- which makes a perfectly good table look
like garbage.  On Nsight's blob 6 the header reads

    unit_length 0x4141 = 16705   (section is 16709 B, i.e. +4 for the field)
    version 2, header_length 89, min_inst 1, default_is_stmt 1,
    line_base 0xfb (-5), line_range 14, opcode_base 10

all stock defaults, which is how to recognise it.  The include_directories list
carries Nsight's own `key>value` metadata as one path, e.g.
`./"stage>ps"fmt>spir"ShaderModuleHash>2ae821dff52be87b`, and file_names[1] is
`frag.10000.spv`.

Usage:
    python dwarf-lines.py out/exp/lines/blob06.bin
    python dwarf-lines.py out/exp/lines/blob06.bin --dump rows.tsv
"""
import argparse
import struct
import sys

ELF = b"\x7fELF"

DW_LNS_copy = 1
DW_LNS_advance_pc = 2
DW_LNS_advance_line = 3
DW_LNS_set_file = 4
DW_LNS_set_column = 5
DW_LNS_negate_stmt = 6
DW_LNS_set_basic_block = 7
DW_LNS_const_add_pc = 8
DW_LNS_fixed_advance_pc = 9
DW_LNS_set_prologue_end = 10
DW_LNS_set_epilogue_begin = 11
DW_LNS_set_isa = 12

DW_LNE_end_sequence = 1
DW_LNE_set_address = 2
DW_LNE_define_file = 3


# --------------------------------------------------------------------- ELF
def parse_elf(d):
    """Return {name: section} plus the symbol table.  None if not ELF64."""
    if len(d) < 64 or d[:4] != ELF or d[4] != 2 or d[5] != 1:
        return None
    e_machine, = struct.unpack_from("<H", d, 18)
    e_shoff, = struct.unpack_from("<Q", d, 40)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 58)
    if e_shoff == 0 or e_shnum == 0:
        return None
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        if o + 64 > len(d):
            return None
        (nm, ty, fl, addr, off, size, link, info, align, ent) = \
            struct.unpack_from("<IIQQQQIIQQ", d, o)
        secs.append(dict(name_off=nm, type=ty, flags=fl, addr=addr, off=off,
                         size=size, link=link, info=info, entsize=ent))
    stro = secs[e_shstrndx]["off"]

    def name_at(x):
        o = stro + x
        z = d.index(b"\0", o)
        return d[o:z].decode("latin1")

    for s in secs:
        s["name"] = name_at(s["name_off"])

    syms = []
    for s in secs:
        if s["type"] == 2 and s["name"] == ".symtab":
            strt = secs[s["link"]]["off"]
            for k in range(s["size"] // 24):
                o = s["off"] + k * 24
                if o + 24 > len(d):
                    break
                st_name, st_info, st_other, st_shndx, st_value, st_size = \
                    struct.unpack_from("<IBBHQQ", d, o)
                z = d.index(b"\0", strt + st_name)
                syms.append(dict(name=d[strt + st_name:z].decode("latin1"),
                                 shndx=st_shndx, value=st_value, size=st_size))
    return dict(machine=e_machine, sections=secs, syms=syms,
                by_name={s["name"]: s for s in secs})


def relocate_debug_line(elf, d):
    """`.debug_line` is stored with sh_addr = 0; the `.text` base lives in
    `.rel.debug_line`, whose entries index `.symtab`.  Without this every line
    row would be anchored at address zero."""
    dl = elf["by_name"].get(".debug_line")
    if not dl:
        return None
    for rname, is_rela in ((".rela.debug_line", True), (".rel.debug_line", False)):
        r = elf["by_name"].get(rname)
        if not r or not r["size"]:
            continue
        out = bytearray(d[dl["off"]:dl["off"] + dl["size"]])
        step = r["entsize"] or (24 if is_rela else 16)
        for k in range(r["size"] // step):
            o = r["off"] + k * step
            if is_rela:
                r_offset, r_info, r_addend = struct.unpack_from("<QQq", d, o)
            else:
                r_offset, r_info = struct.unpack_from("<QQ", d, o)
                r_addend = 0
            sym = r_info >> 32
            if sym >= len(elf["syms"]):
                continue
            val = elf["syms"][sym]["value"]
            if val and r_offset + 8 <= len(out):
                struct.pack_into("<Q", out, r_offset, val + r_addend)
        return bytes(out)
    return None


# -------------------------------------------------------------------- DWARF
def _u8(b, i):
    return b[i], i + 1


def _uleb(b, i):
    r = 0
    s = 0
    while True:
        x, i = _u8(b, i)
        r |= (x & 0x7F) << s
        if not x & 0x80:
            return r, i
        s += 7


def _sleb(b, i):
    r = 0
    s = 0
    while True:
        x, i = _u8(b, i)
        r |= (x & 0x7F) << s
        s += 7
        if not x & 0x80:
            if x & 0x40:
                r -= (1 << s)
            return r, i


def _cstr(b, i):
    z = b.index(b"\0", i)
    return b[i:z].decode("utf-8", "replace"), z + 1


def parse_debug_line(b):
    """Return (version, rows, dirs, files).

    rows: list of (address, file_index, line, column, is_stmt, end_sequence)
    """
    unit_len = struct.unpack_from("<I", b, 0)[0]
    i = 4
    ver = struct.unpack_from("<H", b, i)[0]
    i += 2
    if ver >= 5:
        addr_size = b[i]
        i += 1
        i += 1                       # segment_selector_size
    else:
        addr_size = 8                # these cubins are ELF64
    hdr_len = struct.unpack_from("<I", b, i)[0]
    i += 4
    prog_start = i + hdr_len        # <- the 6-byte slip lives here

    if ver >= 4:
        min_inst = b[i]
        default_is_stmt = b[i + 2]
        line_base = b[i + 3] - 256 if b[i + 3] > 127 else b[i + 3]
        line_range = b[i + 4]
        opcode_base = b[i + 5]
        i += 6
    else:
        min_inst = b[i]
        default_is_stmt = b[i + 1]
        # `line_base` is a *single* signed byte, not a SLEB128. Reading it as
        # SLEB is catastrophic and silent: 0xfb has its high bit set, so SLEB
        # treats it as a continuation byte, swallows `line_range` as its second
        # byte, and yields +1915 instead of -5. Every special opcode then adds
        # 1915 rather than -5, inflating each line by exactly 1920 -- which is
        # why the table appeared to advance by a constant stride of 1928
        # (1920 + 8) and looked like an index rather than a source line.
        line_base = b[i + 2] - 256 if b[i + 2] > 127 else b[i + 2]
        line_range = b[i + 3]
        opcode_base = b[i + 4]
        i += 5
    std_lens = []
    for _ in range(opcode_base - 1):
        v, i = _u8(b, i)
        std_lens.append(v)

    dirs = []
    files = ["<none>"]
    if ver >= 5:
        dfmt_cnt = b[i]
        i += 1
        i += dfmt_cnt
        dcount, i = _uleb(b, i)
        for _ in range(dcount):
            s, i = _cstr(b, i)
            dirs.append(s)
    else:
        while b[i] != 0:
            s, i = _cstr(b, i)
            dirs.append(s)
        i += 1
    if ver >= 5:
        ffmt_cnt = b[i]
        i += 1
        i += ffmt_cnt
        fcount, i = _uleb(b, i)
        for _ in range(fcount):
            s, i = _cstr(b, i)
            dirs.append(s)
            files.append(s)
    else:
        while b[i] != 0:
            s, i = _cstr(b, i)
            _, i = _uleb(b, i)        # directory index
            _, i = _uleb(b, i)        # mtime
            _, i = _uleb(b, i)        # length
            files.append(s)
        i += 1

    rows = []
    addr = 0
    fidx = 1
    line = 1
    col = 0
    is_stmt = default_is_stmt
    p = prog_start
    end = 4 + unit_len
    if end > len(b):
        end = len(b)

    def emit(ends):
        rows.append((addr, fidx, line, col, is_stmt, 1 if ends else 0))

    while p < end:
        op = b[p]
        p += 1
        if op >= opcode_base:                      # special opcode
            adj = op - opcode_base
            addr += (adj // line_range) * min_inst
            line += line_base + (adj % line_range)
            emit(False)
        elif op == 0:                               # extended opcode
            ln, p = _uleb(b, p)
            # ln covers every byte after the length field, including the
            # sub-opcode byte, so resume at p + ln rather than guessing.
            ext_end = p + ln
            sub = b[p]
            p += 1
            if sub == DW_LNE_end_sequence:
                emit(True)
                addr = 0
                fidx = 1
                line = 1
                col = 0
                is_stmt = default_is_stmt
            elif sub == DW_LNE_set_address:
                addr = int.from_bytes(b[p:p + addr_size], "little")
                p += addr_size
            elif sub == DW_LNE_define_file:
                s, p = _cstr(b, p)
                p += 9
                files.append(s)
            p = ext_end
        elif op == DW_LNS_copy:
            emit(False)
        elif op == DW_LNS_advance_pc:
            adv, p = _uleb(b, p)
            addr += adv * min_inst
        elif op == DW_LNS_advance_line:
            adv, p = _sleb(b, p)
            line += adv
        elif op == DW_LNS_set_file:
            v, p = _uleb(b, p)
            fidx = v
        elif op == DW_LNS_set_column:
            v, p = _uleb(b, p)
            col = v
        elif op == DW_LNS_negate_stmt:
            is_stmt = not is_stmt
        elif op == DW_LNS_set_basic_block:
            pass
        elif op == DW_LNS_const_add_pc:
            adj = 255 - opcode_base
            addr += (adj // line_range) * min_inst
        elif op == DW_LNS_fixed_advance_pc:
            v = struct.unpack_from("<H", b, p)[0]
            p += 2
            addr += v
        elif op in (DW_LNS_set_prologue_end, DW_LNS_set_epilogue_begin):
            pass
        elif op == DW_LNS_set_isa:
            _, p = _uleb(b, p)
        else:
            for _ in range(std_lens[op - 1] if 0 < op - 1 < len(std_lens) else 0):
                _, p = _uleb(b, p)
    return ver, rows, dirs, files


def load(cubin_path):
    """Convenience: bytes -> (elf, relocated .debug_line bytes)."""
    d = open(cubin_path, "rb").read()
    elf = parse_elf(d)
    if elf is None:
        return None, None, None
    dl = elf["by_name"].get(".debug_line")
    if not dl:
        return elf, None, None
    body = relocate_debug_line(elf, d) or d[dl["off"]:dl["off"] + dl["size"]]
    return elf, body, d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cubin")
    ap.add_argument("--dump")
    ap.add_argument("--rows", type=int, default=12)
    args = ap.parse_args()

    elf, body, raw = load(args.cubin)
    if elf is None:
        print(f"{args.cubin}: not an ELF64 cubin")
        return 1
    print(f"{args.cubin}: ELF64 machine=0x{elf['machine']:x} "
          f"shnum={len(elf['sections'])} syms={len(elf['syms'])}")
    for s in elf["sections"]:
        if s["name"] and not s["name"].startswith("."):
            pass
        if s["name"]:
            print(f"   {s['name']:<24} type={s['type']:<11} off={s['off']:<9} "
                  f"size={s['size']}")
    if body is None:
        print("   (no .debug_line)")
        return 0

    ver, rows, dirs, files = parse_debug_line(body)
    real = [r for r in rows if not r[5]]
    ln = sorted(set(r[2] for r in real))
    print(f"\nDWARF v{ver}: {len(rows)} rows ({len(real)} non-end), "
          f"{len(set(r[0] for r in real))} distinct addresses")
    if ln:
        print(f"   line range {ln[0]}..{ln[-1]}  distinct={len(ln)}  "
              f"median={ln[len(ln) // 2]}")
    print(f"   dirs={dirs}")
    print(f"   files={files}")
    print("\n   first rows (addr -> file:line):")
    for r in real[:args.rows]:
        f = files[r[1]] if 0 < r[1] < len(files) else str(r[1])
        print(f"     0x{r[0]:06x} -> {f}:{r[2]}  col={r[3]} stmt={r[4]}")

    if args.dump:
        with open(args.dump, "w", encoding="utf-8") as fh:
            fh.write("# addr\tfile\tline\tcol\tstmt\tend\n")
            for r in sorted(rows):
                f = files[r[1]] if 0 < r[1] < len(files) else str(r[1])
                fh.write(f"0x{r[0]:x}\t{f}\t{r[2]}\t{r[3]}\t{int(r[4])}\t{r[5]}\n")
        print(f"\nwrote {args.dump}")
    return 0


if __name__ == "__main__":
    sys.exit(main())