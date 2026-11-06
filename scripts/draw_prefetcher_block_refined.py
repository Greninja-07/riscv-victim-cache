"""Refine the supplied HTML diagram against rtl/prefetch/prefetcher.v.

Exports a report-resolution PNG, vector SVG, and standalone editable HTML.
"""
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Polygon

OUT = Path(__file__).resolve().parents[1] / 'docs'
INK, BLUE, GREEN = '#203447', '#19699b', '#23745d'
plt.rcParams['font.family'] = 'DejaVu Sans'
fig, axes = plt.subplots(2, 2, figsize=(25, 17))
fig.patch.set_facecolor('white')

def panel(ax, title):
    ax.set(xlim=(0,100), ylim=(0,100)); ax.axis('off')
    ax.add_patch(FancyBboxPatch((.5,.5),99,99,boxstyle='round,pad=0,rounding_size=1',
        facecolor='#fafcfe', edgecolor='#c6d2dd', lw=1.2))
    ax.text(4,96,title,va='top',fontsize=16,weight='bold',color=INK)

def box(ax,x,y,w,h,title,body='',seq=False,fs=11):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle='round,pad=0,rounding_size=.7',
        facecolor='#e7f1fa' if seq else 'white',edgecolor=BLUE if seq else '#728798',lw=1.3))
    ax.text(x+w/2,y+h-3,title,ha='center',va='top',fontsize=12,weight='bold',color=INK)
    if body: ax.text(x+w/2,y+(h-5)/2,body,ha='center',va='center',fontsize=fs,color=INK,linespacing=1.5)
    if seq:
        ax.add_patch(Polygon([(x+2,y),(x+3.3,y+1.7),(x+4.6,y)],closed=False,fill=False,edgecolor=BLUE,lw=1))

def arrow(ax,points,label='',color=BLUE,at=None):
    for p,q in zip(points[:-2],points[1:-1]): ax.plot([p[0],q[0]],[p[1],q[1]],color=color,lw=1.4)
    ax.annotate('',xy=points[-1],xytext=points[-2],arrowprops=dict(arrowstyle='-|>',color=color,lw=1.4))
    if label:
        p,q=points[0:2]; x,y=at or ((p[0]+q[0])/2,(p[1]+q[1])/2+2)
        ax.text(x,y,label,ha='center',va='center',fontsize=10,color=color,
            bbox=dict(facecolor='#fafcfe',edgecolor='none',pad=1))

def note(ax,x,y,text,fs=10): ax.text(x,y,text,ha='left',va='top',fontsize=fs,color=INK,linespacing=1.5)

a=axes[0,0]; panel(a,'A   Load training and stride prediction')
box(a,4,71,24,17,'PC split','load_pc[31:0]\nindex = PC[4:2]\nPC tag = PC[14:5]')
box(a,38,65,57,23,'RPT: 8 entries','Per entry: valid (1), PC tag (10), last address (32),\nsigned stride (16), confidence (2)',True)
arrow(a,[(28,79),(38,79)],'index / tag',at=(33,83))
box(a,4,33,28,22,'Stride difference','diff = load_addr − last_addr\nnew_stride = diff[15:0]')
arrow(a,[(48,65),(48,60),(18,60),(18,55)],'last address',at=(37,60))
note(a,5,29,'load_addr[31:0] → difference and candidate adder')
box(a,40,33,55,22,'Training / confidence update','PC mismatch: initialize entry\nChanged nonzero stride: learn stride, INIT\nRepeated nonzero stride: INIT → TRANSIENT → STEADY\nZero stride: hold entry',fs=10)
arrow(a,[(32,44),(40,44)])
arrow(a,[(79,55),(79,65)],'write back',at=(87,60))
note(a,5,20,'train_fire = is_load & !load_stall & prefetch_en & !cache_bypass\nPrediction uses the selected RPT entry and stored stride → panel B.\nNO_PRED (11) is declared, but normal training does not enter it.',11)

a=axes[0,1]; panel(a,'B   Candidate generation and pending request')
box(a,4,66,36,22,'One candidate adder','Sign-extend stored stride: 16 → 32\ntarget = load_addr + stride_ext\nline = {target[31:4], 4\'b0}')
box(a,51,54,44,34,'Candidate validation','train_fire; RPT valid and PC tag match\nSTEADY, or TRANSIENT with matching\nnonzero new_stride\nline < 16384; different from current line\n!l1_tag_hit; no valid buffer-tag match\nno valid in-flight-tag match',fs=10)
arrow(a,[(40,77),(51,77)],'line[31:0]',at=(45,82))
box(a,51,22,44,18,'Single pending register','pending_addr[31:0] + pending_valid',True)
arrow(a,[(73,54),(73,40)],'cand_valid',at=(84,47))
note(a,5,51,'From A:\nstored stride, confidence,\nnew_stride, valid / PC match\n\nFrom C / D:\nin-flight and buffer tags')
arrow(a,[(73,22),(73,11)],'pending request → C',at=(73,8))
note(a,5,18,'Single-stride lookahead\n16-byte aligned target address',10)

