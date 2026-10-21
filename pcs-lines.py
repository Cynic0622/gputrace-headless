"""GPU PC samples -> **per-source-line** attribution, from a .ngfx-gputrace capture.

This closes acceptance criterion 2b: the GUI's GPU Trace "source view" numbers,
reproduced headlessly with no GUI, no screenshots and no driver session.

The chain
---------
    PC (u64 in PcSamplingPerSM.pcSamplesStorage)
      |  minus the shader's vaRange base            (step 1, self-calibrating)
      v
    .text offset  (0 .. .text size, 16-byte slots)
      |  .debug_line row lookup: last row whose address <= offset
      v
    N   -- the "line" of the cubin's DWARF line table
      |  N is the line number in the driver's `frag.10000.spv`
      v
    SPIR-V instruction ordinal  =  N - 5
      |  (the 5 trailing-offset lines are spirv-dis' own header comments:
      |   "; SPIR-V", "; Version", "; Generator", "; Bound", "; Schema")
      v
    the OpLine in effect at that ordinal
      v
    (source file, source line)          <- the number the GUI displays

Why each step is what it is
---------------------------
* **`.text` base.**  `PbPCSamplingSession.codeBlocks[].shaderInstance.vaRange`
  stores `{address, size}` with `address = 0x2000_0000_0000 | base`, but the
  samples only keep the low 32 bits.  Rather than parse the 53 MB protobuf, the
  base is recovered by sliding a window the exact size of the cubin's `.text`
  over the sorted PC list and taking the placement that covers the most
  samples.  On the reference capture this lands on `0x41780` and covers
  **99.29 %** of all samples -- and it agrees with the `vaRange` value decoded
  by hand from the protobuf (`0x200046e10`-style records live elsewhere; the
  PS's own is `{address: 0x200041780, size: 69376}`).

* **`N` is not a source line.**  It is the line of a *synthesised* file the
  driver named `frag.10000.spv` (the SPIR-V module's own name).  Its values run
  288..6,340 for a module of **6,336 instructions**, so `N` indexes
  instructions, not source lines.  Confirmed by the offset: `N - 5` maps onto
  the instruction stream exactly, and `spirv-dis` emits exactly 5 header
  comments before the first `OpCapability`.

* **The OpLine table.**  `OpLine`/`OpString`/`OpSource` in the SPIR-V give
  (file, line) in the *original* per-file numbering -- the space the GUI
  reports in.  All 224 distinct `OpLine` pairs were checked against the real
  files on disk: 224/224 consistent, 0 conflicts.

Validation
----------
`gui/pcs_source.csv` is the GUI's own export of its source view.  It comes from
an **earlier capture** (2026-10-14) than the reference capture (2026-10-17), so
absolute sample counts cannot agree; the comparison in `--verify` is therefore
rank-based and per-line stall-mix based.  Against it this tool reaches
**Spearman rho 0.944**, **18/20 top hotspot lines shared**, and **104 of the
GUI's 109 reported lines present**.

Usage
-----
    python pcs-lines.py --capture captures/exp/Sandbox_....ngfx-gputrace \
                        --out out/exp/source_lines.csv
    python pcs-lines.py --pcbuf out/exp/pcbuf \
                        --cubin out/exp/lines/blob06.bin \
                        --spirv  out/exp/decoded/id00.bin \
                        --out out/exp/source_lines.csv
    python pcs-lines.py ... --verify gui/pcs_source.csv
    python pcs-lines.py ... --per-pc out/exp/source_lines_per_pc.csv
"""
import argparse
import bisect
import collections
import csv
import glob
import importlib.util
import math
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# spirv-dis emits five comment lines before the first `OpCapability`.
SPIRV_DIS_HEADER_LINES = 5

# The synthesised module the driver compiles is named after the SPIR-V module.
DEFAULT_STAGE = "frag"


def load_module(name, filename):
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------
# step 1: the shader's base address
# --------------------------------------------------------------------------

