exec(open('clear.py').read().split("days = sorted(data)")[0])
QS = np.arange(0.4, 2.01, 0.1); PS = np.arange(0.6, 3.01, 0.2)
def fit_any(y, n, two):
    m = (n >= 2) & ~np.isnan(y); top = np.nanmax(np.where(m, y, np.nan)); lit = np.where(m & (y > 0.01 * top))[0]
    a0, b0 = lit[0] - 1, lit[-1] + 1; ys, ws = y[m], n[m]; best = (np.inf,)
    for a in (a0 - 1, a0, a0 + 1):
        for b in (b0 - 1, b0, b0 + 1):
            for p in PS:
                C = np.array([curve(a, b, p, q) for q in QS])          # nq x 288
                Cm = C[:, m] * np.sqrt(ws); yw = ys * np.sqrt(ws)
                G = Cm @ Cm.T; r = Cm @ yw
                if not two:
                    A = r / np.diag(G); err = (yw @ yw) - A * r
                    i = np.argmin(err)
                    if err[i] < best[0]: best = (err[i], A[i] * C[i])
                else:
                    i, j = np.triu_indices(len(QS), 1)
                    det = G[i, i] * G[j, j] - G[i, j] ** 2
                    A1 = (r[i] * G[j, j] - r[j] * G[i, j]) / det; A2 = (r[j] * G[i, i] - r[i] * G[i, j]) / det
                    ok = (A1 >= 0) & (A2 >= 0) & (det > 1e-9)
                    err = np.where(ok, (yw @ yw) - A1 * r[i] - A2 * r[j], np.inf)
                    k = np.argmin(err)
                    if err[k] < best[0]: best = (err[k], A1[k] * C[i[k]] + A2[k] * C[j[k]])
    return best[1]

days = sorted(data); clear = []
for d in days:
    row = data[d]; mid = [s for s in range(108, 156) if s in row]
    if len(mid) < 20: continue
    diffs = [abs(row[s] - row[s - 1]) for s in range(73, 228) if s in row and (s - 1) in row]
    if sum(diffs) / (2 * max(row[s] for s in mid)) <= 1.4: clear.append(d)
print('clear days (relaxed):', len(clear))
for N in (21, 30, 45):
    res = defaultdict(list); bias = defaultdict(list)
    for d in clear:
        win = [d - dt.timedelta(days=k) for k in range(1, N + 1)]
        if sum(w in data for w in win) < 0.7 * N: continue
        y, n = pct(win, 90); row = data[d]; ss = [s for s in range(96, 192) if s in row]; act = np.array([row[s] for s in ss])
        for name, f in (('one arch', fit_any(y, n, False)), ('two arches', fit_any(y, n, True))):
            pk = f.max(); res[name].append(np.mean(np.abs(act - f[ss])) / pk); bias[name].append(act.sum() / f[ss].sum() - 1)
        ok = ~np.isnan(y[ss]); res['old jagged'].append(np.mean(np.abs(act[ok] - y[ss][ok])) / pk)
        if N == 30 and d == clear[-1]:
            f2 = fit_any(y, n, True); f1 = fit_any(y, n, False)
            print('  shape on', d, '(clear day | 30-day p90 | one arch | two arches)')
            for s in range(84, 216, 6):
                print(f'   {s*5//60:02d}:{s*5%60:02d} {row.get(s, -1):7.0f} | {y[s]:6.0f} | {f1[s]:6.0f} | {f2[s]:6.0f}')
    print(f'{N} days, {len(res["one arch"])} clear days tested: ' + ', '.join(f'{k} gap {np.median(v):.1%}' for k, v in res.items()) + ' | clear day vs curve ' + ', '.join(f'{k} {np.median(v):+.1%}' for k, v in bias.items()))
