import random, subprocess, sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TB_MD = str(REPO_ROOT / 'tb' / 'tb_md.v')
MULDIV = str(REPO_ROOT / 'rtl' / 'core' / 'muldiv.v')

M=0xffffffff
def s32(x): x&=M; return x-(1<<32) if x>>31 else x
def golden(f,a,b):
    sa,sb=s32(a),s32(b)
    if f==0: return (sa*sb)&M
    if f==1: return ((sa*sb)>>32)&M
    if f==2: return ((sa*b)>>32)&M
    if f==3: return ((a*b)>>32)&M
    if f==4:
        if b==0: return M
        if sa==-(1<<31) and sb==-1: return 0x80000000
        q=abs(sa)//abs(sb); return (-q if (sa<0)!=(sb<0) else q)&M
    if f==5: return M if b==0 else a//b
    if f==6:
        if b==0: return a
        if sa==-(1<<31) and sb==-1: return 0
        r=abs(sa)%abs(sb); return (-r if sa<0 else r)&M
    if f==7: return a if b==0 else a%b
edge=[0,1,2,3,M,M-1,0x80000000,0x7fffffff,0x80000001,0xffff,0x10000,0xdeadbeef,12345,0xfffffff0]
vec=[]
for f in range(8):
    for a in edge:
        for b in edge: vec.append((f,a,b))
random.seed(1)
for _ in range(4000):
    f=random.randrange(8)
    gen=lambda: random.choice([random.getrandbits(32),random.getrandbits(8),random.getrandbits(16),(-random.getrandbits(8))&M,random.getrandbits(32)>>random.randrange(32)])
    vec.append((f,gen(),gen()))
open('md_vec.txt','w').write(''.join('%x %08x %08x\n'%v for v in vec))
bad=0; cyc={}
for fast in (0,1):
    subprocess.run(['iverilog','-g2005','-P','tb_md.FAST=%d'%fast,'-o','md%d'%fast,TB_MD,MULDIV],check=True)
    out=subprocess.run(['vvp','md%d'%fast],capture_output=True,text=True).stdout.split('\n')
    rs=[l.split() for l in out if l.startswith('R ')]
    assert len(rs)==len(vec),(len(rs),len(vec))
    for (f,a,b),l in zip(vec,rs):
        got=int(l[4],16); exp=golden(f,a,b)
        cyc.setdefault((fast,f),int(l[5]))
        if got!=exp:
            bad+=1
            if bad<10: print('MISMATCH fast=%d f3=%d a=%08x b=%08x got=%08x exp=%08x'%(fast,f,a,b,got,exp))
    print('fast=%d : %d vectors checked'%(fast,len(vec)))
print('total mismatches:',bad)
print('cycles in EX (incl. start+result cycle):',{k:v for k,v in sorted(cyc.items())})
