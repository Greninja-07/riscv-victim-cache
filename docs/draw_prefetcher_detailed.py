import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle,Polygon
from pathlib import Path
O=Path(r'D:\riscv-victim-cache\docs\prefetcher_detailed');O.mkdir(exist_ok=True)
plt.rcParams['font.family']='DejaVu Sans'
pages=[]
def page(title,subtitle):
 f,a=plt.subplots(figsize=(19,12),dpi=180);a.set(xlim=(0,190),ylim=(0,120));a.axis('off');f.patch.set_facecolor('white')
 a.text(2,117,title,fontsize=19,weight='bold',va='top');a.text(2,111,subtitle,fontsize=10,va='top',color='#475569')
 a.text(2,2,'White = combinational     Blue + clock triangle = posedge register     Named wires connect rows and sheets. Default parameters: RPT=8, buffer=4, degree=2.',fontsize=9)
 f.subplots_adjust(left=.015,right=.99,top=.99,bottom=.01);pages.append((f,a,title));return a
def block(a,x,y,w,h,t,kind='logic',fs=10):
 if kind=='mux':p=Polygon([(x,y),(x+w,y+2),(x+w,y+h-2),(x,y+h)],fc='white',ec='#263746',lw=1.3)
 elif kind=='arith':p=Polygon([(x,y+h*.2),(x+w*.25,y),(x+w,y),(x+w,y+h),(x+w*.25,y+h),(x,y+h*.8),(x+w*.12,y+h*.5)],fc='white',ec='#263746',lw=1.3)
 else:p=Rectangle((x,y),w,h,fc='#dfedf8' if kind=='reg' else 'white',ec='#263746',lw=1.3)
 a.add_patch(p);a.text(x+w/2,y+h/2,t,ha='center',va='center',fontsize=fs)
 if kind=='reg':
  a.add_patch(Polygon([(x+2,y),(x+3.3,y+1.8),(x+4.6,y)],closed=False,fill=False,ec='#263746'));a.text(x+.7,y+h-2,'D',fontsize=7);a.text(x+w-2.5,y+h-2,'Q',fontsize=7)
def wire(a,x,y,x2,y2,t=''):
 a.annotate('',xy=(x2,y2),xytext=(x,y),arrowprops=dict(arrowstyle='->',lw=1,color='#334155'))
 if t:a.text((x+x2)/2,(y+y2)/2+1.4,t,ha='center',fontsize=8)
def row(a,y,inp,logic,out,kind='logic',w=57):
 a.text(3,y+6,inp,fontsize=10,va='center');wire(a,57,y+6,68,y+6);block(a,68,y,w,12,logic,kind);wire(a,68+w,y+6,137,y+6);a.text(139,y+6,out,fontsize=10,va='center')
def note(a,y,t):a.text(3,y,t,fontsize=10,va='top',linespacing=1.6)
a=page('1. RPT read and training datapath','Combinational reads; synchronous updates. Each RPT field has its own read mux and write enable.')
row(a,91,'load_pc[4:2] = train_idx','3-to-8 DECODER','entry_sel[7:0]')
row(a,73,'8 × rpt_last_addr[31:0]\nselect = train_idx','8:1 MUX, 32-bit','last_addr_selected','mux')
row(a,55,'load_addr[31:0]\nlast_addr_selected[31:0]','SUBTRACT, 32-bit\nload_addr − last_addr','diff_full[31:0]\nnew_stride = diff_full[15:0]','arith')
row(a,37,'8 × {valid, tag, stride, conf}\nselect = train_idx','8:1 MUX per field\n1 / 10 / 16 / 2 bits','rv, rt, rs, rc','mux')
row(a,19,'rt[9:0], load_pc[14:5]\nrv','10-bit == comparator\nAND with rv','M = entry matches')
note(a,15,'T = is_load & !load_stall & prefetch_en & !cache_bypass.   Z = (new_stride != 0).   E = (new_stride == rs).\nRPT arrays: 8 × {valid[1], pc_tag[10], last_addr[32], stride[16], conf[2]} = 488 register bits.')
a=page('2. RPT next-data muxes and clocked registers','Replicate the register rows for i = 0…7. All updates use old Q values from before the clock edge.')
for y,field,bits,ins,sel in [(87,'rpt_valid[i]',1,'0: Q    1: 1','entry_sel[i] & T & !M'),(68,'rpt_pc_tag[i]',10,'0: Q    1: train_tag','entry_sel[i] & T & !M'),(49,'rpt_last_addr[i]',32,'0: Q    1: load_addr','entry_sel[i] & T & (!M | Z)'),(30,'rpt_stride[i]',16,'0: Q   1: 0   2: new_stride','1 if !M; 2 if M & Z & !E; else 0')]:
 a.text(3,y+8,ins,fontsize=10);block(a,64,y,27,15,'D-input\nMUX','mux');wire(a,91,y+7,110,y+7);block(a,110,y,47,15,field+'\n'+str(bits)+'-bit register','reg');wire(a,157,y+7,184,y+7,'Q → sheet 1');a.text(3,y-3,'select / enable: '+sel+(' (under entry_sel[i] & T)' if field=='rpt_stride[i]' else ''),fontsize=9)