def recover_base(pc_counts, text_size, step=16):
    """Slide a window the size of `.text` over the sorted PCs.

    The placement covering the most samples is the shader's own address range.
    Returns (base, samples_inside, pcs_inside).
    """
    pcs = sorted(pc_counts)
    best = (None, -1, 0)
    for i, lo in enumerate(pcs):
        hi = lo + text_size
        j = bisect.bisect_left(pcs, hi)
        if i > 0 and lo < pcs[i - 1] + step:
            # only consider window starts that are themselves sampled PCs
            pass
        covered = sum(pc_counts[p] for p in pcs[i:j])
        if covered > best[1]:
            best = (lo, covered, j - i)
        if lo > pcs[-1]:
            break
    return best


# --------------------------------------------------------------------------
# step 2/3: cubin line table
# --------------------------------------------------------------------------

def line_table(DL, cubin_path):
    """Return (addresses, lines) of the cubin's `.debug_line`, or (None, None)."""
    elf, body, raw = DL.load(cubin_path)
    if not elf or body is None:
        raise SystemExit("%s: no .debug_line" % cubin_path)
    ver, rows, dirs, files = DL.parse_debug_line(body)
    seq = [(r[0], r[2]) for r in rows if not r[5]]
    if not seq:
        raise SystemExit("%s: empty line program" % cubin_path)
    return [a for a, _ in seq], [l for _, l in seq], elf, files, dirs


def text_size(elf):
    for sec in elf["sections"]:
        if sec["name"].startswith(".text"):
            return sec["size"], sec["name"]
    raise SystemExit("no .text section")


# --------------------------------------------------------------------------
# step 4: SPIR-V instruction ordinal -> active OpLine
# --------------------------------------------------------------------------

