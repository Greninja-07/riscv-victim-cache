import random, subprocess, sys, re
from asm import *
M=0xffffffff
def s32(x): x&=M; return x-(1<<32) if x>>31 else x
from md_test_golden import golden

def gen_prog(rng, n):
    """returns list of ('instr', kind, args) as encoded words + sim list"""
    prog=[]   # each: (word, tuple for simulator)
    # init regs with random 32-bit values
    for r_ in range(1,8):
        v=rng.choice([rng.getrandbits(32), rng.getrandbits(6), (-rng.getrandbits(6))&M, 0x80000000, M, 0, 1])
        for w in li(r_,v): prog.append((w,None))
    sim_setup=True
    body=[]
    while len(body)<n:
        k=rng.random()
        rd=rng.randrange(1,8); rs1=rng.randrange(0,8); rs2=rng.randrange(0,8)
        if k<0.38:
            nm=rng.choice(list(MNEM)); body.append((m(nm,rd,rs1,rs2),('m',nm,rd,rs1,rs2)))
        elif k<0.50:
            imm=rng.randrange(-2048,2048); body.append((addi(rd,rs1,imm),('addi',rd,rs1,imm)))
        elif k<0.60:
            body.append((add(rd,rs1,rs2),('add',rd,rs1,rs2)))
        elif k<0.68:
            off=0x100+4*rng.randrange(16); body.append((sw(rs2,0,off),('sw',rs2,off)))
        elif k<0.76:
            off=0x100+4*rng.randrange(16); body.append((lw(rd,0,off),('lw',rd,off)))
        elif k<0.88:
            skip=rng.randrange(0,4); typ=rng.choice([0,1])
            body.append((b(typ,rs1,rs2,4*(skip+1)),('br',typ,rs1,rs2,skip)))
        else:
            body.append((lui(rd,rng.getrandbits(20)),('lui',rd,0)))
    return prog,body

def simulate(prog_words_setup, body):
    regs=[0]*32; mem={}
    # execute setup (lui/addi)
    for w in prog_words_setup:
        op=w&0x7f
        rd=(w>>7)&31
        if op==0x37: regs[rd]=w&0xfffff000
        elif op==0x13:
            rs1=(w>>15)&31; imm=(w>>20)&0xfff; imm=imm-4096 if imm&0x800 else imm
            regs[rd]=(regs[rs1]+imm)&M
    i=0
    while i<len(body):
        t=body[i][1]; i+=1
        k=t[0]
        if k=='m': _,nm,rd,a,b_=t; v=golden(MNEM[nm],regs[a],regs[b_]); 
        if k=='m':
            if rd: regs[rd]=v
        elif k=='addi':
            _,rd,a,imm=t
            if rd: regs[rd]=(regs[a]+imm)&M
        elif k=='add':
            _,rd,a,b_=t
            if rd: regs[rd]=(regs[a]+regs[b_])&M
        elif k=='sw': mem[t[2]]=regs[t[1]]
        elif k=='lw':
            if t[1]: regs[t[1]]=mem.get(t[2],0)
        elif k=='lui':
            if t[1]: regs[t[1]]=(0)  # placeholder, replaced below
        elif k=='br':
            _,typ,a,b_,skip=t
            take=(regs[a]==regs[b_]) if typ==0 else (regs[a]!=regs[b_])
            if take: i+=skip
        regs[0]=0
    return regs,mem

def run(seed, fast, nbody=50):
    rng=random.Random(seed)
    setup,body=gen_prog(rng,nbody)
    # fix lui semantic: need imm; re-derive from encoded word
    body2=[]
    for w,t in body:
        if t and t[0]=='lui': t=('lui',t[1],w&0xfffff000)
        body2.append((w,t))
    body=body2
    # patch simulate for lui
    words_setup=[w for w,_ in setup]
    regs=[0]*32; mem={}
    for w in words_setup:
        op=w&0x7f; rd=(w>>7)&31
        if op==0x37: regs[rd]=w&0xfffff000
        else:
            rs1=(w>>15)&31; imm=(w>>20)&0xfff; imm=imm-4096 if imm&0x800 else imm
            regs[rd]=(regs[rs1]+imm)&M
    i=0
    while i<len(body):
        t=body[i][1]; i+=1; k=t[0]
        if k=='m':
            _,nm,rd,a,b_=t
            if rd: regs[rd]=golden(MNEM[nm],regs[a],regs[b_])
        elif k=='addi':
            _,rd,a,imm=t
            if rd: regs[rd]=(regs[a]+imm)&M
        elif k=='add':
            _,rd,a,b_=t
            if rd: regs[rd]=(regs[a]+regs[b_])&M
        elif k=='sw': mem[t[2]]=regs[t[1]]
        elif k=='lw':
            if t[1]: regs[t[1]]=mem.get(t[2],0)
        elif k=='lui':
            if t[1]: regs[t[1]]=t[2]
        elif k=='br':
            _,typ,a,b_,skip=t
            take=(regs[a]==regs[b_]) if typ==0 else (regs[a]!=regs[b_])
            if take: i+=skip
        regs[0]=0
    # tail: dump regs
    tail=[sw(r_,0,0x200+4*r_) for r_ in range(1,8)]
    # a branch skip can run past end of body: pad with 4 NOP-ish addi x0
    pad=[addi(0,0,0)]*4
    words=[w for w,_ in setup]+[w for w,_ in body]+pad+tail+[j(0,0)]
    write_hex('imem.hex',words); write_hex('dmem.hex',[0]*1024)
    exp=dict(mem)
    for r_ in range(1,8): exp[0x200+4*r_]=regs[r_]
    nm=sum(1 for _,t in body if t[0]=='m')
    maxc=len(words)*3+nm*40+200
    out=subprocess.run(['vvp',fast,'+MAXC=%d'%maxc],capture_output=True,text=True).stdout
    got={}
    for l in out.split('\n'):
        mm=re.match(r'W (\d+) ([0-9a-f]{8}) ([0-9a-f]{8})',l)
        if mm:
            a=int(mm.group(1)); d=int(mm.group(2),16); be=int(mm.group(3),16)
            cur=got.get(a,0)
            for bi in range(4):
                if be>>bi&1: cur=(cur&~(0xff<<8*bi))|(d&(0xff<<8*bi))
            got[a]=cur
    ok=all(got.get(a,0)==v for a,v in exp.items()) and all(v==exp.get(a,0) for a,v in got.items())
    if not ok:
        for a in sorted(set(exp)|set(got)):
            if exp.get(a,0)!=got.get(a,0): print('  seed',seed,'addr %x exp %08x got %08x'%(a,exp.get(a,0),got.get(a,0)))
    return ok

if __name__=='__main__':
    sim=sys.argv[1]; N=int(sys.argv[2])
    bad=0
    for sd in range(N):
        if not run(sd,sim): bad+=1
    print(sim,'random programs:',N,'failed:',bad)
