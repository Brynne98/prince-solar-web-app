import csv, datetime as dt, numpy as np
from collections import defaultdict
data = {}
for r in csv.DictReader(open('perday_all.csv')):
    if r['plant_id'] == '538820':
        data.setdefault(dt.date.fromisoformat(r['day']), {})[int(r['slot'])] = float(r['w'])
T = np.arange(288, dtype=float)
def curve(a, b, p, q):
    u = (T - a) / (b - a); out = np.zeros_like(T); ok = (u > 0) & (u < 1)
    out[ok] = np.sin(np.pi * u[ok] ** q) ** p; return out
def pct(days, P):
    vals = defaultdict(list)
    for d in days:
        for s, w in data.get(d, {}).items(): vals[s].append(w)
    y = np.full(288, np.nan); n = np.zeros(288)
    for s, v in vals.items(): y[s] = np.percentile(v, P); n[s] = len(v)
    return y, n
def fit(y, n, min_days=2):
    m = (n >= min_days) & ~np.isnan(y)
    top = np.nanmax(np.where(m, y, np.nan)); lit = np.where(m & (y > 0.01 * top))[0]
    a0, b0 = lit[0] - 1, lit[-1] + 1; ys, ws = y[m], n[m]; best = None
    for a in (a0 - 1, a0, a0 + 1):
        for b in (b0 - 1, b0, b0 + 1):
            for p in np.arange(0.6, 3.01, 0.1):
                for q in np.arange(0.6, 1.61, 0.05):
                    c = curve(a, b, p, q)[m]; A = (ws * c * ys).sum() / (ws * c * c).sum()
                    err = (ws * (A * c - ys) ** 2).sum()
                    if best is None or err < best[0]: best = (err, A, a, b, p, q)
    return best[1] * curve(*best[2:])

days = sorted(data); first = days[0]
print('Prince Home readings', first, '..', days[-1], len(days), 'days')
# clear days: 09:00-13:00 mostly unheld, and smooth (clouds make it jagged)
clear = []
for d in days:
    row = data[d]; mid = [s for s in range(108, 156) if s in row]
    if len(mid) < 38: continue
    seq = [row[s] for s in range(72, 228) if s in row and (s - 1) in row]
    diffs = [abs(row[s] - row[s - 1]) for s in range(73, 228) if s in row and (s - 1) in row]
    peak = max(row[s] for s in mid)
    rough = sum(diffs) / (2 * peak)
    if rough <= 1.35: clear.append(d)
print('clear days found:', len(clear))

rows = []
for P in (75, 90):
    for N in (14, 21, 30, 45, 60):
        gaps, bias, jag = [], [], []
        for d in clear:
            win = [d - dt.timedelta(days=k) for k in range(1, N + 1)]
            if sum(w in data for w in win) < 0.7 * N: continue
            y, n = pct(win, P)
            f = fit(y, n, 2); pk = f.max()
            row = data[d]; ss = [s for s in range(96, 192) if s in row]      # 08:00-16:00
            act = np.array([row[s] for s in ss]); pred = f[ss]
            gaps.append(np.mean(np.abs(act - pred)) / pk)
            bias.append((act.sum() - pred.sum()) / pred.sum())
            ys = y[ss]; ok = ~np.isnan(ys)
            jag.append(np.mean(np.abs(act[ok] - ys[ok])) / pk)              # current per-slot line, for comparison
        g = np.array(gaps)
        rows.append((P, N, len(g), np.median(g), np.percentile(g, 90), np.median(bias), np.median(jag)))
print(' pct  days  tested | smooth avg gap med / bad-10% | clear day vs curve | old jagged line gap')
for r in rows:
    print(f' p{r[0]}  {r[1]:>4}  {r[2]:>6} | {r[3]:6.1%} / {r[4]:6.1%}        | {r[5]:+6.1%}            | {r[6]:6.1%}')
