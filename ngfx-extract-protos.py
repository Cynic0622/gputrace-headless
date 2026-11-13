"""
Extract embedded FileDescriptorProto blobs from a Nsight Graphics binary and render
them back into readable .proto files.

Nsight Graphics' TPS (Target Platform Server) layer links each .proto into the binary
as a raw, uncompressed, contiguous serialized FileDescriptorProto. The protobuf wire
format is parsed here directly, so no protobuf runtime is required.

This is how the schemas under schemas/ngfx-<version>/ were produced. Re-run it after
an Nsight upgrade to see what changed.

Usage:
    python ngfx-extract-protos.py <binary> <outdir> [--only SUBSTRING]
    python ngfx-extract-protos.py --all <ngfx-host-dir> <outdir>

Examples:
    python ngfx-extract-protos.py \
        "<nsight-install>/host/windows-desktop-nomad-x64/ngfx-rpc.exe" \
        out

Exit status is 0 on success. The tool prints one line per descriptor found.
"""

import os
import re
import sys
import json
import glob
from collections import OrderedDict

# ----------------------------------------------------------------- wire format

WIRE_VARINT, WIRE_I64, WIRE_LEN, WIRE_I32 = 0, 1, 2, 5


class ParseError(Exception):
    pass


def read_varint(buf, pos):
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ParseError("varint truncated")
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
        if shift > 63:
            raise ParseError("varint too long")


def read_field(buf, pos):
    key, pos = read_varint(buf, pos)
    fnum, wtype = key >> 3, key & 0x07
    if wtype == WIRE_VARINT:
        val, pos = read_varint(buf, pos)
    elif wtype == WIRE_I64:
        if pos + 8 > len(buf):
            raise ParseError("i64 truncated")
        val, pos = buf[pos:pos + 8], pos + 8
    elif wtype == WIRE_LEN:
        ln, pos = read_varint(buf, pos)
        if pos + ln > len(buf):
            raise ParseError("len truncated")
        val, pos = buf[pos:pos + ln], pos + ln
    elif wtype == WIRE_I32:
        if pos + 4 > len(buf):
            raise ParseError("i32 truncated")
        val, pos = buf[pos:pos + 4], pos + 4
    else:
        raise ParseError(f"bad wire type {wtype}")
    return fnum, wtype, val, pos


def parse_message(buf):
    """Parse a message body into {field_number: [raw_values]}."""
    out = {}
    pos = 0
    while pos < len(buf):
        fnum, wtype, val, pos = read_field(buf, pos)
        out.setdefault(fnum, []).append(val)
    return out


def as_str(v):
    return v.decode("utf-8", "replace")


# ------------------------------------------------- FileDescriptorProto schema

FDP_MAX_FIELD = 14
DP_MAX_FIELD = 10

LABEL = {1: "optional", 2: "required", 3: "repeated"}

TYPE = {1: "double", 2: "float", 3: "int64", 4: "uint64", 5: "int32",
        6: "fixed64", 7: "fixed32", 8: "bool", 9: "string", 10: "group",
        11: "message", 12: "bytes", 13: "uint32", 14: "enum",
        15: "sfixed32", 16: "sfixed64", 17: "sint32", 18: "sint64"}


def try_parse_fdp(buf, start):
    """Greedily parse a FileDescriptorProto at `start` (which must sit on the
    0x0A 'name' tag). Returns (raw_fields, end_offset) or (None, None)."""
    pos = start
    raw = {}
    try:
        while pos < len(buf):
            fnum, wtype, val, newpos = read_field(buf, pos)
            if fnum < 1 or fnum > FDP_MAX_FIELD:
                break                      # left the descriptor
            if fnum not in (1, 2, 3, 12) and wtype != WIRE_LEN:
                break
            raw.setdefault(fnum, []).append(val)
            pos = newpos
    except ParseError:
        return None, None
    if 1 not in raw or not as_str(raw[1][0]).endswith(".proto"):
        return None, None
    return raw, pos


