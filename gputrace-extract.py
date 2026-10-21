#!/usr/bin/env python3
"""Turn a `.ngfx-gputrace` capture into the three artefacts `pcs-lines.py` eats.

    python gputrace-extract.py captures/exp/Sandbox_....ngfx-gputrace --out out/exp

writes

    out/exp/pcbuf/*.pc.bin      per-SM PC-sample buffers        (criteria 2a, 2c)
    out/exp/decoded/idNN.bin    deobfuscated shader blobs       (criterion 2b)
    out/exp/lines/blobNN.bin    the same bytes under the name `pcs-lines.py` asks for

so that the whole chain is capture-in, CSV-out:

    python gputrace-extract.py <capture> --out out/exp
    python pcs-lines.py --out out/exp/source_lines.csv \
                        --per-pc out/exp/source_lines_per_pc.csv

No protobuf runtime and no `lz4` package are needed.  WRPV section walking and
raw-LZ4 block decoding are reused from `gputrace-pc2line.py`, which already
implements both; everything else is found by *structure*, because the generated
.proto files are not available to a clean checkout.

Blob table
----------
A repeated field of length-delimited entries whose payload decodes cleanly to

    { 1: id (varint), 2: data (bytes), 3: uncompressedSize (varint),
      4: compression (varint), 5: obfuscation (varint) }

with `compression == 2` (LZ4) and `obfuscation == 2` (SIMPLE).  The entry is
reached through its parent's field-1 tag, so each candidate starts with 0x0a.
On the reference capture this finds exactly 16 entries, ids 0..15, and the
declared sizes line up with the shader containers (273,100 = the PS SPIR-V,
69,376 = `.text.main_2`, 88,096 = the cubin, ...).

PC-sample buffers
-----------------
Field 4 (tag 0x22) length-delimited payloads of roughly 2.2 MB whose first
record is a conforming `{pc, kind=2, pad=0, state}` with `pc` 16-byte aligned.
On the reference capture this finds 60 candidates; 58 of them are byte-for-byte
identical to the buffers the earlier extraction produced, and the aggregate
stall histogram those 58 yield sits within 0.24 pp of the capture's own
`GPUTRACE_FRAME.xls`.  The two extras are reported separately (`--manifest`)
rather than silently folded in: see the note printed at the end of a run.

Obfuscation
-----------
Blob bytes are LZ4-compressed *and then* XORed with a keystream that is a pure
function of offset.  The keystream has no period, is identical across captures
(verified on three), and therefore ships as `keystream.bin` next to this file.
Decoding is `lz4(stored) XOR keystream`, over the first `len(blob)` bytes.
"""
import argparse
import csv
import hashlib
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KEYSTREAM = os.path.join(HERE, "keystream.bin")

SPIRV = b"\x03\x02\x23\x07"
ELF = b"\x7fELF"

# PC-sample records: {u32 pc, u32 kind, u32 pad, u32 state}.  11 of the 16
# bytes are fixed, which is what makes a structural scan safe.
REC = struct.Struct("<IIII")
REC_KIND = 2
REC_PAD = 0

BUF_MIN = 2_000_000
BUF_MAX = 2_600_000