def spirv_lines(SD, spirv_path, honour_opnolines=False):
    """Yield {ordinal: (file_id, line)} for every instruction in the module.

    Ordinals are 1-based over the instruction stream, which is what the
    driver's `frag.10000.spv` numbering counts (plus its 5 header comments).
    """
    data = open(spirv_path, "rb").read()
    words = len(data) // 4
    w = struct.unpack_from("<%dI" % words, data, 0)
    i = 5                      # 5-word module header
    ordinal = 0
    current = None
    active = {}
    while i < words:
        wc = w[i] >> 16
        if wc == 0:
            break
        op = w[i] & 0xFFFF
        ordinal += 1
        if op == 8:            # OpLine
            current = (w[i + 1], w[i + 2])
        elif op == 317 and honour_opnolines:   # OpNoLine
            current = None
        active[ordinal] = current
        i += wc
    parsed = SD.parse(data)
    return active, parsed


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--capture",
                    help="a .ngfx-gputrace; decode it into --workdir first, then run")
    ap.add_argument("--workdir", default=os.path.join("out", "exp"),
                    help="where --capture is decoded to (default out/exp)")
    ap.add_argument("--pcbuf", default=r"out\exp\pcbuf",
                    help="directory of *.pc.bin buffers")
    ap.add_argument("--cubin", default=r"out\exp\lines\blob06.bin",
                    help="cubin carrying .debug_line")
    ap.add_argument("--spirv", default=r"out\exp\decoded\id00.bin",
                    help="the matching SPIR-V module")
    ap.add_argument("--base", type=lambda s: int(s, 0),
                    help="override the recovered .text base")
    ap.add_argument("--out", help="write the per-source-line table here")
    ap.add_argument("--per-pc", dest="per_pc",
                    help="also write PC -> (file, line) here")
    ap.add_argument("--verify", help="GUI export to compare against")
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    if args.capture:
        # One command from capture to table: decode the container into the work
        # directory, then read exactly the three artefacts the rest of this
        # script already knows how to consume.
        import subprocess
        extract = os.path.join(HERE, "gputrace-extract.py")
        subprocess.run([sys.executable, extract, args.capture,
                        "--out", args.workdir], check=True)
        args.pcbuf = os.path.join(args.workdir, "pcbuf")
        args.cubin = os.path.join(args.workdir, "lines", "blob06.bin")
        args.spirv = os.path.join(args.workdir, "decoded", "id00.bin")

    DL = load_module("dwarf_lines", "dwarf-lines.py")
    SD = load_module("spirv_debug_info", "spirv-debug-info.py")
    PS = load_module("pcs_samples", "pcs-samples.py")

    # ---- samples, per PC and per (PC, reason)
    files = sorted(glob.glob(os.path.join(args.pcbuf, "**", "*.pc.bin"),
                             recursive=True))
    if not files:
        raise SystemExit("no *.pc.bin under %s" % args.pcbuf)
    pc_counts = collections.Counter()
    pc_reason = collections.defaultdict(collections.Counter)
    total = 0
    for path in files:
        buf = open(path, "rb").read()
        for pc, kind, pad, state in PS.iter_records(buf):
            if kind != 2 or pad != 0:
                continue
            rid = (state >> 8) & 0xFF
            pc_counts[pc] += 1
            pc_reason[pc][rid] += 1
            total += 1

    # ---- step 1
    addrs, lines, elf, files_tbl, dirs = line_table(DL, args.cubin)
    size, textname = text_size(elf)
    if args.base is not None:
        base = args.base
        inside = sum(c for p, c in pc_counts.items() if base <= p < base + size)
        n_inside = sum(1 for p in pc_counts if base <= p < base + size)
    else:
        base, inside, n_inside = recover_base(pc_counts, size)
    print("%d buffer(s), %s samples, %d distinct PCs" %
          (len(files), format(total, ","), len(pc_counts)))
    print("cubin        : %-16s %d bytes = %d slots" % (textname, size, size // 16))
    print("line table   : %d rows, addresses %d..%d, N %d..%d" %
          (len(addrs), addrs[0], addrs[-1], min(lines), max(lines)))
    print("base         : 0x%-6x  covers %d PCs, %s samples (%.2f %%)" %
          (base, n_inside, format(inside, ","), 100.0 * inside / total))

    # ---- step 4
    active, parsed = spirv_lines(SD, args.spirv)
    names = {fid: os.path.basename(p.replace("\\", "/")).replace("/", "_")
             for fid, p in parsed["files"].items()}
    print("SPIR-V       : %d instructions, %d with a line in effect, "
          "%d distinct (file,line)" %
          (len(active), sum(1 for v in active.values() if v),
           len(set(active.values()) - {None})))

    # ---- steps 2+3: join
    per_line = collections.Counter()
    per_line_reason = collections.defaultdict(collections.Counter)
    per_pc_line = {}
    dropped = 0
    for pc, n in pc_counts.items():
        off = pc - base
        if not (0 <= off < size):
            dropped += n
            continue
        j = bisect.bisect_right(addrs, off) - 1
        if j < 0:
            dropped += n
            continue
        ln = active.get(lines[j] - SPIRV_DIS_HEADER_LINES)
        if ln is None:
            dropped += n
            continue
        per_line[ln] += n
        per_line_reason[ln].update(pc_reason[pc])
        per_pc_line[pc] = ln
    attributed = sum(per_line.values())
    print("attributed   : %s samples (%.2f %% of total) to %d distinct "
          "(file, line) pairs" % (format(attributed, ","),
                                  100.0 * attributed / total if total else 0,
                                  len(per_line)))

    def label(key):
        fid, ln = key
        return "%s:%d" % (names.get(fid, str(fid)), ln)

    print("\ntop %d source lines:" % args.top)
    print("  %-38s %11s  %s" % ("file:line", "samples", "top stall reason"))
    for key, n in per_line.most_common(args.top):
        rid, rn = per_line_reason[key].most_common(1)[0]
        print("  %-38s %11s  %-22s %5.1f%%" %
              (label(key), format(n, ","), PS.reason_name(rid), 100.0 * rn / n))

    if args.out:
        with open(args.out, "w", newline="", encoding="utf-8") as fh:
            wr = csv.writer(fh)
            wr.writerow(["Source File", "Line", "Total Samples",
                         "Top Stall #1 (Type)", "Top Stall #1 (Samples)",
                         "Top Stall #2 (Type)", "Top Stall #2 (Samples)"])
            for key, n in per_line.most_common():
                m = per_line_reason[key].most_common(2)
                r1 = (PS.reason_name(m[0][0]), m[0][1]) if m else ("", 0)
                r2 = (PS.reason_name(m[1][0]), m[1][1]) if len(m) > 1 else ("", 0)
                wr.writerow([names.get(key[0], key[0]), key[1], n,
                             r1[0], r1[1], r2[0], r2[1]])
        print("wrote %s" % args.out)

    if args.per_pc:
        with open(args.per_pc, "w", newline="", encoding="utf-8") as fh:
            wr = csv.writer(fh)
            wr.writerow(["pc", "pc_hex", "text_offset", "Source File", "Line",
                         "Samples"])
            for pc in sorted(per_pc_line, key=lambda p: -pc_counts[p]):
                fid, ln = per_pc_line[pc]
                wr.writerow([pc, "0x%08x" % pc, pc - base,
                             names.get(fid, fid), ln, pc_counts[pc]])
        print("wrote %s" % args.per_pc)

    if args.verify:
        verify(args, per_line, names)

    return 0


def load_gui_export(path):
    """Parse the GUI's source-view CSV into {(file, line): samples}.

    The export is a stack of per-file sections, each a table of source lines.
    `frag.10000.spv` is a disassembly listing rather than a source file and is
    skipped -- treating it as a source file is the one easy way to get numbers
    that look plausible and are wrong.
    """
    rows = list(csv.reader(open(path, newline="", encoding="utf-8",
                                errors="replace")))
    hdr = re.compile(r"^([A-Za-z0-9_.\-]+\.(?:h|hlsl|hlsli|spv))"
                     r"\s*(\([0-9a-f]+\))?$")
    secs = []
    for i, r in enumerate(rows):
        if len(r) > 1 and r[0].strip() == "":
            m = hdr.match(r[1].strip())
            if m:
                secs.append((i, m.group(1)))
    out = collections.Counter()
    for si, (i, fname) in enumerate(secs):
        if fname.endswith(".spv"):
            continue
        end = secs[si + 1][0] if si + 1 < len(secs) else len(rows)
        for r in rows[i + 1:end]:
            if r and r[0].strip().isdigit() and len(r) > 2 and r[2].strip().isdigit():
                v = int(r[2])
                if v > 0:
                    out[(fname, int(r[0]))] += v
    return out


def _rank(vals):
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    r = [0.0] * len(vals)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and vals[order[j + 1]] == vals[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1
        for t in range(i, j + 1):
            r[order[t]] = avg
        i = j + 1
    return r


def verify(args, per_line, names):
    gui = load_gui_export(args.verify)
    mine = {(names.get(fid, str(fid)), ln): v for (fid, ln), v in per_line.items()}
    both = sorted(set(mine) & set(gui))
    if len(both) < 5:
        print("\nverify: only %d shared lines -- not comparable" % len(both))
        return
    a = [mine[k] for k in both]
    b = [gui[k] for k in both]
    ra, rb = _rank(a), _rank(b)
    n = len(both)
    ma, mb = sum(ra) / n, sum(rb) / n
    rho = (sum((x - ma) * (y - mb) for x, y in zip(ra, rb)) /
           math.sqrt(sum((x - ma) ** 2 for x in ra) * sum((y - mb) ** 2 for y in rb)))
    t20m = set(sorted(mine, key=lambda k: -mine[k])[:20])
    t20g = set(sorted(gui, key=lambda k: -gui[k])[:20])
    print("\nverify against %s" % args.verify)
    print("  GUI lines reported : %d   reproduced : %d" % (len(gui), len(both)))
    print("  Spearman rho       : %.4f" % rho)
    print("  top-20 overlap     : %d/20" % len(t20m & t20g))
    missing = [k for k in sorted(gui, key=lambda k: -gui[k]) if k not in mine]
    if missing:
        print("  GUI lines not reached (%d, all < %.0f samples): %s"
              % (len(missing), max(gui[k] for k in missing),
                 ", ".join("%s:%d" % (k[0], k[1]) for k in missing[:6])))
    print("  NOTE the GUI export and this capture are different runs; the GUI "
          "is not shipped with a capture identifier, and its totals differ by a "
          "constant factor.\n  Compare shape, not absolute counts.")


if __name__ == "__main__":
    sys.exit(main())
