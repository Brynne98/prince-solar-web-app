exec(open('two.py').read().split("days = sorted(data); clear = []")[0])
days = sorted(data); clear = []
for d in days:
    row = data[d]; mid = [s for s in range(108, 156) if s in row]
    if len(mid) < 20: continue
    diffs = [abs(row[s] - row[s - 1]) for s in range(73, 228) if s in row and (s - 1) in row]
    if sum(diffs) / (2 * max(row[s] for s in mid)) <= 1.4: clear.append(d)
print('share of 5-min slots with usable readings (battery not full), by hour')
print(' hour  clear days  all days')
for h in range(7, 18):
    sl = range(h * 12, h * 12 + 12)
    c = np.mean([sum(s in data[d] for s in sl) / 12 for d in clear]); a = np.mean([sum(s in data[d] for s in sl) / 12 for d in days])
    print(f'  {h:02d}   {c:6.0%}     {a:6.0%}')

# variants, scored on clear-day readings split morning / afternoon
def fit_v(y, n, q_free, min_days):
    global QS
    keep = QS; QS = QS if q_free else np.array([1.0])
    n2 = np.where(n >= min_days, n, 0); f = fit_any(y, n2, False); QS = keep; return f
V = {'arch, lean free, >=2 days': (True, 2), 'arch, lean free, >=5 days': (True, 5), 'symmetric arch, >=5 days': (False, 5), 'symmetric arch, >=2 days': (False, 2)}
for N in (21, 30):
    out = defaultdict(lambda: ([], []))
    for d in clear:
        win = [d - dt.timedelta(days=k) for k in range(1, N + 1)]
        if sum(w in data for w in win) < 0.7 * N: continue
        y, n = pct(win, 90); row = data[d]
        for name, (qf, md) in V.items():
            f = fit_v(y, n, qf, md); pk = f.max()
            am = [s for s in range(96, 144) if s in row]; pm = [s for s in range(144, 204) if s in row]
            out[name][0].append(np.mean([row[s] - f[s] for s in am]) / pk)
            if pm: out[name][1].append(np.mean([row[s] - f[s] for s in pm]) / pk)
    print(f'\n{N} days: clear day minus curve, as share of peak (+ = curve too low)')
    for name, (am, pm) in out.items():
        print(f'  {name:28s} 08-12h {np.median(am):+6.1%} (avg miss {np.median(np.abs(am)):.1%}, {len(am)} days) | 12-17h {np.median(pm) if pm else float("nan"):+6.1%} ({len(pm)} days)')
