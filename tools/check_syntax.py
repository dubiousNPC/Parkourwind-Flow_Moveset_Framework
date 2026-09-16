import re,os
def strip(src):
    out=[];i=0;n=len(src)
    while i<n:
        m=re.match(r'--\[(=*)\[',src[i:])
        if m:
            c=']'+m.group(1)+']';j=src.find(c,i);i=n if j<0 else j+len(c);continue
        if src.startswith('--',i):
            j=src.find('\n',i);i=n if j<0 else j;continue
        ch=src[i]
        if ch in '"\'':
            j=i+1
            while j<n:
                if src[j]=='\\':j+=2;continue
                if src[j]==ch:j+=1;break
                j+=1
            i=j;out.append('""');continue
        out.append(ch);i+=1
    return ''.join(out)
bad=0;tot=0
for root,dirs,fs in os.walk('.'):
    if any(x in root for x in ['backups','not finished']):continue
    for f in sorted(fs):
        if not f.endswith('.lua'):continue
        p=os.path.join(root,f);tot+=1
        code=strip(open(p,encoding='utf-8',errors='replace').read());st=[];errs=[]
        for ln,text in enumerate(code.split('\n'),1):
            for w in re.findall(r"\b[A-Za-z_]\w*\b",text):
                if w in ('function','if','while','for'): st.append((w,ln))
                elif w=='do':
                    if st and st[-1][0] in ('for','while'): pass
                    else: st.append(('do',ln))
                elif w=='repeat': st.append((w,ln))
                elif w=='until':
                    if st and st[-1][0]=='repeat': st.pop()
                elif w=='end':
                    if st: st.pop()
                    else: errs.append((ln,'end without opener'))
        for o,c,nm in [('(',')','paren'),('{','}','brace')]:
            if code.count(o)!=code.count(c): errs.append((0,nm+' imbalance'))
        if st: errs.append((0,'unclosed: '+','.join('%s@%d'%(t,l) for t,l in st)))
        if errs:
            bad+=1;print('FAIL',p)
            for ln,m in errs: print('   ',ln,m)
print('%d files, %d issues'%(tot,bad))
