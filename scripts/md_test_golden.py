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
