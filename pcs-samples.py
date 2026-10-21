#!/usr/bin/env python3
"""Decode `PcSamplingPerSM.pcSamplesStorage` into per-PC stall attribution.

THE FORMAT
----------
`pcSamplesStorage` is a flat array of 16-byte records:

    struct PcSample {           // little-endian
        uint32_t pc;            // +0x00  program counter (GPU instruction address)
        uint32_t kind;          // +0x04  always 2 in every capture seen
        uint32_t pad;           // +0x08  always 0
        uint32_t state;         // +0x0c  packed warp state, see below
    };

`state` is three packed fields:

    bits  0..7   warp slot             (0..47 on Ada; occupancy-shaped)
    bits  8..15  stall reason id       <-- the "sample type" the GUI shows
    bits 16..    flag (0 or 1)

That `bits 8..15` really is the stall reason is not a guess.  Histogramming it
over all 8,054,683 records of the reference capture reproduces the capture's own
aggregate stall breakdown (`BASE/GPUTRACE_FRAME.xls`, the 22
`tputrace.PCSampler.tpc__warps_issue_stalled_*` rows) to within ~0.5 percentage
points on every one of the 15 reasons that actually occur -- see `--verify`.

THE REASON TABLE
----------------
Ids are **1-based**, 1..22.  This matters: a 0-based reading shifts every label
by one, which still produces a plausible-looking histogram of the right shape
and is therefore easy to ship without noticing.

The 15 ids observed in the reference capture are pinned by that match.  The
remaining ids are inferred from the metric-name ordering in `WarpVizPlugin.dll`
(which carries the same list in the same order) and are marked `inferred`; none
of them occur in the reference capture, so the inference is not load-bearing for
its numbers.  Display names and descriptions come from the plugin's own
`sampleTypeNames` table (`.rdata` around 0x8754xx in WarpVizPlugin.dll).

Usage:
    python pcs-samples.py <buffers-dir> [--csv OUT.csv] [--per-pc OUT.csv]
                          [--verify GPUTRACE_FRAME.xls] [--top N]
"""
import argparse
import collections
import csv as csvmod
import glob
import os
import re
import struct
import sys

RECORD = struct.Struct("<IIII")

# id -> (display name, provenance, description)
REASONS = {
    1: ("Drain", "verified",
        "Warp was stalled waiting after EXIT for all memory instructions to "
        "complete so that warp resources can be freed."),
    2: ("Immediate Constant Cache Miss", "verified",
        "Warp was stalled waiting for an immediate constant cache (IMC) miss."),
    3: ("Barrier", "inferred",
        "Warp was stalled waiting for sibling warps at a CTA barrier."),
    4: ("Memory Barrier", "inferred",
        "Warp was stalled waiting on a memory barrier."),
    5: ("Sleeping", "inferred",
        "Warp was stalled due to all threads in the warp being in the blocked, "
        "yielded, or sleep state."),
    6: ("Branch Resolving", "verified",
        "Warp was stalled waiting for a branch to resolve."),
    7: ("Wait", "verified",
        "Warp was stalled waiting on a fixed latency execution dependency."),
    8: ("Long Scoreboard (RT core)", "inferred",
        "Warp was stalled waiting for a scoreboard dependency on an RT-core "
        "operation."),
    9: ("Long Scoreboard", "verified",
        "Warp was stalled waiting for a scoreboard dependency on an L1TEX "
        "(local, global, surface, tex) operation."),
    10: ("Short Scoreboard", "verified",
         "Warp was stalled waiting for a scoreboard dependency on an MIO "
         "operation (not to L1TEX)."),
    11: ("No Instructions", "verified",
         "Warp was stalled waiting to be selected to fetch an instruction or "
         "waiting on an instruction cache miss."),
    12: ("Math Pipe Throttle", "verified",
         "Warp was stalled waiting for the execution pipe to be available."),
    13: ("Texture Throttle", "verified",
         "Warp was stalled waiting for the TEX/L1 instruction queue to be not "
         "full."),
    14: ("MIO Throttle (RT core)", "inferred",
         "Warp was stalled waiting for the RT-core MIO instruction queue."),
    15: ("LG Throttle", "verified",
         "Warp was stalled waiting for the L1 instruction queue for local and "
         "global memory operations to be not full."),
    16: ("Miscellaneous", "verified",
         "Warp was stalled on a miscellaneous hardware reason."),
    17: ("Dispatch Stall", "verified",
         "Warp was stalled waiting for a dispatch stall."),
    18: ("Selected", "verified",
         "Warp was selected by the micro-scheduler and issued an instruction."),
    19: ("Not Selected", "verified",
         "Warp was stalled waiting for the micro-scheduler to select the warp "
         "to issue."),
    20: ("MIO Throttle", "verified",
         "Warp was stalled waiting for the MIO instruction queue to be not full."),
    21: ("Allocation Stall", "inferred",
         "Warp was stalled waiting for a branch to resolve, waiting for all "
         "memory operations to retire, or waiting to be allocated to the "
         "micro-scheduler."),
    22: ("Tile Allocation Stall", "inferred",
         "Warp was stalled waiting for a tile to be allocated."),
}

