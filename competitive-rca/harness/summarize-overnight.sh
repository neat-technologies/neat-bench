#!/usr/bin/env bash
# Scoreboard over a results.tsv: per-cell accuracy + cost, then the savings each
# arm buys against the code baseline (same model, and the cross-tier headline of
# the cheap model with NEAT vs the premium model without). Speed is reported when
# the runner recorded wall_s; older results without it just skip the speed column.
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
has_wall = bool(rows) and 'wall_s' in rows[0]
agg=defaultdict(lambda: dict(n=0,caught=0,rci=0,rcr=0,resolved=0,robust=0,void=0,cost=0.0,wall=0.0,walln=0))
for r in rows:
    k=(r.get('mode',''),r.get('model',''),r.get('arm','')); a=agg[k]; a['n']+=1
    if yes(r.get('caught','')): a['caught']+=1
    if yes(r.get('rci','')): a['rci']+=1
    if yes(r.get('rcr','')): a['rcr']+=1
    if yes(r.get('resolved','')): a['resolved']+=1
    if yes(r.get('robust','')): a['robust']+=1
    if 'VOID' in (r.get('caught',''),r.get('resolved',''),r.get('rci','')): a['void']+=1
    a['cost']+=num(r.get('cost_usd','0'))
    w=num(r.get('wall_s','0'))
    if w>0: a['wall']+=w; a['walln']+=1
def cpr(a):  return a['cost']/a['n'] if a['n'] else 0.0
def wpr(a):  return a['wall']/a['walln'] if a['walln'] else 0.0
for mode in ('detect','resolve'):
    ks=sorted([k for k in agg if k[0]==mode], key=lambda k:(k[1],k[2]))
    if not ks: continue
    print("\n==== %s ====" % mode.upper())
    wh = "%8s" % "wall_s" if has_wall else ""
    if mode=='detect':
        print("%-7s %-10s %3s %8s %5s %5s %5s %9s %9s%s" % ('model','arm','n','CAUGHT','RCI','RCR','VOID','cost$','$/run',wh))
        for k in ks:
            a=agg[k]; _,model,arm=k
            wv = ("%8.0f" % wpr(a)) if has_wall else ""
            print("%-7s %-10s %3d %8s %5d %5d %5d %9.3f %9.4f%s" % (model,arm,a['n'],"%d/%d"%(a['caught'],a['n']),a['rci'],a['rcr'],a['void'],a['cost'],cpr(a),wv))
    else:
        print("%-7s %-10s %3s %9s %7s %5s %5s %9s %9s%s" % ('model','arm','n','RESOLVED','ROBUST','RCI','VOID','cost$','$/run',wh))
        for k in ks:
            a=agg[k]; _,model,arm=k
            wv = ("%8.0f" % wpr(a)) if has_wall else ""
            print("%-7s %-10s %3d %9s %7s %5d %5d %9.3f %9.4f%s" % (model,arm,a['n'],"%d/%d"%(a['resolved'],a['n']),"%d/%d"%(a['robust'],a['n']),a['rci'],a['void'],a['cost'],cpr(a),wv))

# Savings: what each arm buys vs the code baseline. Positive = cheaper / faster.
def pct(arm_v, base_v):
    return 100.0*(1.0-arm_v/base_v) if base_v>0 and arm_v>0 else None
def fmt(p, word_pos, word_neg):
    if p is None: return "   n/a"
    return "%+5.0f%% %s" % (p, word_pos if p>=0 else word_neg)
print("\n==== SAVINGS vs code baseline (per run; + = cheaper/faster, - = pricier/slower) ====")
print("%-7s %-10s %-12s %-18s%s" % ('mode','arm','vs','cost', '  speed' if has_wall else ''))
for mode in ('detect','resolve'):
    cells={k:agg[k] for k in agg if k[0]==mode}
    if not cells: continue
    models=sorted(set(k[1] for k in cells))
    arms=sorted(set(k[2] for k in cells if k[2]!='code'))
    # same-model: arm@m vs code@m  (isolates the arm's contribution, model held fixed)
    for m in models:
        base=cells.get((mode,m,'code'))
        if not base: continue
        for arm in arms:
            a=cells.get((mode,m,arm))
            if not a: continue
            line="%-7s %-10s %-12s %-18s" % (mode, arm+'@'+m, 'code@'+m, fmt(pct(cpr(a),cpr(base)),'cheaper','pricier'))
            if has_wall: line+="  "+fmt(pct(wpr(a),wpr(base)),'faster','slower')
            print(line)
    # cross-tier headline: cheap model + NEAT vs premium model + code
    if 'sonnet' in models and 'opus' in models:
        a=cells.get((mode,'sonnet','neat')); base=cells.get((mode,'opus','code'))
        if a and base:
            line="%-7s %-10s %-12s %-18s" % (mode, 'neat@sonnet', 'code@opus', fmt(pct(cpr(a),cpr(base)),'cheaper','pricier'))
            if has_wall: line+="  "+fmt(pct(wpr(a),wpr(base)),'faster','slower')
            print(line+"   <- cross-tier headline")
if not has_wall:
    print("\n(no wall_s column in this results file: speed not recorded by this runner version)")
print("\ntotal rows:",len(rows),"  total cost $%.2f"%sum(num(r.get('cost_usd','0')) for r in rows))
PY
