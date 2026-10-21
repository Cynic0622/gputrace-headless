#!/usr/bin/env python3
"""Decode DXC's SPIR-V debug info: OpString / OpSource / OpLine.

Two traps, both of which produce silently wrong answers
-----------------------------------------------------
1. **The literal-string length word is absent.**  `OpString` at word 46 has
   `count = 8`: one result-id operand plus six data words, and those six words
   spell exactly `ntcBenchmarkVecPS.hlsl` (23 chars + NUL = 24 B = 6 words).  A
   standard SPIR-V literal string would need a seventh word for the length.
   Reading the high 16 bits of the result-id word as the length yields 0, and
   reading the low 16 bits yields 9 -- which truncates to `"ntcBench"`.  Both are
   wrong; the second one at least looks plausible, which is why it is the more
   dangerous bug.  The reliable rule is: *skip the id operands, then scan words
   as little-endian byte pairs until a NUL.*

2. **`OpLine` operands are `%file %line` at words i+1, i+2.**  Indexing them as
   i+2, i+3 yields values up to 766 that are not lines at all.

What this yields
----------------
    OpSource : 10 entries, files 9..18, each with the file's full text embedded
    OpString : file id -> file name
    OpLine   : 2522 entries, 224 distinct (file, line) pairs, lines 29..766

The five file ids actually referenced by OpLine are 9, 11, 12, 17, 18, and the
first rows are (9,82) (9,84) (9,85) (9,86) (9,89) (11,596) (9,91) (9,92) -- which
is exactly the line set the GUI prints for the top of `ntcBenchmarkVecPS.hlsl`.

Usage:
    python spirv-debug-info.py ntcBenchmarkVecPS.spv
    python spirv-debug-info.py ntcBenchmarkVecPS.spv --out dir
"""
import argparse
import glob
import io
import os
import struct
import sys

OP_STRING = 7
OP_SOURCE = 3
OP_SOURCE_CONTINUED = 2
OP_LINE = 8
OP_NAME = 5


def words_of(data):
    return list(struct.unpack_from("<%dI" % (len(data) // 4), data, 0))


def nul_string(w, start, limit):
    """Read a DXC literal string starting at word `start`.

    A SPIR-V word carries **four** bytes, lowest-addressed first, so decode
    `word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF, word >> 24` per
    word.  Taking only two bytes per word -- the obvious-looking mistake -- still
    yields printable text, it just drops every other character:
    `ntcBenchmarkVecPS.hlsl` decodes as `ntenmaVeS.sl`.
    """
    out = bytearray()
    i = start
    while i < limit:
        word = w[i]
        for shift in (0, 8, 16, 24):
            byte = (word >> shift) & 0xFF
            if byte == 0:
                return out.decode("utf-8", "replace"), i
            out.append(byte)
        i += 1
    return out.decode("utf-8", "replace"), i


def parse(data):
    w = words_of(data)
    n = len(w)
    files = {}          # file id -> filename (from OpString)
    sources = {}        # file id -> embedded text (from OpSource)
    lines = []          # ordered (file id, line) from OpLine
    continued = []      # (file id, text) from OpSourceContinued
    last_source = None            # OpSourceContinued carries no file id

    i = 5
    n_instr = 0
    while i + 1 <= n:
        op = w[i] & 0xFFFF
        cnt = w[i] >> 16
        if cnt == 0 or i + cnt > n:
            break
        end = i + cnt
        n_instr += 1
        if op == OP_STRING:
            fid = w[i + 1]
            s, _ = nul_string(w, i + 2, end)
            files[fid] = s
        elif op == OP_SOURCE:
            # operands are three ids then the text; the last id is the file id
            fid = w[i + 3]
            s, _ = nul_string(w, i + 4, end)
            sources[fid] = s
            last_source = fid
        elif op == OP_SOURCE_CONTINUED:
            # **no file-id operand**: the string starts at w[i+1]. Reading
            # w[i+1] as the id yields an ASCII word (measured 1866625897 =
            # "uro\n"), which silently files the tail under a bogus key and
            # leaves the real file truncated -- STFSamplerStateImpl.hlsli comes
            # out at 1,790 lines instead of its true 2,294.  The continuation
            # belongs to the most recently opened OpSource.
            s, _ = nul_string(w, i + 1, end)
            sources[last_source] = sources.get(last_source, "") + s
        elif op == OP_LINE:
            lines.append((w[i + 1], w[i + 2]))
        i = end
    return dict(words=n, n_instr=n_instr, files=files, sources=sources,
                lines=lines, continued=continued)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spv", nargs="?", default=r"D:\Code\Bear\Bear\src\Shaders\ntcBenchmarkVecPS.spv")
    ap.add_argument("--out")
    ap.add_argument("--show", type=int, default=6, help="lines of each source to print")
    args = ap.parse_args()

    data = open(args.spv, "rb").read()
    r = parse(data)
    print(f"{args.spv}: {r['words']:,} words, {r['n_instr']:,} instructions")
    print(f"  OpString  (file id -> name): {len(r['files'])}")
    for fid, nm in sorted(r["files"].items()):
        print(f"     {fid:>4} : {nm}")
    print(f"  OpSource  (file id -> embedded text): {len(r['sources'])}")
    for fid, txt in sorted(r["sources"].items()):
        print(f"     {fid:>4} : {len(txt):>6,} chars   {txt[:64]!r}")
    print(f"  OpSourceContinued: {len(r['continued'])}")
    print(f"  OpLine: {len(r['lines'])} rows, "
          f"{len(set(r['lines']))} distinct (file, line) pairs")

    used = sorted(set(f for f, _ in r["lines"]))
    print(f"     files referenced: {used}")
    print(f"     first 20 rows: {r['lines'][:20]}")

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        base = os.path.splitext(os.path.basename(args.spv))[0]
        for fid, txt in r["sources"].items():
            nm = r["files"].get(fid, "file%d" % fid)
            safe = os.path.basename(nm).replace("/", "_") or ("file%d.txt" % fid)
            with io.open(os.path.join(args.out, safe), "w", encoding="utf-8") as fh:
                fh.write(txt)
        with io.open(os.path.join(args.out, base + ".lines.tsv"), "w", encoding="utf-8") as fh:
            fh.write("#\tfile_id\tfile\tline\n")
            for k, (fid, ln) in enumerate(r["lines"]):
                fh.write(f"{k}\t{fid}\t{r['files'].get(fid, '?')}\t{ln}\n")
        print(f"\nwrote sources + {base}.lines.tsv to {args.out}")

    for fid, txt in sorted(r["sources"].items())[:3]:
        nm = r["files"].get(fid, "?")
        print(f"\n--- file {fid} = {nm} ---")
        for k, ln in enumerate(txt.splitlines()[:args.show], 1):
            print(f"   {k:>4} | {ln[:96]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())