block(a,5,7,28,12,'rc + 1','arith');block(a,43,7,45,12,'rc < 2\n2-bit comparator');block(a,99,7,30,12,'0 / rc+1 / Q\nMUX','mux');block(a,142,7,42,12,'rpt_conf[i] [1:0]','reg');wire(a,33,13,99,13,'rc+1 (data)');wire(a,65,7,112,7,'select: rc<2');wire(a,129,13,142,13)
a.text(4,103,'conf D = 0 if !M or (M & Z & !E); rc+1 if M & Z & E & rc<2; otherwise Q. Enabled by entry_sel[i] & T.',fontsize=10)
a=page('3. Candidate address arithmetic and comparators','S = sign extension of rs[15:0] to 32 bits. Align(X) = {X[31:4], 4\'b0000}; alignment and shift are wiring.')
row(a,89,'load_addr[31:0], S[31:0]','ADD, 32-bit','C1 = Align(load_addr + S)','arith')
row(a,71,'load_addr[31:0], (S << 1)','ADD, 32-bit','C2 = Align(load_addr + 2S)','arith')
row(a,53,'rc, new_stride, rs\nM, T','==2; ==1; ==stride; !=0\nAND / OR gates','P = T & M &\n(rc==2 | (rc==1 & E & Z))')
row(a,35,'Ck, load_addr, inflight_tag\npf_buf_tag[0…3], valid[0…3]','<16384; 28-bit != current\n4 × 28-bit == buffer tags\n28-bit == in-flight tag','Rk, Nk, Bk, Ik (k=1,2)')
note(a,28,'Rk = Ck < 16384; Nk = Ck[31:4] != load_addr[31:4].\nBk = OR of (pf_buf_valid[i] & pf_buf_tag[i] == Ck[31:4]); Ik = inflight & (inflight_tag == Ck[31:4]).\nV1 = P & R1 & N1 & !l1_tag_hit & !B1 & !I1.\nV2 = P & R2 & N2 & !l1_tag_hit & !B2 & !I2 & (C2[31:4] != C1[31:4]).\nV1/V2 are combinational cand1_valid/cand2_valid, despite being declared reg in Verilog.')
a=page('4. Pending request and in-flight register datapath','Each mux selects D from the listed sources. Priority rules below follow the order of nonblocking assignments in the RTL.')
for y,inp,label,bits in [(86,'Q / C1 / C2 / pending_addr2','pending_addr',32),(67,'Q / C2','pending_addr2',32),(48,'Q / 0 / 1 / pending_valid2','pending_valid, pending_valid2',2),(29,'Q / pending_addr[31:4]','inflight_tag',28),(10,'Q / 0 / 1','inflight, inflight_invalid',2)]:
 a.text(3,y+8,inp,fontsize=10);block(a,65,y,27,15,'priority\nD MUX','mux');wire(a,92,y+7,107,y+7);block(a,107,y,55,15,label+'\n'+str(bits)+' bits total','reg');wire(a,162,y+7,184,y+7,'Q')
note(a,105,'Issue I = !state & !l1_mem_req & l1_idle & pending_valid.   Finish F = state & main_mem_ack.')
a.text(3,6,'Priority: reset > bypass > FSM issue/finish > store invalidation > candidate enqueue > hold.',fontsize=9)
a=page('5. Prefetch buffer: registers, parallel comparisons and data mux','Four entries; synchronous writes, combinational read. No synchronous RAM or BRAM read port exists inside prefetcher.v.')
for i in range(4):
 x=4+i*46;block(a,x,82,39,18,f'Entry {i}\nvalid 1 | tag 28\ndata 128','reg');wire(a,x+20,82,x+20,77);block(a,x,62,39,14,'28-bit == demand tag\nAND valid');wire(a,x+20,62,x+20,57)
