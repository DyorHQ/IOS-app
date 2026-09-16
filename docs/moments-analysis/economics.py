"""Deterministic design model; not deployed-contract or exact Uniswap v4 math.
Run: python3 docs/moments-analysis/economics.py
All curve and pool calculations exclude swap fees, gas, rounding and finite ticks.
Redemption scenarios include the explicitly selected redemption fee.
"""
from decimal import Decimal, getcontext
from pathlib import Path
import csv
getcontext().prec = 48
D = Decimal
S = D(100_000_000)
OUT = Path(__file__).resolve().parent

def curve(v, t):
    c = S*v/(v+t)
    p = (v+t)/c
    x = t/p
    return c, p, x, c-x

def buy(x,y,n):
    if not D(0) < n < x:
        raise ValueError('Desired output exceeds available pool inventory')
    return y*n/(x-n)

def sell(x,y,n):
    return y*n/(x+n)

def write(name, rows):
    with (OUT/name).open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=rows[0].keys());w.writeheader();w.writerows(rows)

rows=[]
for multiple in (4,9,19):
    v=D(1000);t=v*multiple;c,p,x,b=curve(v,t)
    assert S == (S-c)+x+b
    for r in (10000,20000,50000,100000,200000,250000,500000,1000000):
        n=D(r)
        rows.append(dict(threshold_over_virtual=multiple,virtual_MON=v,threshold_MON=t,coins_per_NFT=r,
          sold_at_graduation=S-c,pool_coins=x,surplus_burn=b,post_burn_supply=S-b,
          initial_theoretical_cap=int(S/n),post_burn_theoretical_cap=int((S-b)/n),
          first_collect_buy_MON=v*n/(S-n),graduation_spot_MON=p,
          after_graduation_buy_MON=buy(x,t,n),buy_impact_percent=(buy(x,t,n)/(p*n)-1)*100))
write('denomination-scenarios.csv',rows)
rows=[]
c,p,x,b=curve(D(1000),D(4000))
for fee in ('0','.01','.02','.05'):
    for gross in (20000,1000000,10000000,40000000):
        g=D(gross);f=D(fee);net=g*(1-f)
        proceeds=sell(x,D(4000),net)
        rows.append(dict(redemption_fee=f,gross_backing_coins=g,net_coins=net,
          spot_net_MON=net*p,executable_MON_excluding_swap_fee=proceeds,
          average_execution_discount_percent=(1-proceeds/(net*p))*100,
          fee_only_break_even_percent=(1/(1-f)-1)*100))
write('redemption-scenarios.csv',rows)
# Recommended 2% split, expressed against gross backing.
g=D(1000000)
alloc=[g*D(f) for f in ('.98','.0075','.005','.005','.0025')]
assert sum(alloc)==g
assert buy(x,D(4000),D(1000000)) > p*D(1000000)
assert sell(x,D(4000),D(980000)) < p*D(980000)
print('Wrote 24 denomination scenarios and 16 independent redemption scenarios.')
print('2% split: holder, LP, creator, project, burn:', ', '.join(map(str,alloc)))
print('One 1M-backed NFT redeem/sell:', sell(x,D(4000),D(980000)), 'MON before swap fees')
