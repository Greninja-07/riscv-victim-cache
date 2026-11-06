"""Render the settled simulation trace; no hand-authored output waveforms."""
import csv
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs"
with (OUT / "prefetcher_timing_20cycles.csv").open() as f:
    rows = list(csv.DictReader(f))
# Start the viewport at the first simulated rising edge; shift every signal
# together so clock phase, input setup, and registered outputs remain aligned.
first_rise = next(float(r["time_ns"]) for r in rows if r["clk"] == "1")
rows = [r for r in rows if float(r["time_ns"]) >= first_rise]
times = [round(float(r["time_ns"]) - first_rise, 2) for r in rows]
if times[-1] < 200:
    rows.append(dict(rows[-1]))
    times.append(200.0)
signals = [
    ("clk", "clk", False), ("rst", "rst", False),
    ("is_load", "is_load", False), ("load_addr", "load_addr [31:0]", True),
    ("rpt_conf", "rpt_conf[0] [1:0]", True),
    ("pending_valid", "pending_valid", False),
    ("main_mem_req", "main_mem_req", False),
    ("main_mem_addr", "main_mem_addr [31:0]", True),
    ("inflight", "inflight", False),
    ("main_mem_ack", "main_mem_ack", False),
    ("pf_valid", "pf_valid", False), ("pf_tag", "pf_tag [27:0]", True),
    ("l1_mem_req", "l1_mem_req", False),
    ("l1_mem_addr", "l1_mem_addr [31:0]", True),
    ("l1_mem_ack", "l1_mem_ack", False),
    ("prefetch_hit", "prefetch_hit", False),
]
fig, ax = plt.subplots(figsize=(22, 11.7))
fig.subplots_adjust(left=.16, right=.985, bottom=.18, top=.84)
blue = "#1467a1"
for cycle in range(20):
    ax.axvspan(cycle*10, cycle*10+10, color="#eef3f8" if cycle%2 == 0 else "white", zorder=0)
    ax.axvline(cycle*10, color="#bdc7d1", lw=.6, ls=":", zorder=1)
    ax.text(cycle*10+5, len(signals)+.08, str(cycle+1), ha="center", fontsize=12)
for index, (key, label, bus) in enumerate(signals):
    y = len(signals)-1-index
    ax.text(-2, y+.32, label, ha="right", va="center", fontsize=12, fontfamily="DejaVu Sans Mono")
    values = [r[key] for r in rows]
    color = blue if key in {"main_mem_req", "pf_valid", "prefetch_hit"} else "#182b3a"
    if not bus:
        nums = [int(v) if v in ("0", "1") else 0 for v in values]
        ax.step(times, [y+.08+.53*v for v in nums], where="post", color=color, lw=1.65)
        for j, v in enumerate(values[:-1]):
            if v not in ("0", "1"):
                a, b = times[j], times[j+1]
                ax.fill_between([a,b], y+.05, y+.62, color="#e5d8bc", zorder=3)
                ax.text((a+b)/2,y+.32,"X",ha="center",va="center",fontsize=9,zorder=4)
    else:
        start = 0
        for j in range(1, len(values)+1):
            if j == len(values) or values[j] != values[start]:
                a = times[start]
                b = times[j] if j < len(values) else 200
                if b > a:
                    v = values[start]
                    if key == "rpt_conf":
                        text = {"0":"INIT (00)", "1":"TRANSIENT\n(01)", "2":"STEADY (10)"}.get(v, "X")
                    else:
                        try: text = f"0x{int(v, 16):03X}"
                        except ValueError: text = "X"
                    d = min(.65, (b-a)/4)
                    ax.plot([a,a+d,b-d,b], [y+.32,y+.59,y+.59,y+.32], color=color,lw=1.2)
                    ax.plot([a,a+d,b-d,b], [y+.32,y+.05,y+.05,y+.32], color=color,lw=1.2)
                    ax.text((a+b)/2,y+.32,text,ha="center",va="center",fontsize=8 if key == "rpt_conf" and v == "1" else 10)
                start = j
ax.set_xlim(0,200)
ax.set_ylim(-.35,len(signals)+.65)
ax.set_xticks(range(0,201,10))
ax.set_xlabel("Time from first rising edge (ns)   |   20 periods, 10 ns each; rising edges at 0, 10, ... , 190 ns", fontsize=12, labelpad=10)
ax.set_yticks([])
for spine in ax.spines.values(): spine.set_visible(False)
fig.text(.16,.95,"Stride prefetcher — 20-cycle timing diagram",fontsize=24,weight="bold",color="#182b3a")
fig.text(.16,.91,"Simulated from current RTL + main_memory.v  |  +16-byte stride  |  memory latency N = 10",fontsize=14,color=blue)
fig.text(.16,.865,"Cycle",fontsize=11)
fig.text(.16,.105,"Inputs: prefetch_en=1; cache_bypass=0; load_pc=0x00001000; load_stall=0; store_valid=0; l1_tag_hit=0; l1_mem_we=0.",fontsize=11)
fig.text(.16,.080,"l1_idle = !l1_mem_req. Isolated prefetcher training test. Cycle 1 starts high at the reset edge; all signal times share the same origin. Hex labels omit leading zeros.",fontsize=11)
fig.text(.16,.055,"C2–C5: train 0x100, 0x110, 0x120, 0x130. C5: predict 0x140. C6: memory accepts. C15: ack rises. C16: buffer fills (tag 0x014).",fontsize=11)
fig.text(.16,.030,"155 ns: demand 0x140 hits buffer immediately. C17: L1 samples ack, drops request; buffer consumed. Hit pulse clears at C18; tag retains 0x014.",fontsize=11)
for extension in ("png", "svg"):
    fig.savefig(OUT / f"prefetcher_timing_20cycles.{extension}", dpi=180, facecolor="white")
print("Rendered simulation-derived PNG and SVG.")
