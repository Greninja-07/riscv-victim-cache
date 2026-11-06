"""Connected schematic of the README's degree-2, four-entry architecture."""
from pathlib import Path
from html import escape
import math
import pymupdf

OUT=Path(__file__).resolve().parents[1]/'docs'
W,H=3300,1650
B='#246ca1'; C='#8150a0'; G='#24815c'; R='#bd4942'; INK='#253d50'
shapes=[]; wires=[]; labels=[]
def txt(x,y,s,size=22,color=INK,anchor='middle',bold=False):
    labels.append(f'<text x="{x}" y="{y}" font-family="Arial, sans-serif" font-size="{size}" fill="{color}" text-anchor="{anchor}" font-weight="{"bold" if bold else "normal"}">{escape(s)}</text>')
def block(x,y,w,h,title,lines,seq=False,color=B):
    shapes.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{"#eaf3fa" if seq else "#ffffff"}" stroke="{color}" stroke-width="3"/>')
    txt(x+w/2,y+43,title,27,bold=True)
    for i,s in enumerate(lines):txt(x+w/2,y+86+34*i,s,21)
    if seq:shapes.append(f'<path d="M{x+18},{y+h} l14,-18 l14,18" fill="none" stroke="{color}" stroke-width="2"/>')
def edge(points,label='',color=B,at=None):
    wires.append(f'<polyline points="{" ".join(f"{x},{y}" for x,y in points)}" stroke="{color}" stroke-width="3" fill="none" stroke-linejoin="round"/>')
    a,b=points[-2:];dx,dy=b[0]-a[0],b[1]-a[1];n=math.hypot(dx,dy);ux,uy=dx/n,dy/n
    p=[b,(b[0]-12*ux+5*uy,b[1]-12*uy-5*ux),(b[0]-12*ux-5*uy,b[1]-12*uy+5*ux)]
    wires.append(f'<polygon points="{" ".join(f"{x},{y}" for x,y in p)}" fill="{color}"/>')
    if label:
        x,y=at
        # White backing keeps routed lines out of signal labels.
        width=len(label)*10.4+12
        labels.append(f'<rect x="{x-width/2}" y="{y-23}" width="{width}" height="30" rx="3" fill="white"/>')
        txt(x,y,label,21,color)
def dot(x,y,color=B):wires.append(f'<circle cx="{x}" cy="{y}" r="6" fill="{color}"/>')

txt(1650,58,'Two-Degree Stride Prefetcher — Connected Block Diagram',39,bold=True)
txt(1650,101,'Intended architecture from README: 8-entry RPT • 2 lookahead candidates • 4-entry prefetch buffer • 32-bit addresses / 128-bit cache lines',23)

block(80,220,390,260,'Load snoop / training',[
    'load_pc[31:0], load_addr[31:0]',
    'is_load, load_stall',
    'train_fire gates RPT updates',
    'new_stride = Δaddr[15:0]',
    'Initialize / learn / confirm stride'])
block(600,220,420,260,'Reference prediction table',[
    '8 entries; index = PC[4:2]',
    'PC tag[9:0] + valid',
    'Last address[31:0]',
    'Signed stride[15:0] + conf[1:0]',
    'INIT / TRANSIENT / STEADY'],True)
block(1150,220,440,260,'Candidate address generation',[
    'Sign-extend stride to 32 bits',
    'Candidate 1 = load_addr + stride',
    'Candidate 2 = load_addr + 2×stride',
    'Align both addresses to 16 bytes',
    'Forward current-line address'])
block(1720,220,450,260,'Candidate validation',[
    'Training / confidence / PC match',
    'Target < 16384; different line',
    '!l1_tag_hit; no buffer duplicate',
    'No in-flight duplicate',
    'Qualify each candidate separately'])
block(2300,220,400,260,'Pending request queue',[
    'pending_addr + valid',
    'pending_addr2 + valid',
    'Candidate 1 then candidate 2',
    'Shift / clear on issue',
    'Store-match cancellation'],True)

block(80,700,390,280,'L1 cache interface',[
    'Demand req / we / addr / wdata',
    'l1_idle and l1_tag_hit',
    'Receives refill data + ack',
    'Demand reads may hit PF buffer',
    'Stores supply coherence snoop'])
block(600,700,420,280,'Response selection',[
    '128-bit read-data MUX',
    'Select PF line on buffer hit',
    'Else return main-memory data',
    'ACK: buffer hit / same-line merge',
    'Otherwise arbiter / memory ACK'])
block(1150,700,440,280,'Demand buffer lookup',[
    '4 × (demand tag == PF tag)',
    'Qualify by valid / read / enable',
    'Hit OR + priority encoder',
    'hit_idx selects 4:1 data MUX',
    'Consume the hit buffer entry'])
block(1720,700,450,280,'Prefetch buffer: 4 entries',[
    'Each: valid + tag[27:0]',
    'Each: data[127:0] (16-byte line)',
    'Allocation / replacement control',
    'Write on valid prefetch return',
    'Store-match invalidation'],True)
block(2300,700,400,280,'Memory arbiter + in-flight',[
    'S_IDLE / S_PREF_WAIT',
    'Demand has priority before issue',
    'Track tag / valid / invalid',
    'Same-line demand merge logic',
    'Store match → mark invalid'],True)
block(2860,700,350,280,'Main memory',[
    'req / we / addr[31:0]',
    'wdata[127:0]',
    'ack + rdata[127:0]',
    'External to prefetcher'])
