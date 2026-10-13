#!/usr/bin/env bash
OUT="${1:-$HOME/praxis/runs/fullsuite-results.tsv}"
[ -f "$OUT" ] || { echo "no results yet: $OUT"; exit 0; }
python3 - "$OUT" <<'PY'
import sys,csv
from collections import defaultdict
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t'))
def num(x):
    try: return float(x)
    except: return 0.0
yes=lambda v: v in ('YES','1','true','True')
agg=defaultdict(lambda: dict(n=0,caught=0,rci=0,rcr=0,resolved=0,robust=0,void=0,cost=0.0))
for r in rows:
    k=(r.get('mode',''),r.get('model',''),r.get('arm','')); a=agg[k]; a['n']+=1
    if yes(r.get('caught','')): a['caught']+=1
    if yes(r.get('rci','')): a['rci']+=1
    if yes(r.get('rcr','')): a['rcr']+=1
    if yes(r.get('resolved','')): a['resolved']+=1
    if yes(r.get('robust','')): a['robust']+=1
    if 'VOID' in (r.get('caught',''),r.get('resolved',''),r.get('rci','')): a['void']+=1
    a['cost']+=num(r.get('cost_usd','0'))
for mode in ('detect','resolve'):
    ks=sorted([k for k in agg if k[0]==mode], key=lambda k:(k[1],k[2]))
    if not ks: continue
    print("\n==== %s ====" % mode.upper())
    if mode=='detect':
        print("%-7s %-10s %3s %8s %5s %5s %5s %9s" % ('model','arm','n','CAUGHT','RCI','RCR','VOID','cost$'))
        for k in ks:
            a=agg[k]; _,model,arm=k
            print("%-7s %-10s %3d %8s %5d %5d %5d %9.3f" % (model,arm,a['n'],"%d/%d"%(a['caught'],a['n']),a['rci'],a['rcr'],a['void'],a['cost']))
    else:
        print("%-7s %-10s %3s %9s %7s %5s %5s %9s" % ('model','arm','n','RESOLVED','ROBUST','RCI','VOID','cost$'))
        for k in ks:
            a=agg[k]; _,model,arm=k
            print("%-7s %-10s %3d %9s %7s %5d %5d %9.3f" % (model,arm,a['n'],"%d/%d"%(a['resolved'],a['n']),"%d/%d"%(a['robust'],a['n']),a['rci'],a['void'],a['cost']))
print("\ntotal rows:",len(rows),"  total cost $%.2f"%sum(num(r.get('cost_usd','0')) for r in rows))
PY
