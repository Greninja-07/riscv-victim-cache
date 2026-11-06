"""Clean spacing and routing in the supplied two-degree/four-entry diagram."""
from pathlib import Path
from html import escape
import pymupdf

OUT = Path(__file__).resolve().parents[1] / 'docs'
parts = []
BLUE='#2980b9'; INK='#2c3e50'; PURPLE='#8e44ad'; RED='#c0392b'; GREEN='#238b57'
def text(x,y,value,size=17,color=INK,anchor='middle',bold=False):
    parts.append(f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-family="Arial, sans-serif" font-size="{size}" fill="{color}" font-weight="{"bold" if bold else "normal"}">{escape(value)}</text>')
def rect(x,y,w,h,fill='white',stroke=INK,lw=2):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" stroke="{stroke}" stroke-width="{lw}"/>')
def box(x,y,w,h,title,lines=(),fill='white',stroke=INK,size=17):
    rect(x,y,w,h,fill,stroke);text(x+w/2,y+29,title,19,bold=True)
    for i,line in enumerate(lines): text(x+w/2,y+60+i*25,line,size)
def section(x,y,w,h,title):
    rect(x,y,w,h,'#fbfcfd','#c4cdd4',1.5);text(x+18,y+31,title,21,anchor='start',bold=True)
def wire(points,color=BLUE,width=2.4,arrow=True):
    parts.append(f'<polyline points="{" ".join(f"{x},{y}" for x,y in points)}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linejoin="round"/>')
    if arrow:
        import math
        a,b=points[-2:]; dx,dy=b[0]-a[0],b[1]-a[1]; n=math.hypot(dx,dy)
        if n:
            ux,uy=dx/n,dy/n
            pts=[b,(b[0]-9*ux+4*uy,b[1]-9*uy-4*ux),(b[0]-9*ux-4*uy,b[1]-9*uy+4*ux)]
            parts.append(f'<polygon points="{" ".join(f"{x},{y}" for x,y in pts)}" fill="{color}"/>')
def circle(x,y,symbol):
    parts.append(f'<circle cx="{x}" cy="{y}" r="27" fill="#e8f8f5" stroke="#16a085" stroke-width="2"/>');text(x,y+8,symbol,27,bold=True)
def mux(x,y,w,h,label):
    parts.append(f'<polygon points="{x},{y} {x+w},{y+25} {x+w},{y+h-25} {x},{y+h}" fill="#fdf2e9" stroke="#d35400" stroke-width="2"/>')
    text(x+w/2,y+h/2,label,18,bold=True)

parts.append('<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="1490" viewBox="0 0 2400 1490">')
parts.append('<rect width="2400" height="1490" fill="white"/>')
text(1200,43,'Hardware Multi-Degree Stride Data Prefetcher',31,bold=True)
text(1200,76,'Degree 2  •  8-entry RPT  •  4-entry fully associative prefetch buffer  •  32-bit address / 128-bit data',19,'#637583')

# Preserve the supplied left-to-right training / candidate / pending / buffer layout.
section(25,105,475,680,'Reference Prediction Table & Training')
text(55,179,'load_pc[31:0]',17,anchor='start');wire([(195,173),(220,173)])
box(220,145,105,105,'PC split',['[4:2]','[14:5]'],size=16)
box(345,145,130,280,'RPT array',['8 entries','Tag [9:0]','Valid','Conf [1:0]','Stride [15:0]','Last addr [31:0]'],fill='#fdf2e9',stroke='#d35400',size=16)
wire([(325,177),(345,177)]);wire([(325,210),(335,210),(335,235),(345,235)])
text(55,317,'load_addr[31:0]',17,anchor='start');wire([(210,312),(295,312),(295,380),(345,380)])
circle(225,485,'−')
wire([(410,425),(410,445),(225,445),(225,458)]);text(310,438,'last_addr',15)
wire([(115,329),(115,485),(198,485)]);text(118,467,'load_addr',15,anchor='start')
text(225,545,'new_stride = (load_addr − last_addr)[15:0]',16)
box(75,585,350,105,'Training control',['is_load & !load_stall','prefetch_en & !cache_bypass'],fill='#f7f0fa')
wire([(225,512),(225,529)],arrow=False)
wire([(252,485),(455,485),(455,570),(425,570),(425,620)])
wire([(75,620),(50,620),(50,405),(345,405)],PURPLE)
text(75,728,'RPT outputs → candidate stage:',17,anchor='start',bold=True)
text(75,757,'stride, confidence, valid, PC tag match',16,anchor='start')

section(530,105,315,680,'Two-Degree Candidates')
box(555,160,265,95,'Sign extension',['signed stride [15:0] → [31:0]'],size=16)
box(675,300,120,72,'Shift << 1',[],fill='#e8f8f5')
circle(610,425,'+');circle(755,425,'+')
wire([(610,255),(610,398)]);wire([(735,255),(735,300)])
wire([(735,372),(735,385),(755,385),(755,398)])
text(553,477,'load_addr',16,anchor='start')
wire([(555,485),(570,485),(570,425),(583,425)])
wire([(570,485),(840,485),(840,425),(782,425)])
box(550,535,130,95,'Align 1',['[3:0] = 0'],size=16)
box(695,535,130,95,'Align 2',['[3:0] = 0'],size=16)
wire([(610,452),(610,535)]);wire([(755,452),(755,535)])
text(615,672,'Candidate 1',17,BLUE,bold=True);text(760,703,'Candidate 2',17,BLUE,bold=True)
wire([(615,630),(615,651)],arrow=False);wire([(760,630),(760,681)],arrow=False)
text(687,754,'+1 stride                 +2 strides',16)

section(875,105,330,680,'Validation & Pending Queue')
box(895,160,290,270,'Candidate filters',[
    'Confidence / PC qualification','Address < 16384','Different from current line',
    '!l1_tag_hit','Not in prefetch buffer','Not in flight'],fill='#f4f9fd',size=17)
wire([(615,630),(615,645),(855,645),(855,250),(895,250)])
wire([(760,630),(760,655),(865,655),(865,310),(895,310)])
box(910,490,260,80,'pending_addr2',['Candidate 2 + valid'],size=17)
box(910,635,260,80,'pending_addr',['Candidate 1 + valid'],size=17)
wire([(990,430),(990,490)]);text(1035,467,'Cand 2',15,BLUE)
wire([(1135,430),(1190,430),(1190,675),(1170,675)]);text(1160,457,'Cand 1',15,BLUE)
wire([(1040,570),(1040,635)]);text(1065,609,'shift',16,BLUE,anchor='start')
wire([(1040,715),(1040,815)],PURPLE);text(1080,761,'issue',16,PURPLE,anchor='start')

section(1240,105,1135,680,'4-Entry Fully-Associative Prefetch Buffer & Demand Resolution')
text(1290,181,'Fill: main_mem_rdata[127:0] + tag + allocation slot',17,GREEN,anchor='start')
text(1470,226,'Buffer registers',18,bold=True)
text(1765,226,'Tag ==',17,bold=True);text(1870,226,'Valid AND',17,bold=True)
text(1725,195,'Demand tag = l1_mem_addr[31:4]',17,anchor='start')
for i in range(4):
    y=255+i*90
    rect(1270,y,50,57);rect(1320,y,155,57);rect(1475,y,175,57)
    text(1295,y+35,f'V{i}',17);text(1397,y+35,f'PF tag {i} [27:0]',16);text(1562,y+35,f'PF data {i}',17)
    box(1725,y,80,57,'==',[],size=16);box(1830,y,80,57,'AND',[],size=16)
    wire([(1475,y+14),(1705,y+14),(1705,y+28),(1725,y+28)])
    wire([(1805,y+28),(1830,y+28)],INK)
    # Named valid and data nets keep the diagram free of wires crossing register labels.
    text(1868,y+82,f'V{i} + tag match → H{i}',15,RED)
    wire([(1910,y+28),(1960,y+28)],RED);text(1982,y+34,f'H{i}',16,RED,anchor='start')
    text(1562,y+80,f'D{i} [127:0] → data MUX',15,BLUE)
box(2050,255,280,90,'Hit OR',['H0 | H1 | H2 | H3'],fill='#f9ebea',stroke=RED)
text(2190,374,'→ l1_hit_pf_buf',17,RED)
box(2050,410,280,100,'Priority encoder',['H[3:0] → hit_idx[1:0]'],fill='#e8f8f5',size=17)
mux(2110,565,125,150,'4:1 MUX')
for i in range(4):
    yy=590+i*28
    text(2070,yy+5,f'D{i}',17,BLUE,anchor='end');wire([(2080,yy),(2110,yy)])
wire([(2190,510),(2190,555),(2175,555),(2175,578)],PURPLE)
text(2260,550,'hit_idx',16,PURPLE)
wire([(2235,640),(2340,640)]);text(2285,682,'pf_data_mux',16,BLUE)
text(1280,707,'H0–H3: per-entry valid AND matching tag; read demand and enable qualify the buffer hit.',16,anchor='start')
text(1280,747,'Named nets D0–D3 connect the four data registers to the MUX; hit_idx selects the returned line.',16,anchor='start')

section(875,815,330,340,'FSM Memory Arbiter')
box(900,870,280,70,'State register',['S_IDLE / S_PREF_WAIT'],size=17)
box(900,965,280,75,'In-flight tracking',['tag [27:0], valid, invalid'],size=17)
box(900,1070,280,60,'Allocation MUX',[],fill='#fdf2e9')
wire([(1040,940),(1040,965)],PURPLE);wire([(1040,1040),(1040,1070)],PURPLE)

section(1240,815,1135,340,'Main Memory Interface & L1 Response Selection')
text(1270,875,'main_mem_req / main_mem_addr / main_mem_we → main memory',18,GREEN,anchor='start')
text(1270,915,'main_mem_ack / main_mem_rdata ← main memory',18,GREEN,anchor='start')
wire([(1180,1000),(1218,1000),(1218,855),(1240,855)],GREEN)
text(1450,976,'pf_data_mux [127:0]',17,BLUE)
text(1450,1036,'main_mem_rdata [127:0]',17,BLUE)
mux(1660,950,100,130,'MUX')
wire([(1560,970),(1660,970)]);wire([(1580,1030),(1660,1030)])
wire([(1760,1015),(1910,1015)]);text(1835,1090,'l1_mem_rdata [127:0]',17,BLUE)
text(2060,976,"1'b1 (hit)",17);text(2060,1036,'main_mem_ack',17)
mux(2170,950,85,130,'MUX')
wire([(2120,970),(2170,970)],INK);wire([(2145,1030),(2170,1030)],INK)
wire([(2255,1015),(2340,1015)],INK);text(2290,1090,'l1_mem_ack',17)
text(1270,1124,'Response control: buffer hit / in-flight merge, arbiter state and bypass mode.',17,anchor='start')

section(25,1185,2350,230,'Store Coherence & Invalidation Broadcast Network')
text(60,1270,'store_addr[31:0]',19,anchor='start');box(285,1230,120,75,'[31:4]',[])
wire([(240,1263),(285,1263)])
text(500,1252,'store_tag [27:0]',17,RED)
wire([(405,1265),(2240,1265)],RED,3,False)
for x,title,action in [(760,'Pending tag compare','Cancel matching pending request'),(1325,'In-flight tag compare','Set inflight_invalid'),(1910,'Buffer tag compares','Invalidate matching buffer entry')]:
    wire([(x,1265),(x,1287)],RED)
    box(x-215,1287,430,95,title,[action],fill='#fdf2f1',stroke=RED,size=17)
text(60,1350,'store_valid',19,anchor='start');text(60,1384,'qualifies comparisons',16,anchor='start')
text(1200,1455,'Blue: address / data  •  Purple: control  •  Green: memory interface  •  Red: hit / coherence  |  Named nets indicate connections without crossing unrelated blocks.',17,'#637583')
parts.append('</svg>')
svg='\n'.join(parts)
stem=OUT/'prefetcher_original_refined'
stem.with_suffix('.svg').write_text(svg,encoding='utf-8')
stem.with_suffix('.html').write_text('<!doctype html><html><head><meta charset="utf-8"><title>Stride Prefetcher Block Diagram</title><style>body{margin:0;background:white}svg{width:100%;height:auto;display:block}</style></head><body>'+svg+'</body></html>',encoding='utf-8')
doc=pymupdf.open(stem.with_suffix('.svg'))
doc[0].get_pixmap(matrix=pymupdf.Matrix(2,2)).save(stem.with_suffix('.png'))
print('Updated original diagram: PNG 4800 × 2980; SVG and HTML.')