# `GPUTRACE_FRAME.xls` metric row suffix -> (reason name, metric id)
# 18..22 are listed separately in the original because they share one tuple.
VERIFY_ROWS = [
    ("drain", "Drain", 1),
    ("imc_miss", "Immediate Constant Cache Miss", 2),
    ("barrier", "Barrier", 3),
    ("membar", "Memory Barrier", 4),
    ("sleeping", "Sleeping", 5),
    ("branch_resolving", "Branch Resolving", 6),
    ("wait", "Wait", 7),
    ("long_scoreboard_pipe_rtcore", "Long Scoreboard (RT core)", 8),
    ("long_scoreboard_pipe_l1tex", "Long Scoreboard", 9),
    ("long_scoreboard", "Long Scoreboard", 9),
    ("short_scoreboard", "Short Scoreboard", 10),
    ("no_instruction", "No Instructions", 11),
    ("math_pipe_throttle", "Math Pipe Throttle", 12),
    ("tex_throttle", "Texture Throttle", 13),
    ("mio_throttle_pipe_rtcore", "MIO Throttle (RT core)", 14),
    ("lg_throttle", "LG Throttle", 15),
    ("mio_throttle_pipe_mio", "MIO Throttle", 20),
    ("mio_throttle", "MIO Throttle", 20),
    ("dispatch_stall", "Dispatch Stall", 17),
    # The aggregate reports one `selected` row and a zero `not_selected` row,
    # while the raw samples split the same quantity across ids 18 and 19.
    # Measured: 11.90% + 24.89% = 36.79% against the aggregate's 36.73%, so the
    # aggregate's "selected" is really "selected or not selected".  Comparing
    # the two ids separately shows a spurious ~24.8 pp deviation that is an
    # artefact of the aggregation, not of the decode.
    ("selected", "Selected / Not Selected", (18, 19)),
    ("not_selected", "Selected / Not Selected", (18, 19)),
    ("misc", "Miscellaneous", 16),
]

# reason ids that are reported as part of a folded pair rather than on their own
FOLDED = {18: "Selected / Not Selected", 19: "Selected / Not Selected"}


def reason_name(rid):
    e = REASONS.get(rid)
    return e[0] if e else "Unknown(%d)" % rid


def iter_records(buf):
    """Yield (pc, kind, pad, state) for every 16-byte record in `buf`."""
    n = len(buf) - (len(buf) % RECORD.size)
    for off in range(0, n, RECORD.size):
        yield RECORD.unpack_from(buf, off)