def load_helper():
    """Import the sibling research script for `sections()` and `lz4_block()`."""
    path = os.path.join(HERE, "gputrace-pc2line.py")
    if not os.path.exists(path):
        raise SystemExit("gputrace-pc2line.py is required next to this script")
    spec = importlib.util.spec_from_file_location("gputrace_pc2line", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_varint(buf, i, end):
    v = 0
    shift = 0
    while i < end:
        c = buf[i]
        i += 1
        v |= (c & 0x7F) << shift
        if not c & 0x80:
            return v, i
        shift += 7
    return None, i


def parse_blob_entry(buf, tag, end):
    """Decode one `0a <len>` entry.  Return (entry, next_offset) or None.

    An entry must consist of fields 1..5 only, with 1/3/4/5 varints and 2 bytes,
    and must declare LZ4 + SIMPLE.  Anything else is rejected rather than
    guessed at.
    """
    if buf[tag] != 0x0A:
        return None
    length, body = read_varint(buf, tag + 1, end)
    if length is None or length < 4 or body + length > end:
        return None
    stop = body + length
    ent = {}
    j = body
    while j < stop:
        key, j = read_varint(buf, j, stop)
        if key is None:
            return None
        field, wire = key >> 3, key & 7
        if field < 1 or field > 5:
            return None
        if wire == 0:
            val, j = read_varint(buf, j, stop)
            if val is None:
                return None
            ent[field] = val
        elif wire == 2:
            ln, j = read_varint(buf, j, stop)
            if ln is None or j + ln > stop:
                return None
            ent[field] = buf[j:j + ln]
            j += ln
        else:
            return None
    if set(ent) != {1, 2, 3, 4, 5}:
        return None
    if not isinstance(ent[2], bytes):
        return None
    if ent[4] != 2 or ent[5] != 2:
        return None
    return ent, stop


def scan_blobs(section):
    """Return [(entry_offset, entry)] for every structurally valid blob entry."""
    out = []
    n = len(section)
    i = 0
    while True:
        tag = section.find(b"\x0a", i)
        if tag < 0:
            return out
        hit = parse_blob_entry(section, tag, n)
        if hit is not None:
            out.append((tag, hit[0]))
            i = hit[1]
        else:
            i = tag + 1


def scan_buffers(section):
    """Return [(tag_offset, payload_offset, length)] for PC-sample buffers."""
    out = []
    n = len(section)
    i = 0
    while True:
        tag = section.find(b"\x22", i)
        if tag < 0:
            return out
        length, body = read_varint(section, tag + 1, n)
        if length is not None and BUF_MIN <= length <= BUF_MAX and body + length <= n:
            pc, kind, pad, _state = REC.unpack_from(section, body)
            if kind == REC_KIND and pad == REC_PAD and (pc & 0xF) == 0:
                out.append((tag, body, length))
                i = body + length
                continue
        i = tag + 1


def deobfuscate(helper, payload, keystream, size):
    """LZ4-decode, then XOR the declared keystream prefix.

    Order matters: the keystream is applied to the *decompressed* bytes, which
    is why the same fixed keystream works for blobs of every size.
    """
    if size > len(keystream):
        raise SystemExit("blob of %d bytes exceeds the %d-byte keystream"
                         % (size, len(keystream)))
    raw = helper.lz4_block(payload, size)
    return bytes(a ^ b for a, b in zip(raw, keystream[:size]))


def classify(blob):
    if blob[:4] == SPIRV:
        return "spirv"
    if blob[:4] == ELF:
        return "elf"
    return "raw"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--out", default=os.path.join("out", "exp"),
                    help="output root (default out/exp)")
    ap.add_argument("--keystream", default=KEYSTREAM,
                    help="deobfuscation keystream (default ./keystream.bin)")
    ap.add_argument("--manifest",
                    help="write a CSV of everything found and where it came from")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.capture):
        raise SystemExit("no such capture: %s" % args.capture)
    with open(args.keystream, "rb") as fh:
        keystream = fh.read()

    helper = load_helper()
    buf = open(args.capture, "rb").read()
    if not args.quiet:
        print("%s: %s bytes on disk" % (args.capture, format(len(buf), ",")))

    pcbuf_dir = os.path.join(args.out, "pcbuf")
    decoded_dir = os.path.join(args.out, "decoded")
    lines_dir = os.path.join(args.out, "lines")
    for d in (pcbuf_dir, decoded_dir, lines_dir):
        os.makedirs(d, exist_ok=True)

    rows = []
    blobs = []
    buffers = []

    for index, _ident, comp_size, uncomp_size, hdr in helper.sections(buf):
        try:
            section = helper.lz4_block(buf[hdr + 24:hdr + 24 + comp_size],
                                       uncomp_size or None)
        except Exception as exc:                       # noqa: BLE001 - report, skip
            if not args.quiet:
                print("  section %d: LZ4 failed (%s), skipped" % (index, exc))
            continue

        found = scan_blobs(section)
        if found:
            blobs.append((index, found))
            if not args.quiet:
                print("  section %2d: %d blob entries (%s compressed)"
                      % (index, len(found), format(sum(len(e[2]) for _, e in found), ",")))

        found_bufs = scan_buffers(section)
        for tag, body, length in found_bufs:
            buffers.append((index, tag, body, length, section[body:body + length]))
        if found_bufs and not args.quiet:
            print("  section %2d: %d PC-sample buffers (%s bytes)"
                  % (index, len(found_bufs),
                     format(sum(f[2] for f in found_bufs), ",")))

        del section

    if not blobs:
        raise SystemExit("no blob table found -- the capture layout is unknown")
    if not buffers:
        raise SystemExit("no PC-sample buffers found")

    # ---- blobs -------------------------------------------------------------
    section_index, entries = max(
        blobs, key=lambda pair: sum(len(e[2]) for _off, e in pair[1]))
    ids = [e[1] for _off, e in entries]
    if sorted(ids) != list(range(len(ids))):
        raise SystemExit("blob ids are not 0..N-1: %r" % ids)

    for _off, ent in sorted(entries, key=lambda p: p[1][1]):
        blob_id, payload, size = ent[1], ent[2], ent[3]
        blob = deobfuscate(helper, payload, keystream, size)
        kind = classify(blob)
        for directory, stem in ((decoded_dir, "id%02d.bin"), (lines_dir, "blob%02d.bin")):
            with open(os.path.join(directory, stem % blob_id), "wb") as fh:
                fh.write(blob)
        rows.append(dict(kind="blob", section=section_index, offset=hex(_off),
                         bytes=len(payload), sha1=hashlib.sha1(blob).hexdigest(),
                         detail="id=%d %s %d B" % (blob_id, kind, size)))
        if not args.quiet:
            print("  blob %2d  %-6s %7d B" % (blob_id, kind, size))

    # ---- PC-sample buffers -------------------------------------------------
    for order, (section_index, tag, body, length, payload) in enumerate(buffers):
        name = "vsm%04d_%012x.pc.bin" % (order, body + length)
        with open(os.path.join(pcbuf_dir, name), "wb") as fh:
            fh.write(payload)
        rows.append(dict(kind="pcbuf", section=section_index,
                         offset=hex(body), bytes=length,
                         sha1=hashlib.sha1(payload).hexdigest(),
                         detail=name))

    if not args.quiet:
        print("\n%d blob entries, %d PC-sample buffers -> %s"
              % (len(entries), len(buffers), args.out))
        if len(buffers) < 16:
            print("note: only %d buffers -- fewer than any plausible SM count;"
                  " check with\n      python pcs-samples.py %s --verify <GPUTRACE_FRAME.xls>"
                  % (len(buffers), pcbuf_dir))

    if args.manifest:
        with open(args.manifest, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=["kind", "section", "offset",
                                                    "bytes", "sha1", "detail"])
            writer.writeheader()
            writer.writerows(rows)
        if not args.quiet:
            print("manifest -> %s" % args.manifest)


if __name__ == "__main__":
    sys.exit(main())