block(600,1220,420,170,'Hit reporting',[
    'Buffer hit OR in-flight merge',
    'Combinational hit + pulse register',
    'prefetch_hit → profiler'],True,color=C)
block(80,1290,390,160,'Store snoop input',[
    'store_valid',
    'store_addr[31:0]'],color=R)
block(1720,1290,980,160,'Store coherence broadcast',[
    'store_tag = store_addr[31:4]; store_valid qualifies every comparison',
    'Buffer: invalidate match • Pending queue: cancel match • In-flight: mark invalid'],color=R)

# Training and prediction datapath.
edge([(470,340),(600,340)],'RPT write',at=(535,321))
edge([(810,220),(810,166),(280,166),(280,220)],'last_addr / stored stride / confidence',at=(540,151))
edge([(1020,340),(1150,340)],'stride',at=(1085,321))
edge([(470,420),(520,420),(520,545),(1300,545),(1300,480)],'load_addr[31:0]',at=(910,531))
edge([(1590,340),(1720,340)],'targets',at=(1655,321))
edge([(990,480),(990,510),(1770,510),(1770,480)],'RPT valid / PC match / confidence / train_fire',C,at=(1430,497))
edge([(2170,340),(2300,340)],'addr + valid',at=(2235,321))
edge([(2500,480),(2500,700)],'pending address + valid',at=(2500,585))
edge([(2380,700),(2380,640),(2280,640),(2280,420),(2300,420)],'pop / shift',C,at=(2270,617))

# Feedback paths: tags go to filtering, demand status goes to arbiter and lookup.
edge([(1945,700),(1945,480)],'PF tags / valids',C,at=(1945,593))
edge([(2300,745),(2230,745),(2230,550),(2100,550),(2100,480)],'in-flight tag / valid',C,at=(2100,536))
edge([(280,700),(280,610),(2470,610),(2470,700)],'L1 demand req / we / addr / wdata + l1_idle',at=(1430,596))
edge([(1360,610),(1360,700)],color=B);dot(1360,610)
edge([(350,700),(350,570),(1835,570),(1835,480)],'l1_tag_hit',C,at=(690,556))

# Main-memory exchange and returned prefetch fill.
edge([(2700,780),(2860,780)],'request bus',G,at=(2780,760))
edge([(2860,890),(2700,890)],'ack / rdata',G,at=(2780,872))
edge([(2300,805),(2170,805)],'PF fill',G,at=(2235,789))
edge([(2300,935),(2260,935),(2260,1090),(955,1090),(955,980)],'main_mem_rdata + memory ACK / arbiter status',G,at=(1690,1075))

# Buffer tags, indexed data, hit and consume paths.
edge([(1720,785),(1590,785)],'tags / V',at=(1655,768))
edge([(1720,915),(1660,915),(1660,1020),(1485,1020),(1485,980)],'4 × 128-bit lines',at=(1700,1005))
edge([(1590,865),(1630,865),(1630,665),(2080,665),(2080,700)],'consume hit_idx / clear valid',C,at=(1835,650))
edge([(1150,805),(1020,805)],'data / hit',at=(1085,787))
edge([(2430,980),(2430,1135),(875,1135),(875,980)],'merge_hit + returned memory data selection',C,at=(1650,1120))
edge([(600,850),(470,850)],'rdata / ACK',at=(535,831))
edge([(1360,980),(1360,1175),(945,1175),(945,1220)],'buffer hit',C,at=(1120,1161))
edge([(2430,1135),(2430,1200),(810,1200),(810,1220)],'merge_hit',C,at=(1870,1186));dot(2430,1135,C)
edge([(600,1310),(520,1310),(520,1180),(80,1180)],'prefetch_hit → profiler',C,at=(285,1166))

# Coherence: a physical broadcast to each local comparator bank.
edge([(470,1370),(500,1370),(500,1480),(1680,1480),(1680,1370),(1720,1370)],'store_valid + store_addr[31:0]',R,at=(1110,1466))
edge([(2080,1290),(2080,980)],'store tag / valid',R,at=(2080,1245))
edge([(2600,1290),(2600,980)],'store tag / valid',R,at=(2600,1245))
edge([(2700,1380),(2780,1380),(2780,410),(2700,410)],'store tag / valid → pending cancellation',R,at=(2900,1150))

txt(1650,1520,'Blue: prediction / demand data   •   Purple: control / feedback / hit   •   Green: memory return   •   Red: store coherence',22)
txt(1650,1560,'Dots mark branches; crossings without dots are separate nets. Blue-filled blocks contain registers. clk and reset/enable controls apply to all sequential blocks.',21)
txt(1650,1600,'Architecture-level connectivity for the degree-2, four-entry design described in the README; not a gate-level netlist of the differing local RTL.',21,'#687c8c')
svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}"><rect width="{W}" height="{H}" fill="#fff"/>'+''.join(shapes+wires+labels)+'</svg>'
stem=OUT/'prefetcher_connected_block_diagram'
stem.with_suffix('.svg').write_text(svg,encoding='utf-8')
stem.with_suffix('.html').write_text('<!doctype html><html><head><meta charset="utf-8"><title>Connected Stride Prefetcher</title><style>body{margin:0}svg{width:100%;height:auto}</style></head><body>'+svg+'</body></html>',encoding='utf-8')
d=pymupdf.open(stem.with_suffix('.svg'));d[0].get_pixmap(matrix=pymupdf.Matrix(1.8,1.8)).save(stem.with_suffix('.png'))
print('Exported connected PNG, SVG, and HTML.')
