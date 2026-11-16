# gputrace-mcp — headless GPU Trace 分析的 MCP server

让 LLM agent 无需人工介入即可**抓取、解析、校验、对比** Nsight Graphics GPU Trace 数据——包括
GUI Top Stall 表的同源采样数据（warp-state sampling），以及逐源码行采样归因（GUI Source
Positions 的数据，`gputrace_source_lines`）。

依赖：Windows + Nsight Graphics + PowerShell，无 Node/包安装。唯一例外：`gputrace_source_lines`
的容器解码需要 **Python 3**（仅标准库、无包；用工具的 `python` 输入参数或 `$env:GPUTRACE_PYTHON`
指定解释器）。没有 Python 时该工具返回结构化错误，其余工具不受影响。

## 安装

1. 安装 Nsight Graphics（含 `ngfx.exe`）。
2. **解锁计数器（一次性）**：NVIDIA 控制面板 → 开发者 → 管理 GPU 性能计数器 → "允许所有用户访问"。
   没有这一步时抓取会走 UAC 提权重启（需要人在场点一次）；设置后永久免提权。
3. 把 server 注册进你的 MCP 客户端（见下）。

## 客户端配置片段

ZCode（`~/.zcode/config.json` 或工作区 MCP 配置）：

```json
{
  "mcpServers": {
    "gputrace": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
               "<本仓库路径>\\mcp\\server.ps1"]
    }
  }
}
```

Claude Desktop / 其它客户端同理：command 指向 `powershell.exe`，args 指向本目录的 `server.ps1`。
server 默认在上层目录的 `cli\` 子目录找 CLI；若你把它单独放到别处，设环境变量
`GPUTRACE_TOOLS_DIR` 指向含 `gputrace-capture.ps1` 与 `gputrace-report.ps1` 的目录。

## 抓取目标（profile）

抓取目标由 profile 描述（`profiles/*.json`）：exe、工作目录、架构、应用参数、超时参数模板、变体列表。
内置 `ntc-benchmark`（Bear 的 decode 三变体）作为完整示例，`profiles/example.json` 是待填模板。
新应用 = 新 profile 文件，无需改代码；接入前先跑 `-DryRun` 自检。

## 工具

| 工具 | 用途 |
| --- | --- |
| `gputrace_capture` | 按 profile 抓取（warp-state sampling 默认开启，即 GUI Top Stall 同源数据），自动导出全部指标 |
| `gputrace_report` | 单目录校验 + JSON 报告：耗时拆解、focus 指标、计数器 stall（16 项）、采样 stall（20 项）、provenance |
| `gputrace_compare` | 2+ 目录对比（同一工作负载的不同版本） |
| `gputrace_list_metrics` | 全部指标实例（含同名多实例 `#2`，不同汇总层级数值可差数倍） |
| `gputrace_raw_metric` | 按正则拉原始逐帧行（审计用） |
| `gputrace_source_lines` | 直接解码 `.ngfx-gputrace` 容器，输出逐源码行采样归因（GUI Source Positions 的数据，无需 GUI）。每行带两个主导 stall 原因；解码结果先对拍抓帧自身的 `GPUTrace.PCSampler.*` 聚合（>1.0 pp 拒绝返回）。需要 Python 3（仅标准库）；冷解码需数分钟 |

## 准确性契约（内置于每个 report/compare 响应）

1. **校验失败的抓取拒绝返回**——report/compare 先跑 8 项结构校验（事件-帧时间预算、采样出处、
   warp-width 不变量、寄存器对拍等），失败即返回错误而非数据。
2. **每个数值带证据类**：`sampled`（warp-state 采样，= GUI Top Stall 同源）/ `count`（确定性事件
   计数）/ `rate`（每周期均值）/ `peak-normalised`（对假设峰值的占比）/ `time`（有界抖动时长）。
3. **聚合语义声明**：GUI 显示的是全程时间加权值（含空闲帧），导出中位数只覆盖抓取帧——同一抓取
   两者相差 2-3% 属正常；方向性差异才有意义。

## 已知边界

- **逐源码行采样归因（Source Positions）** 不在结构化 CSV 导出里，但**不需要 GUI**：
  `gputrace_source_lines` 工具直接解码 trace 容器产出逐源码行表（每行的样本数与 stall 构成）。
  该解码是本工具唯一需要 **Python 3**（仅标准库、无包）的部分——用 `python` 输入参数或
  `$env:GPUTRACE_PYTHON` 指定解释器；未配置时返回结构化错误并给出补救说明。对拍同抓帧 GUI
  导出可复现 122/122 行、rho 1.0000。
- **per-PSO Instruction Mix**（每个着色器的指令构成统计）仍无 headless 通路。
- Nsight Graphics 2026.1 + Ada 实测；其它架构/版本的指标名集合可能不同——先用
  `gputrace_list_metrics` 确认。
- GeForce 无 NVCP 解锁时每次抓取需要一次 UAC 点击（MCP 会返回 `elevatedViaUac: true` 提示）。
- 采样开启会替换一部分普通计数器（NVIDIA 设计）；两套 stall（`sampled` 与计数器版）互补。

## 本机实测记录（2026-10-11）

- 三 arm 采样抓取 + 对比：decode 耗时 arm0=2.179 / arm1=1.331 / arm2=1.291 ms；
  采样 stall top：Not Selected ~11-12%、Math Pipe Throttle ~8.6-9.5%（pct_of_peak）。
  向量化变体的 Long Scoreboard(L1TEX) 从 0.97% 升至 ~9.9%、L1TEX 命中率降 7 个点——
  计算瓶颈换访存延迟的典型画像。
- 同 trace GUI vs 导出逐项对比：8 项面板值全部吻合（差 2-3%，聚合语义解释见上）。