def parse_field_descriptor(body):
    m = parse_message(body)
    f = {"name": "", "number": 0, "label": "optional", "type": "message",
         "type_name": "", "oneof_index": None, "default": "", "json_name": ""}
    if 1 in m:
        f["name"] = as_str(m[1][0])
    if 3 in m:
        f["number"] = m[3][0]
    if 4 in m:
        f["label"] = LABEL.get(m[4][0], "?")
    if 5 in m:
        f["type"] = TYPE.get(m[5][0], "?")
    if 6 in m:
        f["type_name"] = as_str(m[6][0])
    if 7 in m:
        f["default"] = as_str(m[7][0])
    if 9 in m:
        f["oneof_index"] = m[9][0]
    if 10 in m:
        f["json_name"] = as_str(m[10][0])
    return f


def parse_enum_descriptor(body):
    m = parse_message(body)
    e = {"name": as_str(m[1][0]) if 1 in m else "", "values": []}
    for val in m.get(2, []):
        vm = parse_message(val)
        e["values"].append((as_str(vm[1][0]) if 1 in vm else "",
                            vm[2][0] if 2 in vm else 0))
    return e


def parse_descriptor_proto(body):
    m = parse_message(body)
    out = {"name": as_str(m[1][0]) if 1 in m else "",
           "fields": [], "nested": [], "enums": [], "oneofs": []}
    for val in m.get(2, []):
        out["fields"].append(parse_field_descriptor(val))
    for val in m.get(3, []):
        out["nested"].append(parse_descriptor_proto(val))
    for val in m.get(4, []):
        out["enums"].append(parse_enum_descriptor(val))
    for val in m.get(8, []):
        om = parse_message(val)
        out["oneofs"].append(as_str(om[1][0]) if 1 in om else "")
    return out


def short_type(type_name, package):
    """'.NV.WarpViz.PbTraceData' -> 'PbTraceData' (or the qualified tail)."""
    n = type_name.lstrip(".")
    if package and n.startswith(package + "."):
        return n[len(package) + 1:]
    return n.split(".")[-1]


def render(fdp, lines, indent=0):
    pad = "  " * indent
    lines.append(f"// package {fdp['package']}  |  syntax {fdp['syntax']}"
                 + (f"  |  from {fdp['source']}" if fdp.get("source") else ""))
    for dep in fdp["dependencies"]:
        lines.append(f'// import "{dep}";')
    lines.append("")

    for e in fdp["enums"]:
        lines.append(f"{pad}enum {e['name']} {{")
        for n, v in e["values"]:
            lines.append(f"{pad}  {n} = {v};")
        lines.append(f"{pad}}}")
        lines.append("")

    def field_type(f):
        if f["type"] in ("message", "enum", "group") and f["type_name"]:
            return short_type(f["type_name"], fdp["package"])
        return f["type"]

    def emit(msg, ind):
        p = "  " * ind
        lines.append(f"{p}message {msg['name']} {{")
        by_oneof = {}
        for f in msg["fields"]:
            if f["oneof_index"] is not None:
                by_oneof.setdefault(f["oneof_index"], []).append(f)
        emitted = set()
        for f in msg["fields"]:
            if f["oneof_index"] is not None:
                oi = f["oneof_index"]
                if oi in emitted:
                    continue
                emitted.add(oi)
                oname = msg["oneofs"][oi] if oi < len(msg["oneofs"]) else f"oneof_{oi}"
                lines.append(f"{p}  oneof {oname} {{")
                for g in by_oneof[oi]:
                    lines.append(f"{p}    {field_type(g)} {g['name']} = {g['number']};")
                lines.append(f"{p}  }}")
            else:
                lines.append(f"{p}  {f['label']} {field_type(f)} "
                             f"{f['name']} = {f['number']};")
        for sub in msg["nested"]:
            lines.append("")
            emit(sub, ind + 1)
        for e in msg["enums"]:
            lines.append(f"{p}  enum {e['name']} {{")
            for n, v in e["values"]:
                lines.append(f"{p}    {n} = {v};")
            lines.append(f"{p}  }}")
        lines.append(f"{p}}}")
        lines.append("")

    for msg in fdp["messages"]:
        emit(msg, indent)

    for svc in fdp["services"]:
        lines.append(f"{pad}service {svc} {{}}")
        lines.append("")


