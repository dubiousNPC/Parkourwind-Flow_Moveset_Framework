import re, os, sys, glob

def strip_comments(src):
    out=[];i=0;n=len(src)
    while i<n:
        m=re.match(r'--\[(=*)\[',src[i:])
        if m:
            c=']'+m.group(1)+']';j=src.find(c,i);i=n if j<0 else j+len(c);continue
        if src.startswith('--',i):
            j=src.find('\n',i);i=n if j<0 else j;continue
        out.append(src[i]);i+=1
    return ''.join(out)
stub, mod = sys.argv[1], sys.argv[2]

# module -> allowed contexts, from the stub header
modctx = {}
for f in glob.glob(stub + '/openmw/*.lua'):
    name = os.path.basename(f)[:-4]
    head = open(f, encoding='utf-8', errors='replace').read(400)
    m = re.search(r"---@omw-context ([\w|]+)", head)
    if m: modctx[name] = set(m.group(1).split('|'))

# which FLOW file runs in which context, from .omwscripts
script_ctx = {}
for f in glob.glob(mod + '/*.omwscripts'):
    for line in open(f):
        m = re.match(r"\s*(PLAYER|GLOBAL|MENU|LOCAL|CUSTOM)\s*:\s*(\S+)", line, re.I)
        if m: script_ctx[m.group(2).strip()] = m.group(1).upper()

CTXMAP = {'PLAYER':{'player','local'}, 'GLOBAL':{'global'}, 'MENU':{'menu'}, 'LOCAL':{'local'}}

# resolve requires transitively so modules pulled in by main.lua inherit its context
def requires_of(path):
    src = strip_comments(open(path, encoding='utf-8', errors='replace').read())
    return re.findall(r"require\(['\"]([\w./]+)['\"]\)", src)

file_ctx = {}
def assign(rel, ctx, seen=None):
    seen = seen or set()
    if rel in seen: return
    seen.add(rel)
    p = os.path.join(mod, rel)
    if not os.path.exists(p): return
    file_ctx.setdefault(rel, set()).add(ctx)
    for r in requires_of(p):
        if r.startswith('openmw'): continue
        cand = r.replace('.', '/') + '.lua'
        if os.path.exists(os.path.join(mod, cand)): assign(cand, ctx, seen)

for f, c in script_ctx.items(): assign(f, c)

bad = 0
for rel, ctxs in sorted(file_ctx.items()):
    src = strip_comments(open(os.path.join(mod, rel), encoding='utf-8', errors='replace').read())
    mods = set(re.findall(r"require\(['\"]openmw\.(\w+)['\"]\)", src))
    for m in mods:
        if m not in modctx: continue
        allowed = modctx[m]
        for c in ctxs:
            need = CTXMAP.get(c, set())
            if need and "all" not in allowed and not (allowed & need):
                print("  %-34s requires openmw.%-14s allowed=%s but runs in %s"
                      % (rel, m, '|'.join(sorted(allowed)), c))
                bad += 1
print("%d context violations" % bad)