a=axes[1,0]; panel(a,'C   Memory arbitration and store coherence')
box(a,4,65,44,23,'Arbiter FSM','S_IDLE → S_PREF_WAIT:\n!l1_mem_req & l1_idle & pending_valid\nS_PREF_WAIT → S_IDLE: main_mem_ack',True)
box(a,57,65,38,23,'In-flight registers','inflight; inflight_tag[27:0]\ninflight_invalid',True)
arrow(a,[(48,77),(57,77)],'issue',at=(52,82))
box(a,4,31,44,22,'Request / address / WE logic','In-flight prefetch holds the memory bus\nIn IDLE: demand precedes pending prefetch\nmain_mem_addr selects demand, pending,\nor {inflight_tag, 4\'b0}',fs=10)
arrow(a,[(24,65),(24,53)])
arrow(a,[(48,42),(55,42)],'→ main memory',at=(72,45))
note(a,57,36,'main_mem_ack / rdata → FSM + D\nWrite data passes through unchanged:\nmain_mem_wdata = l1_mem_wdata',10)
box(a,4,5,91,18,'Store-tag comparisons','store_valid + store_addr[31:4]: clear matching buffer valid; cancel matching pending;\nmark matching in-flight transfer invalid (inflight_invalid).',fs=10)
arrow(a,[(76,65),(76,57)],'tag → D',at=(85,60))

a=axes[1,1]; panel(a,'D   Single-entry buffer and demand response')
box(a,4,67,43,21,'Prefetch buffer','pf_valid (1) | pf_tag[27:0]\npf_data[127:0] = one 16-byte line',True)
box(a,57,67,38,21,'Demand tag comparison','buffer valid & matching demand tag\n& !l1_mem_we & pref_active',fs=10)
arrow(a,[(47,78),(57,78)],'tag',at=(52,83))
note(a,5,62,'On prefetch ack: buffer the line if no same-line demand merge\nand !inflight_invalid. Buffer hit consumes the valid entry.',10)
box(a,4,25,43,23,'Read-data selector','l1_mem_rdata = pf_data on active buffer hit;\notherwise main_mem_rdata\nSelect: pref_active & l1_hit_pf_buf',fs=10)
box(a,57,25,38,23,'ACK and hit logic','Buffer hit or merge: ACK = 1\nOther demand during PREF_WAIT: ACK = 0\nElse: forward main_mem_ack',fs=10)
arrow(a,[(4,75),(2,75),(2,50),(25,50),(25,48)])
arrow(a,[(77,67),(97,67),(97,52),(77,52),(77,48)],'buffer hit',at=(87,52))
note(a,5,20,'merge_hit = active & PREF_WAIT & main_mem_ack & l1_mem_req\n                      & same in-flight tag & !l1_mem_we\nprefetch_hit = active buffer-demand hit OR merge_hit OR registered pf_hit_pulse',10)

fig.text(.035,.974,'Stride Data Prefetcher',fontsize=28,weight='bold',color=INK)
fig.text(.035,.944,'RTL block diagram  •  32-bit addresses  •  128-bit lines  •  8-entry RPT  •  one-entry prefetch buffer',fontsize=15,color=BLUE)
fig.text(.035,.045,'Blue blocks with a clock mark are registers; white blocks are combinational logic. Named signals connect panels. External L1 and main memory are outside the module.',fontsize=11,color=INK)
fig.text(.035,.025,'All registers use clk. rst or !prefetch_en resets the module. pref_active = prefetch_en & !cache_bypass; when inactive, the memory bus passes through.',fontsize=11,color=INK)
fig.subplots_adjust(left=.025,right=.98,bottom=.075,top=.925,wspace=.04,hspace=.055)
stem=OUT/'prefetcher_block_diagram_refined'
fig.savefig(stem.with_suffix('.png'),dpi=180,facecolor='white')
fig.savefig(stem.with_suffix('.svg'),facecolor='white')
svg=stem.with_suffix('.svg').read_text(encoding='utf-8')
svg=svg[svg.index('<svg'):]
stem.with_suffix('.html').write_text('<!doctype html><html><head><meta charset="utf-8"><title>Stride Prefetcher — Corrected RTL Block Diagram</title><style>body{margin:0;background:white}svg{display:block;width:100%;height:auto}</style></head><body>'+svg+'</body></html>',encoding='utf-8')
print('Saved refined PNG, SVG, and standalone HTML to docs.')