def count_messages(msgs):
    return sum(1 + count_messages(m["nested"]) for m in msgs)


def count_fields(msgs):
    return sum(len(m["fields"]) + count_fields(m["nested"]) for m in msgs)


# ------------------------------------------------------------------- driver

def extract(binary, outdir, only=None, verbose=True):
    data = open(binary, "rb").read()
    os.makedirs(outdir, exist_ok=True)

    pat = re.compile(rb"\x0a[\x00-\x7f]([ -~]{2,60}?\.proto)")
    found = OrderedDict()
    for m in pat.finditer(data):
        if m.group(0)[1] != len(m.group(1)):
            continue
        raw, end = try_parse_fdp(data, m.start())
        if raw is None:
            continue
        name = as_str(raw[1][0])
        if only and only not in name:
            continue
        prev = found.get(name)
        if prev is None or (end - m.start()) > (prev[1] - prev[0]):
            found[name] = (m.start(), end, raw)

    if verbose:
        print(f"binary: {binary}  ({len(data):,} bytes)")
        print(f"descriptors: {len(found)}\n")

    index = []
    for name, (start, end, raw) in sorted(found.items()):
        fdp = {
            "name": name,
            "source": os.path.basename(binary),
            "package": as_str(raw[2][0]) if 2 in raw else "",
            "dependencies": [as_str(v) for v in raw.get(3, [])],
            "syntax": as_str(raw[12][0]) if 12 in raw else "proto2",
            "messages": [parse_descriptor_proto(v) for v in raw.get(4, [])],
            "enums": [parse_enum_descriptor(v) for v in raw.get(5, [])],
            "services": [],
        }
        for val in raw.get(6, []):
            sm = parse_message(val)
            fdp["services"].append(as_str(sm[1][0]) if 1 in sm else "?")

        lines = []
        render(fdp, lines)
        path = os.path.join(outdir, name.replace("/", "__"))
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(lines))

        nmsg, nfld = count_messages(fdp["messages"]), count_fields(fdp["messages"])
        index.append({"file": name, "package": fdp["package"], "source": fdp["source"],
                      "offset": start, "bytes": end - start,
                      "messages": nmsg, "fields": nfld, "deps": fdp["dependencies"]})
        if verbose:
            print(f"{name:<52} {fdp['package']:<32} msgs={nmsg:<4} "
                  f"fields={nfld:<5} {end-start:>7,}B")

    return index


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    only = None
    if "--only" in argv:
        i = argv.index("--only")
        only = argv[i + 1]
        del argv[i:i + 2]

    all_mode = False
    if argv and argv[0] == "--all":
        all_mode = True
        del argv[0]

    if len(argv) < 2:
        print(__doc__)
        return 2

    src, outdir = argv[0], argv[1]
    combined = []
    if all_mode:
        targets = sorted(glob.glob(os.path.join(src, "*.exe")) +
                         glob.glob(os.path.join(src, "Plugins", "*.dll")) +
                         glob.glob(os.path.join(src, "Plugins", "*", "*.dll")))
    else:
        targets = [src]

    seen = {}
    for t in targets:
        for entry in extract(t, outdir, only):
            key = entry["file"]
            if key not in seen or entry["bytes"] > seen[key]["bytes"]:
                seen[key] = entry
    combined = list(seen.values())
    combined.sort(key=lambda e: e["file"])

    with open(os.path.join(outdir, "_index.json"), "w", encoding="utf-8") as fh:
        json.dump(combined, fh, indent=2)
    print(f"\nwrote {len(combined)} .proto files to {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
