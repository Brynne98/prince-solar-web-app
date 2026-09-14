exec(open('fit.py').read().split('def fit(')[0])
def fit(y, n, min_days=2):
    m = (n >= min_days) & ~np.isnan(y)
    top = np.nanmax(np.where(m, y, np.nan))
    lit = np.where(m & (y > 0.01 * top))[0]
    a0, b0 = lit[0] - 1, lit[-1] + 1          # sunrise / sunset pinned from the readings
    ys, ws = y[m], n[m]
    best = None
    for a in (a0 - 1, a0, a0 + 1):
        for b in (b0 - 1, b0, b0 + 1):
            for p in np.arange(0.6, 3.01, 0.1):
                for q in np.arange(0.6, 1.61, 0.05):
                    c = curve(a, b, p, q)[m]
                    A = (ws * c * ys).sum() / (ws * c * c).sum()
                    err = (ws * (A * c - ys) ** 2).sum()
                    if best is None or err < best[0]: best = (err, A, a, b, p, q)
    _, A, a, b, p, q = best
    return A * curve(a, b, p, q), (A, a, b, p, q)

NS = [7, 10, 14, 21]
for plant, data in rows.items():
    first, last = sorted(data)[0], dt.date(2026, 9, 14)
    ends = [first + dt.timedelta(days=30 + i) for i in range((last - first).days - 29)][-30:]
    errs = {N: [] for N in NS}; shape = []
    for E in ends:
        win = lambda N: [E - dt.timedelta(days=k) for k in range(1, N + 1)]
        y30, n30 = p90(data, win(30))
        f30, par = fit(y30, n30, 5)
        peak = f30.max(); day = f30 > 0.05 * peak
        m = (n30 >= 5) & ~np.isnan(y30) & day
        shape.append(np.mean(np.abs(f30[m] - y30[m])) / peak)
        for N in NS:
            y, n = p90(data, win(N)); f, _ = fit(y, n, 2)
            d = np.abs(f - f30)[day] / peak
            errs[N].append((d.mean(), d.max(), abs(f.max() - peak) / peak))
    print(f'plant {plant}: 30-day curve vs its own points, mean gap {np.median(shape):.1%} of peak')
    print('  days | avg gap med/worst | biggest gap med/worst | peak gap med/worst')
    for N in NS:
        e = np.array(errs[N]); md = np.median(e, 0); mx = e.max(0)
        print(f'  {N:>4} | {md[0]:5.1%} / {mx[0]:5.1%} | {md[1]:5.1%} / {mx[1]:5.1%} | {md[2]:5.1%} / {mx[2]:5.1%}')