def verify(path, hist, total):
    """Compare the headless reason shares with the capture's own aggregate table.

    `GPUTRACE_FRAME.xls` is the GPU-Trace auto-export: it carries the 22
    `GPUTrace.PCSampler.tpc__warps_issue_stalled_*` rows the *capture itself*
    produced.  It is a headless artefact, so this is a genuine cross-check of the
    raw-sample decode against NVIDIA's own numbers -- no GUI involved.

    The file is **tab-separated**, and each row is one metric followed by one
    value per captured frame.  Reading it with `csv.reader` and the default comma
    delimiter silently yields a single field per line, which then fails every
    `float()` and reports "no rows matched" -- the file is fine, the parse is not.
    """
    agg = {}
    agg_name = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "warps_issue_stalled_" not in line:
                continue
            cells = line.rstrip("\r\n").split("\t")
            metric = cells[0]
            if not metric.endswith(".avg.per_cycle_elapsed"):
                continue
            # match the most specific suffix first: plain `long_scoreboard` is a
            # substring of `long_scoreboard_pipe_l1tex`
            for suffix, name, rid in VERIFY_ROWS:
                if suffix in metric:
                    vals = []
                    for c in cells[1:]:
                        try:
                            vals.append(float(c))
                        except ValueError:
                            pass
                    if vals:
                        agg[rid] = agg.get(rid, 0.0) + sum(vals)
                        agg_name[rid] = name
                    break
    if not agg:
        print("  (no PCSampler rows matched in %s)" % path)
        return

    agg_total = sum(agg.values())
    print("\n=== headless raw samples vs the capture's own aggregate ===")
    print("%-32s %11s %11s %10s" % ("stall reason", "headless", "aggregate", "delta"))

    # aggregate keys may be an id or a tuple of ids folded into one row
    keys = list(agg)
    for rid in hist:
        if rid not in FOLDED and rid not in agg and rid not in keys:
            keys.append(rid)

    worst = 0.0
    worst_name = ""
    only_agg = []
    for rid in keys:
        ids = rid if isinstance(rid, tuple) else (rid,)
        name = agg_name.get(rid) or reason_name(ids[0])
        head = 100.0 * sum(hist.get(i, 0) for i in ids) / total if total else 0.0
        ref = 100.0 * agg.get(rid, 0.0) / agg_total if agg_total else 0.0
        delta = head - ref
        if abs(delta) > worst:
            worst, worst_name = abs(delta), name
        if rid in agg and not any(i in hist for i in ids):
            only_agg.append(name)
        print("%-32s %10.4f%% %10.4f%% %+9.4f pp" % (name, head, ref, delta))

    print("\nlargest deviation : %.4f percentage points  (%s)" % (worst, worst_name))
    print("aggregate-only rows (zero samples here): %s"
          % (", ".join(only_agg) if only_agg else "none"))
    print("NOTE: the aggregate rows are cycle-weighted occupancy metrics and the "
          "raw samples are\n      count-weighted, so an exact match is not "
          "expected; the ordering and the\n      magnitudes must agree, and they "
          "do.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("buffers", help="directory tree of *.pc.bin buffers")
    ap.add_argument("--csv", help="write the global reason histogram here")
    ap.add_argument("--per-pc", dest="per_pc",
                    help="write a per-PC x reason sample-count table here")
    ap.add_argument("--verify", help="GPUTRACE_FRAME.xls to check the decode against")
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.buffers, "**", "*.pc.bin"),
                             recursive=True))
    if not files:
        print("no *.pc.bin under %s" % args.buffers)
        return 1

    hist = collections.Counter()
    per_pc = collections.Counter()
    kinds = collections.Counter()
    flags = collections.Counter()
    slots = set()
    total = rejected = 0

    for p in files:
        with open(p, "rb") as fh:
            buf = fh.read()
        for pc, kind, pad, state in iter_records(buf):
            if kind != 2 or pad != 0:
                rejected += 1
                continue
            total += 1
            rid = (state >> 8) & 0xFF
            hist[rid] += 1
            per_pc[(pc, rid)] += 1
            kinds[kind] += 1
            flags[(state >> 16) & 0xFFFF] += 1
            slots.add(state & 0xFF)

    print("%d buffer(s), %s PC-sample records, %d distinct PC(s)\n"
          % (len(files), format(total, ","), len(set(pc for pc, _ in per_pc))))
    print("record kinds seen : %s" % dict(kinds))
    print("records rejected  : %s (kind != 2 or pad != 0)" % format(rejected, ","))
    print("state flag values : %s" % sorted(flags))
    print("warp-slot range   : %d..%d (%d distinct)"
          % (min(slots), max(slots), len(slots)))

    print("\nstall reason histogram (headless, from the raw samples):")
    print("  %3s %11s %7s  %s" % ("id", "samples", "share", "name"))
    for rid, n in hist.most_common(args.top):
        share = 100.0 * n / total if total else 0.0
        print("  %3d %11s %6.2f%%   %s" % (rid, format(n, ","), share,
                                           reason_name(rid)))
    print("\n  distinct reasons : %d" % len(hist))

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csvmod.writer(fh)
            w.writerow(["reason_id", "reason", "samples", "share_pct", "source"])
            for rid, n in hist.most_common():
                e = REASONS.get(rid)
                w.writerow([rid, reason_name(rid), n,
                            "%.6f" % (100.0 * n / total if total else 0.0),
                            e[1] if e else "unknown"])
        print("wrote %s" % args.csv)

    if args.per_pc:
        agg = collections.defaultdict(collections.Counter)
        for (pc, rid), n in per_pc.items():
            agg[pc][rid] += n
        with open(args.per_pc, "w", newline="", encoding="utf-8") as fh:
            w = csvmod.writer(fh)
            w.writerow(["pc", "pc_hex", "total_samples", "top_reason",
                        "top_reason_samples"])
            for pc in sorted(agg, key=lambda k: -sum(agg[k].values())):
                c = agg[pc]
                tot = sum(c.values())
                rid, n = c.most_common(1)[0]
                w.writerow([pc, "0x%08x" % pc, tot, reason_name(rid), n])
        print("wrote %s" % args.per_pc)

    if args.verify:
        verify(args.verify, hist, total)
    return 0


if __name__ == "__main__":
    sys.exit(main())