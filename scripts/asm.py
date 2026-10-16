# tiny RV32I(+M) encoder for tests
def r(op,f3,f7,rd,rs1,rs2): return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def i(op,f3,rd,rs1,imm): return ((imm&0xfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def s(f3,rs1,rs2,imm): return (((imm>>5)&0x7f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&0x1f)<<7)|0x23
def b(f3,rs1,rs2,imm):
    imm&=0x1fff
    return (((imm>>12)&1)<<31)|(((imm>>5)&0x3f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((imm>>1)&0xf)<<8)|(((imm>>11)&1)<<7)|0x63
def j(rd,imm):
    imm&=0x1fffff
    return (((imm>>20)&1)<<31)|(((imm>>1)&0x3ff)<<21)|(((imm>>11)&1)<<20)|(((imm>>12)&0xff)<<12)|(rd<<7)|0x6f
def lui(rd,imm20): return ((imm20&0xfffff)<<12)|(rd<<7)|0x37
def auipc(rd,imm20): return ((imm20&0xfffff)<<12)|(rd<<7)|0x17
def addi(rd,rs1,imm): return i(0x13,0,rd,rs1,imm)
def lw(rd,rs1,imm): return i(0x03,2,rd,rs1,imm)
def sw(rs2,rs1,imm): return s(2,rs1,rs2,imm)
MNEM={'mul':0,'mulh':1,'mulhsu':2,'mulhu':3,'div':4,'divu':5,'rem':6,'remu':7}
def m(name,rd,rs1,rs2): return r(0x33,MNEM[name],1,rd,rs1,rs2)
def add(rd,a,b_): return r(0x33,0,0,rd,a,b_)
def li(rd,val):
    val&=0xffffffff
    lo=val&0xfff
    if lo>=0x800: lo-=0x1000
    hi=((val-lo)>>12)&0xfffff
    return [lui(rd,hi),addi(rd,rd,lo)]
def write_hex(path,words,size=1024):
    words=list(words)+[0x13]*(size-len(words))
    open(path,'w').write('\n'.join('%08x'%(w&0xffffffff) for w in words)+'\n')
