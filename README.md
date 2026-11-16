# gputrace-headless

Headless capture and analysis of NVIDIA Nsight Graphics **GPU Trace** data — no GUI, no
screenshots, no hand-copying numbers off a panel. A PowerShell CLI does the work; a thin MCP
server exposes the same engine to LLM agents, and an agent skill teaches it to any coding
agent.

What makes this more than `ngfx` automation: **NVIDIA's CLI captures but does not analyze.**
`ngfx` writes a capture plus a fixed set of aggregate export tables; there is no CLI command
that opens a `.ngfx-gputrace` afterwards, and `ngfx-replay` rejects the GPU Trace container
outright (`Invalid file header` — the replayer speaks a different format). Everything at the
container level — the per-PC samples, the per-source-line attribution, the per-line stall
mix that the GUI's Source Positions view renders — was reachable only through the GUI, until
this decode.

The point is not only automation. It is that **every number this tool reports is labelled with
how far it can be trusted**, and a capture that fails validation is refused rather than returned
as data.

## Requirements

- **Windows** with **Nsight Graphics** installed (developed and measured against 2026.1).
- **PowerShell 5.1** — the only runtime for capture, export reading and reporting. No Node, no
  Python, no packages to install.
- **Python 3** (stdlib only, no packages) — needed for exactly one thing: decoding the capture
  container for per-source-line sampling analysis (`gputrace-sampling.ps1`). Everything else in
  this tool runs without it.
