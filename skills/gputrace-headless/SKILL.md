---
name: gputrace-headless
description: Capture, validate and analyze NVIDIA Nsight Graphics GPU Trace data headlessly on Windows - including per-source-line warp-state (PC) sample attribution decoded from the .ngfx-gputrace container, which no official CLI or third-party tool provides. Use when the user wants GPU bottleneck analysis, shader stall attribution, or frame-capture profiling without opening the Nsight Graphics GUI, or wants an AI agent to read GPU Trace captures.
---

# Headless Nsight Graphics GPU Trace analysis

PowerShell CLI that captures GPU Trace profiles via `ngfx`, validates them, and reports them
with an evidence contract - plus a decode of the `.ngfx-gputrace` container itself that
reproduces the GUI's Source Positions data (per-source-line sample counts and stall mix)
with no GUI. No official NVIDIA CLI analyzes a saved GPU Trace capture: `ngfx` only captures
(and auto-exports a fixed set of aggregate tables), and `ngfx-replay` rejects the WRPV
container. The container decode is the unique part of this tool.

Windows + Nsight Graphics 2026.1 (measured) + PowerShell 5.1. Python 3 (stdlib only) is
needed only for the container decode (`gputrace-sampling.ps1`).

## Engine first

The CLI in this repository is the engine. Drive it directly:

```powershell
# 1. Capture one trace per variant (warp-state sampling ON, all metrics auto-exported).
#    Profiles describe the target: profiles\*.json, -DryRun first on a new one.
.\gputrace-capture.ps1 -Profile <name-or-path>

# 2. Validated report / comparison. Exits non-zero when validation fails.
.\gputrace-report.ps1 -Validate -Compare gputrace\arm0,gputrace\arm1
.\gputrace-report.ps1 -Json -Validate -Dir gputrace\arm1      # for agents to parse

# 3. Per-source-line sampling attribution, decoded from the container (needs Python 3).
.\gputrace-sampling.ps1 -Trace <path\to\capture.ngfx-gputrace> -Json -Top 30

# 4. Registers / instruction footprint from a pipeline dump (different API entirely).
.\pipeline-dump-report.ps1
```

If the `gputrace` MCP server is configured in your client, prefer its tools
(`gputrace_capture`, `gputrace_report`, `gputrace_compare`, `gputrace_list_metrics`,
`gputrace_raw_metric`, `gputrace_source_lines`) - same engine, structured responses. The
skill still applies: the accuracy contract below governs both.

## Decision guide

- "Is variant A faster / lighter than B?" -> `gputrace-capture` both arms, then
  `gputrace-report -Validate -Compare`. Quote `count`-class metrics for "did work shrink";
  never quote trace wall-times (the profiler costs ~18%).
- "Where does the shader stall?" -> `gputrace-sampling.ps1` per-source-line table
  (`sampled` class), plus the counter stall breakdown from `gputrace-report` for the
  16-reason hardware view. The two are different quantities; report them separately.
- "Which metric instance is the right one?" -> `gputrace_list_metrics` first; same-name
  instances (`Name`, `Name#2`) can differ several-fold between rollup levels.
- "Is this number real?" -> `-Validate` runs eight structural checks and refuses failed
  traces; `-Json` output carries an evidence class on every value. Cite the class.

## Accuracy contract (binds every number you report)

1. **Never cite a trace that failed validation.** The CLI refuses it; if you see
   `validation FAILED`, fix the capture, do not soften the wording.
2. **Evidence classes travel with values:**
   - `count` - deterministic event totals; identical work must reproduce exactly.
   - `sampled` - warp-state (PC) samples, the GUI Top Stall data source. Count-weighted;
     GUI panel values are time-weighted. Compare ranks and shapes, never absolute
     percentages against the GUI.
   - `rate` - per-cycle averages; they move with the SM clock, so compare same-clock or
     `ngfx --lock-gpu-clocks` runs only.
   - `ratio` / `peak-normalised` / `invariant` - hit rates, assumed-peak shares, warp width.
3. **Aggregation semantics**: GUI displays are time-weighted over the whole trace; export
   medians cover captured frames only. 2-3% differences between the two on identical
   captures are expected - directional differences are what mean anything.
4. **Sampling provenance**: only captures taken with warp-state sampling ON (the default
   here) carry sampled stall data at all; `REPRO_INFO.xls` records it.

## Pitfalls that cost the previous sessions

- GeForce hands GPU counters only to elevated processes unless the NVIDIA Control Panel
  "allow all users" toggle is set. Without it the capture relaunches via UAC - needs a
  human once.
- The per-line decode needs the target's profile `env` to force OFF any dump/verbose
  switch that changes shader compilation; a trace of altered code is worthless.
- One variant per trace. An app that sweeps variants per frame makes attribution
  impossible for close variants.
- PowerShell 5.1 `Set-Content -Encoding UTF8` writes a BOM; ngfx's config parser silently
  rejects it (the capture script handles this - do not "simplify" it away).
- Python discovery for `gputrace-sampling.ps1`: `-Python` or `$env:GPUTRACE_PYTHON` beats
  the Store stub on PATH (which the probe rejects by design).
- Nsight Compute (`ncu`) cannot profile fragment-shader work in Vulkan draws - it is a
  CUDA/compute profiler. Do not route graphics workloads there.

## File map

| Path | Role |
| --- | --- |
| `gputrace-capture.ps1` | headless capture, one trace per profile variant |
| `gputrace-report.ps1` | validation + reporting + comparison (the analysis engine) |
| `gputrace-sampling.ps1` | container decode -> per-source-line sample/stall table |
| `profiles\*.json` | target descriptions; `example.json` is the template |
| `mcp\server.ps1` | MCP server wrapping the CLI |
| `docs\HANDOFF.md` | reverse-engineering trail: container format, PC-sample records, what was proven and how |
| `docs\per-source-line-solved-2026-10-19.md` | the per-source-line derivation and its GUI verification (122/122 lines, rho 1.0000) |
