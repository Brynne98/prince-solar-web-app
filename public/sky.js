// The showcase's sky through one day (SOLAR-352): shared by welcome-scene.js and 404.html.
window.Sky = (() => {
  const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));
  const rgb = c => `rgb(${c[0]},${c[1]},${c[2]})`;
  // hour, sky top, mid, bottom, far hill, near hill, ink (0 light, 1 dark), stars
  const K = [
    [0, '#04060c', '#070b16', '#0e1424', '#090c16', '#05070c', 0, 1],
    [5.0, '#05070f', '#0b1020', '#171b33', '#0b0e1a', '#06080e', 0, 1],
    [5.9, '#0f1433', '#3b2f5e', '#c0656a', '#1a1626', '#0b0a12', 0, .55],
    [6.7, '#23305c', '#8a6282', '#f2a46f', '#3a2a2e', '#1a1418', 0, .05],
    [8.0, '#6f6a8a', '#d9a27a', '#f6cf96', '#7a5a3e', '#3c2c20', 0, 0],
    [9.6, '#c08c4c', '#ebbd74', '#f9e0ad', '#a77d48', '#5e4428', 1, 0],
    [12.3, '#e3a744', '#f4cd7f', '#fdedc6', '#b98c4c', '#6e522e', 1, 0],
    [15.2, '#d68c38', '#efb462', '#f8d79e', '#a7743c', '#5c3f22', 1, 0],
    [16.6, '#b9672f', '#df9150', '#f1bd7c', '#874f2c', '#46291a', 1, 0],
    [17.4, '#7e3f3c', '#c8664c', '#ee9d5e', '#5a2f2a', '#2c1816', 0, 0],
    [18.4, '#3e2046', '#a1475c', '#ec8650', '#341c2a', '#1a0e16', 0, .1],
    [19.3, '#171633', '#3e2850', '#7a3f58', '#1a1424', '#0c0a12', 0, .5],
    [20.6, '#070a17', '#0d1124', '#181a33', '#0b0d18', '#06070d', 0, 1],
    [24, '#04060c', '#070b16', '#0e1424', '#090c16', '#05070c', 0, 1]
  ];
  function skyAt(h) {
    let i = 0; while (i < K.length - 2 && h > K[i + 1][0]) i++;
    const a = K[i], b = K[i + 1], t = Math.min(1, Math.max(0, (h - a[0]) / (b[0] - a[0])));
    const c = [1, 2, 3, 4, 5].map(j => rgb(mix(hex(a[j]), hex(b[j]), t)));
    return { c, ink: a[6] + (b[6] - a[6]) * t, stars: a[7] + (b[7] - a[7]) * t };
  }
  return { hex, mix, rgb, skyAt };
})();