- A traced application that takes CLI arguments (see [Profiles](#profiles)).

`ngfx.exe` and `ngfx-ui.exe` are found automatically: an explicit path first (`-NgfxPath`, or
`$env:GPUTRACE_NGFX`), then `PATH`, then the usual install roots and every fixed drive. Nsight
Graphics installs under a version-stamped directory on whatever drive the user picked, so the
search is deliberately not a fixed path list — and `-NgfxPath` is the escape hatch when even that
misses.

**Counter access.** NVIDIA hands GPU performance counters only to an elevated process on GeForce,
so `ngfx` connects and then fails with `GPU Performance Counters unavailable`. Two ways out:

- **Permanent:** NVIDIA Control Panel → Developer → Manage GPU Performance Counters → "Allow all
  users". On drivers where the legacy registry key still applies, `unlock-counters.ps1` sets
  `RmProfilingAdminOnly=0` instead — note that the driver only honours it after the next
  driver reload or reboot.
- **Per run:** `gputrace-capture.ps1` probes first and relaunches itself through UAC when needed.
  One prompt covers all variants, and the script transcribes the elevated run back to your console
  (an elevated process otherwise disappears with its console).

## Quick start

The commands below use the bundled `ntc-benchmark` profile, which points at a sibling checkout of
the application it was written for — **substitute your own profile** (see
[Bringing your own application](#bringing-your-own-application)) and check it with `-DryRun`
before the first real capture.

```powershell
# 1. Capture. One trace per variant, warp-state sampling on, all metrics auto-exported.
.\gputrace-capture.ps1 -Profile ntc-benchmark

# 2. Read, validate, compare.
.\gputrace-report.ps1 -Validate -Compare gputrace\arm0,gputrace\arm1,gputrace\arm2
.\gputrace-report.ps1 -Json -Validate -Dir gputrace\arm1     # for an agent to parse

# 3. Registers / instruction footprint per variant, from a different API entirely.
#    Run the application once with its own pipeline-dump switch ON - the bundled profile's `env`
#    field holds that switch off during traces, so override it for this run - then:
.\pipeline-dump-report.ps1

# 4. Only when the counters themselves matter: one GPU Trace per variant.
#    -MultiPassMetrics adds the 16-reason counter stall breakdown.
.\gputrace-capture.ps1 -Profile ntc-benchmark -MultiPassMetrics

# 5. Read the per-variant counter breakdown.
.\gputrace-report.ps1 -Validate -Regimes -Compare gputrace\arm0,gputrace\arm1

# 6. Where the warps stall, per source line — decoded from the capture container, no GUI.
#    Needs Python 3 (stdlib only). The step self-checks the decode against the capture's
#    own aggregate and refuses to return the table when that check fails.
.\gputrace-sampling.ps1 -Trace gputrace\arm1\Sandbox_2026_10_27_12_00_00.ngfx-gputrace -Json -Top 30
```

## Profiles

A profile is a JSON file describing one capturable target — everything the tool needs that is not
about Nsight Graphics itself. It is the capture's configuration document: one file per target,
no code changes to add one.

```json
{
  "name": "ntc-benchmark",
  "description": "What this target is, for a human reading the file later.",
  "workDir": "..\\..\\Bear",
  "exe": "build\\bin\\Release\\Sandbox.exe",
  "architecture": "Ada",
  "appArgs": "--ntc-benchmark --model Suzanne --samples 1000000",
  "appTimeoutArgs": "--timeout {seconds}",
  "appSeconds": 25,
  "variants": [
    { "name": "arm0", "args": "--arm 0" },
    { "name": "arm1", "args": "--arm 1" }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `exe` | **yes** | The executable to trace. Relative to `workDir`. |
| `variants` | **yes** | One trace per entry, each `{ "name", "args" }`. **`name` becomes a directory name**, so keep it filesystem-safe. |
| `workDir` | recommended | The target's checkout. **A relative value resolves against the profile file**, so a profile can point at a tree next to itself. Falls back to `-WorkDir`, then the current directory. |
| `architecture` | recommended | Selects the Nsight metric set. **Set it explicitly on anything but Ada** — it defaults to `Ada` when omitted, and other architectures expose a different metric set (check with `gputrace_list_metrics`). |
| `appArgs` | optional | Base arguments every variant shares; each variant's `args` are appended. |
| `appTimeoutArgs` | optional | How to tell the application how long it may live, as a template — `{seconds}` is replaced by `appSeconds`. See below. |
| `appSeconds` | optional | The value substituted into `appTimeoutArgs`. Default 25. Does nothing on its own. |
| `env` | optional | Environment variables the traced application must see, as `{ "NAME": "value" }`. Normally empty. See below. |
| `name`, `description` | optional | Metadata. Not read by any code; write them for the next person. |

`-Profile` accepts a bundled name (resolved under `profiles\`) or a path to any JSON file.
`-Exe`, `-AppArgs`, `-WorkDir` and `-AppSeconds` override the profile for one run; the profile is
the default, not the last word.

**`env` exists to keep a trace honest.** A diagnostic switch that changes how the driver compiles
shaders — dumping pipeline statistics, forcing debug info, disabling optimizations — makes the trace
describe code that does not normally exist. `env` is where the profile names those switches so they
are forced off for the run. It is a map rather than a single flag because which variables a target
exposes is the target's business, and keeping the names in the profile is what stops them from
having to appear in this tool.

**One variant per trace, deliberately.** The traced application must not switch variants per frame
(`--sweep`): when two variants are numerically close, frames cannot be attributed back to them
afterwards, and the trace becomes useless for exactly the comparison it was taken for.

### Bringing your own application

Start from `profiles\example.json`, which is a template rather than a runnable target — its
placeholders are left in on purpose, and the capture stops on the first one and names it.

Four things the tool needs from the application, none of which the field table can express:

1. **It must be able to select a variant from the command line**, or `variants` can only hold one
   entry — and a single-variant profile gives you a trace, not a comparison.
2. **It must end on its own.** Nothing here bounds it: there is no watchdog on the application
   process, so the capture waits for as long as the application runs. If it takes a lifetime flag,
   say so with `appTimeoutArgs` (for example `"--timeout {seconds}"`); if it terminates by design,
   leave the field out and the arguments are passed through untouched. Omitting it is fine — the
   capture warns once that the run length is the application's business.
3. **It must run unattended.** `ngfx` launches the process directly; nothing can answer a prompt
   or click a dialog.
4. **It must not change how shaders are compiled while it is being traced.** Any dump/verbose
   switch that alters code generation pollutes the trace — name it in `env` and force it to `"0"`.

Sanity-check a new profile with `-DryRun`: it prints the exact `ngfx` command line for every
variant without running anything, which is where a wrong path or a missing flag shows up first.

## For AI agents

Two doors, same engine — pick whichever your client speaks:

- **Skill** (recommended first): copy `skills\gputrace-headless\` into your agent's skills
  directory (Claude Code: `.claude\skills\` project-level or `~\.claude\skills\` user-level;
  ZCode and other CLIs: their skill folders). The SKILL.md teaches the workflows, the
  accuracy contract and the pitfalls, so the agent drives the CLI correctly with no other
  setup.
- **MCP**: register `mcp\server.ps1` with your client (config snippets in
  [mcp/README.md](mcp/README.md)). Structured tools with schemas; validation refusals and
  evidence classes are embedded in every response. Tool: `gputrace_capture`, `gputrace_report`,
  `gputrace_compare`, `gputrace_list_metrics`, `gputrace_raw_metric`, `gputrace_source_lines`.

If both are configured the skill tells the agent to prefer the MCP tools; the CLI remains the
fallback that always works.

## Layout

| Script | Role |
| --- | --- |
| `gputrace-capture.ps1` | Captures one GPU Trace per profile variant with `ngfx`, unattended, and auto-exports the metrics. |
| `gputrace-report.ps1` | Reads those exports, validates them, compares traces. The analysis engine. |
| `gputrace-sampling.ps1` | Decodes the `.ngfx-gputrace` container itself: per-source-line warp-state sample attribution (the GUI Source Positions data) with an internal-consistency gate. Needs Python 3. |
| `gputrace-common.ps1` | Shared discovery of `ngfx.exe` / `ngfx-ui.exe`. Dot-sourced by the two scripts above and by `gui-harvest.ps1`. |
| `pipeline-dump-report.ps1` | Reads a pipeline dump (`pipelines.csv`): registers, binary size, stack size. |
| `gui-harvest.ps1` | Screenshots and drives the Nsight Graphics UI. `-Action export` pulls the per-source-line attribution out as CSV — the one thing with no CLI front end. |
| `crop-png.ps1` | Crops a harvested screenshot to the panel that matters. |
| `keep-awake.ps1` | Stops the machine sleeping mid-capture. |
| `unlock-counters.ps1` | One-time: opens counter access to all users, so traces never need UAC again. |
| `ngfx-extract-protos.py` | Recovers every `.proto` Nsight links into its binaries (the capture format and the replayer's RPC) — the provenance of the container format this tool decodes; run it against your own install to regenerate the schemas locally. |
| `mcp\server.ps1` | MCP server (stdio) wrapping the CLI for an LLM agent. See [`mcp\README.md`](mcp/README.md). |
| `skills\gputrace-headless\` | Agent skill (SKILL.md): workflows, accuracy contract and pitfalls for coding agents that drive the CLI. See [For AI agents](#for-ai-agents). |

`mcp\README.md` covers the MCP installation, the client config snippets, the tool reference and
the accuracy contract each response carries.

## What was learned building this (the headless data map)

**Warp state sampling — the GUI "Top Stall" table's data source — is ON by default in the GUI and
OFF from the CLI; the switch is the real-time-shader-profiler option.** Evidence trail:

- The full GPU Trace activity option table lives inside `WarpVizPlugin.dll` (offset ~8.45M): 37
  options including `real-time-shader-profiler`, `pc-samples-per-pm-interval-per-sm`,
  `pm-bandwidth-limit`, `lock-gpu-clocks` (base/boost — fixes the clock-comparability gap), and
  `hes-enabled`. The option help text says the real-time shader profiler is "collected via a
  high-speed sampling profiler in the SM hardware" and that **when disabled, a more detailed list
  of SM and L1TEX perf counters is collected instead** — exactly the sampled-vs-counter split
  measured between GUI and CLI captures.
- With `--real-time-shader-profiler`, the session INFO line reports
  `Warp State Sampling Interval = 1024` — identical to GUI captures (the CLI default echo is 16).
  Without it, captures show "0 Samples" in the GUI's Shader Pipelines view.
- Two config-file pitfalls, both now fixed in `gputrace-capture.ps1`: (1) Windows PowerShell's
  `Set-Content -Encoding UTF8` writes a BOM, which ngfx's config parser silently rejects — the
  config must be written BOM-free; (2) the per-arch config only honours architecture-specific keys
  (metric-set-name / metric-set-id) — general options like multi-pass or the RTS profiler are
  silently ignored there and must be CLI flags.

The working recipe:

```powershell
ngfx --activity "GPU Trace Profiler" ... --metric-set-id 1 --multi-pass-metrics --real-time-shader-profiler
```

**Where the per-PC / per-source-line numbers live.** The capture carries the raw
warp-state sample buffer and nothing else about the shader. `pcSamplesStorage`
decodes headlessly to per-PC sample counts and per-PC stall reasons (verified
against the capture's own `GPUTrace.PCSampler.*` aggregate), and the GPU Trace host
only embeds a cubin with a DWARF line table when *Tools → Options → Search Paths →
Separate Shader Debug Information* is configured — which it is not by default.
The per-source-line join below works without it: the capture embeds the shader's
SPIR-V (with OpLine records) and the driver's cubin regardless.

**The per-pass timing breakdown was always in the export.** `D3DPERF_EVENTS.xls` is one row per
named event, one ms column per traced frame — the pass/draw split, no GUI needed.
`gputrace-report.ps1` reads it, plus `REPRO_INFO.xls` (capture provenance) and, with `-Regimes`,
`GPUTRACE_REGIMES.xls`. Regimes layout: header row, then metric names in blocks of exactly
`<frame-count>` columns; rows cycle the regime names, row 0 carries a whole-frame-per-column series
and later rows repeat one frame's value across the block — either column of a repeated row gives
the same value, and the report takes the first.

**Nsight Compute cannot profile this class of workload.** It injects fine but matches zero
launches when the work runs as a fragment shader in a Vulkan draw: ncu is a CUDA/compute profiler.
Keep it for genuine compute-kernel work only.

**A locked-down desktop fights synthetic input.** Security software can deny `SetCursorPos`,
`MoveWindow` and `SC_MAXIMIZE`, and pin the cursor at a fixed pixel; `SendInput` clicks then work
only there and `SendKeys` only reaches whatever is foreground. The GUI harvest therefore prefers:
spawn our own UI instance (`--shared-instance-key` so the single-instance handshake does not
forward the request to the user's instance and exit), read what it shows, screenshot and crop, and
only navigate when the keyboard focus actually sits on the app.

## The evidence contract

`gputrace-report.ps1` labels every metric, because the numbers are not equally trustworthy:

| Class | Meaning | How it is verified |
| --- | --- | --- |
| `sampled` | A quantity from the warp-state (PC) sampler — the same hardware source as the GUI Top Stall table. | Decoded from the capture container and cross-checked against the capture's own `GPUTrace.PCSampler.*` aggregate (`gputrace-sampling.ps1` refuses the table past a 1.0 pp deviation; measured 0.24 pp). Count-weighted, while GUI panel values are time-weighted — compare ranks and shapes. |
| `count` | A raw event count. | Two independent traces of the same work must agree **exactly**. |
| `invariant` | A physical constant the hardware guarantees. | Warp width is 32. It proves the counters are scaled correctly. |
| `ratio` | A ratio with a known denominator. | Stable across independent traces to ~0.1%. |
| `rate` | A per-cycle average. | Numerator is a count, denominator is elapsed cycles, so it **moves with the SM clock**. |
| `peak-normalised` | A rate against an assumed peak. | Internally checkable; **not** guaranteed to match another tool's definition. |

## The validation checks

`-Validate` runs eight checks and exits non-zero when one fails, so a script cannot read a broken
trace and treat it as good.

| Check | What it proves |
| --- | --- |
| `warp-width` | threads-per-instruction is exactly 32. If not, nothing else is scaled right. |
| `pipe-budget` | `alu + fma + xu <= total` instructions. |
| `registers` | `register-file% / warps_active` reconstructs a register count, which must land on a real allocation — and, with `-PipelineDump`, must match what the driver reports through `VK_KHR_pipeline_executable_properties`, a completely different API. |
| `slot-budget` | issue-slot utilisation + stalled fraction `<= 100%`. |
| `peak-bound` | The peak implied by the stall sum (`active / sum(stalls)`) is `>=` the architecture's warps per sub-partition — 8 on Turing, 12 on Ampere GA10x and Ada, 16 on GA100/Hopper/Blackwell. It lands just above the value when the scaling is right. The architecture is read from the capture's own `REPRO_INFO` (`Chip Name`), so it needs no input; an unrecognised chip **skips** the check rather than guessing, because judging against the wrong architecture reports a false failure. `-Architecture` overrides. |
| `determinism` | Two traces of the same variant agree exactly on every `count` metric. |
| `event-budget` | The per-pass timings sum to no more than the frame time — two different tables that must agree. |
| `sampling-provenance` | `REPRO_INFO` records whether warp state sampling was enabled; only sampling-enabled traces carry GUI-comparable stall data at all. |

The checks earn their keep: `determinism` first failed because `sm__inst_executed.avg.per_cycle_elapsed`
and `warps_active` were labelled `count` when they are per-cycle averages. The counts were identical;
the per-cycle figures differed by 1.8% — the two runs had run at slightly different SM clocks. That
is now its own evidence class.

## What cannot be measured this way

**Nsight's GUI stall table is not reproducible from an export.** `Top Stall #1/#2/#3` and
`Dependency-Attributed Samples` come from warp-state sampling stored inside the `.ngfx-gputrace`
container. On Nsight 2026 that container is a binary `WRPV` blob — confirmed by reading
[nsight-graphics-mcp](https://github.com/elliotttate/nsight-graphics-mcp), which gives up on WRPV
the same way and points at the auto-export folder. Enabling multi-pass does **not** change the
GUI's numbers, which confirms the two are different quantities rather than two views of one. On
one measured variant the GUI reported `LGTHR 28% / LGSB 19% / NOTSEL 19%` where the counter-based
figures gave `NOTSEL 42% / MATHPT 34% / LGSB 3.4%`. **Compare directions, never absolute values.**
Per-instruction and per-source-line attribution live in the same container and do **not** need the
GUI: `gputrace-extract.py` locates the blob table and the PC-sample buffers by structure, and
`pcs-lines.py` turns them into a per-source-line table — wrapped by `gputrace-sampling.ps1`,
which adds Python discovery, the aggregate cross-check gate and a JSON report. Against a
same-capture GUI export the decode reproduces 122/122 lines at Spearman rho 1.0000 (top-20
overlap 20/20, residual 0.0011%); any note calling this step GUI-only is stale.

**Two stall metrics are pipe-qualified.** `long_scoreboard_pipe_l1tex` is long-scoreboard on the
L1TEX pipe only, and `mio_throttle_pipe_mio` similarly. They are subsets, so any share computed by
dividing by the sum of the reasons understates every other reason. The report marks them `(subset)`.

**Clock differences survive into `rate` and `peak-normalised` figures.** Traces are separate
process runs, so the SM clock can differ between them. `ngfx --lock-gpu-clocks` (help names
`set-gpu-clocks` as its replacement) removes this; the scripts do not currently pass it.

**The profiler costs about 18%, uniformly.** Ratios between variants survive; absolute times do
not. Time the application with its own harness, never from these traces.

## Which numbers to quote

| Question | Trust | Quote |
| --- | --- | --- |
| Did the instruction count go down? | `count` | Yes — exactly, and it is clock-independent. |
| Did occupancy go up? | `registers` + `rate` | Yes — cross-checked against a second API. |
| Did memory behaviour change? | `ratio` | L1 sector hit rate, stable to 0.1%. |
| Is it faster? | — | **Not from here.** Time it with the application's own harness. |
| Where are the warps stalling, per source line? | `sampled` | Yes — `gputrace-sampling.ps1 -Trace <capture>` decodes the warp-state samples in the capture container into a per-source-line table, no GUI. Count-weighted, so compare ranks and shapes, not absolute percentages against GUI panel values. |

## License

MIT — see [LICENSE](LICENSE).