block(a,4,40,41,15,'OR reduce hit[3:0]\nAND !we & pref_active');block(a,55,40,38,15,'Priority encoder\nhighest hit index');block(a,107,40,28,15,'4:1 MUX\n128-bit','mux');wire(a,45,47,55,47,'hit vector');wire(a,93,47,107,47,'select');wire(a,135,47,183,47,'pf_data[127:0]')
a.text(108,61,'Entry data Q[0…3]',fontsize=10);wire(a,121,59,121,55)
row(a,19,'valid[3:0], pf_wr_ptr[1:0]','Lowest invalid priority encoder\nelse pointer MUX','alloc_slot[1:0]')
note(a,15,'Write decode: alloc_slot → 2-to-4 decoder → per-entry data/tag enables. Store invalidation: 4 × (tag == store_addr[31:4]).\nBuffer-hit consume: hit_idx → 2-to-4 decoder → valid clear. Buffer fill sets valid and writes main_mem_rdata + inflight_tag.\npf_wr_ptr: 2-bit Q → ==3 comparator + (+1) adder → 0 / Q+1 mux → D register; advance only on buffer fill.')
a=page('6. Output bus: explicit nested muxes','A = pref_active; H = l1_hit_pf_buf; W = state == S_PREF_WAIT; R = l1_mem_req; K = main_mem_ack.')
row(a,89,'pending_addr / l1_mem_addr\nselect R','2:1 MUX, 32-bit','Xaddr','mux')
row(a,71,'Xaddr / {inflight_tag, 4\'b0}\nselect W','2:1 MUX, 32-bit','Yaddr','mux')
row(a,53,'l1_mem_addr / Yaddr\nselect A','2:1 MUX, 32-bit','main_mem_addr','mux')
row(a,35,'main_mem_rdata / pf_data\nselect A & H','2:1 MUX, 128-bit','l1_mem_rdata','mux')
note(a,29,'MUX chain for main_mem_req (outer condition has priority): !A ? R : W ? 1 : (R & H) ? 0 : R ? 1 : (l1_idle & pending_valid).\nMUX chain for main_mem_we: !A ? l1_mem_we : R ? l1_mem_we : 0.\nMUX chain for l1_mem_ack: !A ? K : H ? 1 : merge_hit ? 1 : W ? 0 : K.\nmain_mem_wdata[127:0] = l1_mem_wdata[127:0] (direct wire).\nmerge_hit = A & W & K & R & !l1_mem_we & (l1_mem_addr[31:4] == inflight_tag).\nprefetch_hit = pf_hit_pulse | (A & ((R & H) | merge_hit)).')
a=page('7. FSM, pulse register and update priority','This sheet records control details that would otherwise be hidden inside a generic controller box.')
row(a,87,'!R, l1_idle, pending_valid\n!state','AND gate','I = issue')
row(a,69,'state, main_mem_ack','AND gate','F = finish')
row(a,51,'state, I, main_mem_ack','2:1 next-state MUX\nstate ? !ack : I','','mux')
block(a,145,49,39,16,'state (1 bit)\nIDLE=0, WAIT=1','reg');wire(a,125,57,145,57)
row(a,31,'(R & H) | (F & tag_equal\n& R & !l1_mem_we)','OR / AND gates','')
block(a,145,29,39,16,'pf_hit_pulse\n1-bit register','reg');wire(a,125,37,145,37)
note(a,25,'Global priority: synchronous reset (rst | !prefetch_en) > cache_bypass > normal updates.\nBypass clears state, pending valids and pulse; other registers retain their values.\nNormal per-register priority: FSM updates > hit consumption > store invalidation > candidate enqueue > hold.\nWithin RPT: confidence saturates at STEADY=2. NO_PRED=3 is declared but never assigned.\nAt F: merge uses old tag/flags; else buffer fill occurs only if old inflight_invalid=0.\nA store and fill on the same edge follow this RTL priority; no extra coherence interlock is drawn.')
a=page('8. Request, acknowledge and write-enable mux chains','Each mux is labelled condition ? upper input : lower input. Read from left to right; final mux has highest priority.')
def cascade(y,initial,stages,out):
 a.text(3,y+4,initial,fontsize=9,va='center')
 last=25
 for j,(cond,one) in enumerate(stages):
  x=30+j*29
  wire(a,last,y+4,x,y+4)
  block(a,x,y-4,19,16,cond+' ?\n1 : 0','mux',8)
  a.text(x+9,y+19,one,ha='center',fontsize=8)
  wire(a,x+9,y+16,x+9,y+12)
  last=x+19
 wire(a,last,y+4,181,y+4)
 a.text(182,y+4,out,fontsize=9,va='center',rotation=90)
cascade(83,'l1_idle &\npending_valid',[('R','1'),('R & H','0'),('W','1'),('!A','R')],'main_mem_req')
cascade(49,'K',[('W','0'),('merge_hit','1'),('H','1'),('!A','K')],'l1_mem_ack')
cascade(15,'0',[('R','l1_mem_we'),('!A','l1_mem_we')],'main_mem_we')
note(a,105,'Top pin is input 1; left pin is input 0. A=pref_active; R=l1_mem_req; H=l1_hit_pf_buf; W=state; K=main_mem_ack.')
for n,(f,a,t) in enumerate(pages,1):
 f.savefig(O/f'{n:02d}.png',bbox_inches='tight',facecolor='white');f.savefig(O/f'{n:02d}.svg',bbox_inches='tight',facecolor='white')
print(O)
