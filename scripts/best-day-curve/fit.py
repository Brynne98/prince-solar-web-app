import csv, sys, datetime as dt
import numpy as np
from collections import defaultdict

import os; SP = os.path.dirname(os.path.abspath(__file__)) + '/'
rows = defaultdict(dict)  # plant -> day -> slot -> w
for r in csv.DictReader(open(SP + 'perday.csv')):
    rows[r['plant_id']].setdefault(dt.date.fromisoformat(r['day']), {})[int(r['slot'])] = float(r['w'])

T = np.arange(288, dtype=float)

def curve(a, b, p, q):
    u = (T - a) / (b - a)
    out = np.zeros_like(T)
    ok = (u > 0) & (u < 1)
    out[ok] = np.sin(np.pi * u[ok] ** q) ** p
    return out

def p90(days_data, days):
    vals = defaultdict(list)
    for d in days:
        for s, w in days_data.get(d, {}).items():
            vals[s].append(w)
    y = np.full(288, np.nan); n = np.zeros(288)
    for s, v in vals.items():
        y[s] = np.percentile(v, 90); n[s] = len(v)
    return y, n

def fit(y, n, min_days=2):
    m = (n >= min_days) & ~np.isnan(y)
    ys, ws = y[m], n[m]
    best = None
    def search(As, Bs, Ps, Qs):
        nonlocal best
        for p in Ps:
            for q in Qs:
                for a in As:
                    for b in Bs:
                        c = curve(a, b, p, q)[m]
                        den = (ws * c * c).sum()
                        if den <= 0: continue
                        A = (ws * c * ys).sum() / den
                        err = (ws * (A * c - ys) ** 2).sum()
                        if best is None or err < best[0]:
                            best = (err, A, a, b, p, q)
    search(np.arange(60, 100, 3), np.arange(190, 232, 3), np.arange(0.6, 3.2, 0.3), np.arange(0.6, 1.7, 0.15))
    _, A, a, b, p, q = best
    search(np.arange(a - 3, a + 3.1, 1), np.arange(b - 3, b + 3.1, 1), np.arange(p - 0.3, p + 0.31, 0.1), np.arange(q - 0.15, q + 0.16, 0.05))
    _, A, a, b, p, q = best
    return A * curve(a, b, p, q), (A, a, b, p, q)

NS = [7, 10, 14, 21]
for plant, data in rows.items():
    days_all = sorted(data)
    first, last = days_all[0], dt.date(2026, 9, 14)
    ends = [first + dt.timedelta(days=30 + i) for i in range((last - first).days - 29)][-30:]
    print(f'\nplant {plant}: {len(ends)} end dates {ends[0]}..{ends[-1]}')
    errs = {N: [] for N in NS}; shape = []
    for E in ends:
        win = lambda N: [E - dt.timedelta(days=k) for k in range(1, N + 1)]
        y30, n30 = p90(data, win(30))
        f30, par = fit(y30, n30, 5)
        peak = f30.max()
        m = (n30 >= 5) & ~np.isnan(y30) & (T >= 108) & (T < 180)
        shape.append(np.sqrt(np.mean((f30[m] - y30[m]) ** 2)) / peak)
        day = f30 > 0.05 * peak
        for N in NS:
            y, n = p90(data, win(N))
            f, _ = fit(y, n, 2)
            errs[N].append((np.abs(f - f30)[day].max() / peak, abs(f.max() - peak) / peak))
    print(f'  30-day fit vs its own points, 09-15h RMS: median {np.median(shape):.1%}, worst {max(shape):.1%}; last params A={par[0]:.0f} rise={par[1]*5/60:.2f}h set={par[2]*5/60:.2f}h p={par[3]:.2f} q={par[4]:.2f}')
    for N in NS:
        e = np.array(errs[N])
        print(f'  {N:>2} days: max gap median {np.median(e[:,0]):.1%}, worst {e[:,0].max():.1%} | peak gap median {np.median(e[:,1]):.1%}, worst {e[:,1].max():.1%}')
