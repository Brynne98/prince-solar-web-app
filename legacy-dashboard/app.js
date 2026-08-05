'use strict';

const REFRESH_MS = 60000; // match SunSynk's ~60s cloud cadence; polling faster only repeats data
const HISTORY_MS = 5 * 60 * 1000; // the day-chart changes slowly; refresh it every 5 min
let chart = null;
let timer = null;
let lastHistoryAt = 0;

const $ = (id) => document.getElementById(id);

function fmtPower(w) {
  const v = Math.abs(Math.round(w));
  if (v >= 1000) return (v / 1000).toFixed(2) + ' kW';
  return v + ' W';
}
function fmtKwh(k) {
  return (Number(k) || 0).toFixed(1) + ' kWh';
}

async function getJSON(url) {
  const r = await fetch(url);
  const body = await r.json();
  if (!r.ok) throw new Error(body.error || ('HTTP ' + r.status));
  return body;
}

// --- flow diagram ------------------------------------------------------------
function setLink(id, active, reverse) {
  const el = $(id);
  el.classList.toggle('active', !!active);
  el.classList.toggle('reverse', !!reverse);
}

function renderFlow(t) {
  $('solar-val').textContent = fmtPower(t.pv);
  $('grid-val').textContent = fmtPower(t.grid);
  $('load-val').textContent = fmtPower(t.load);
  $('batt-val').textContent = fmtPower(t.batteryPower);
  $('batt-soc-inline').textContent = t.soc + '%';
  $('hub-val').textContent = t.soc + '%';

  // solar always flows toward the hub when producing
  setLink('link-solar', t.pv > 5, false);
  // load always flows away from the hub when consuming
  setLink('link-load', t.load > 5, false);
  // grid link path runs hub -> grid, so default animation = export.
  // importing reverses it (grid -> hub).
  setLink('link-grid', Math.abs(t.grid) > 5, t.gridDirection === 'importing');
  // battery link path runs battery -> hub, so default animation = discharging.
  // charging reverses it (hub -> battery).
  setLink('link-batt', t.batteryDirection !== 'idle', t.batteryDirection === 'charging');
}

// --- tiles -------------------------------------------------------------------
function renderTiles(t) {
  $('t-solar').textContent = fmtPower(t.pv);
  $('t-solar-today').textContent = fmtKwh(t.todayPv);

  $('t-soc').textContent = t.soc + '%';
  $('soc-fill').style.width = Math.max(0, Math.min(100, t.soc)) + '%';
  const bs = t.batteryDirection;
  $('t-batt-status').textContent = bs.charAt(0).toUpperCase() + bs.slice(1);
  $('t-batt-power').textContent = bs === 'idle' ? '' : ' · ' + fmtPower(t.batteryPower);

  $('t-grid').textContent = fmtPower(t.grid);
  $('t-grid-dir').textContent = Math.abs(t.grid) <= 5 ? 'idle' : t.gridDirection;
  $('t-grid-imp').textContent = fmtKwh(t.todayGridImport);
  $('t-grid-exp').textContent = fmtKwh(t.todayGridExport);

  $('t-load').textContent = fmtPower(t.load);
}

// --- inverter cards ----------------------------------------------------------
function metric(k, v, cls, sub) {
  return `<div class="metric"><span class="k">${k}</span>
    <span class="v ${cls || ''}">${v}${sub ? `<small>${sub}</small>` : ''}</span></div>`;
}

function renderInverters(list) {
  const wrap = $('inverters');
  wrap.innerHTML = list.map((s) => {
    const on = String(s.status) === '1' || s.status === 1;
    const batLabel = s.battery.status === 'idle' ? 'idle' : s.battery.status;
    return `<div class="inv">
      <div class="inv-head">
        <div>
          <div class="inv-name">${s.alias || s.sn}</div>
          <div class="inv-sn">SN ${s.sn}${s.model ? ' · ' + s.model : ''}</div>
        </div>
        <span class="pill ${on ? 'on' : 'off'}">${on ? 'ONLINE' : 'OFFLINE'}</span>
      </div>
      <div class="inv-grid">
        ${metric('Solar', fmtPower(s.pv.power), 'solar')}
        ${metric('Output', fmtPower(s.output.power), '')}
        ${metric('Battery', fmtPower(s.battery.power), 'batt', batLabel)}
        ${metric('SoC', s.battery.soc + '%', 'batt')}
        ${metric('Grid', fmtPower(s.grid.power), 'grid', s.grid.power > 5 ? s.grid.direction : '')}
        ${metric('Home', fmtPower(s.load.power), 'load')}
        ${metric('Batt temp', (s.battery.temperature || 0).toFixed(1) + '°C', '')}
        ${metric('Today PV', fmtKwh(s.pv.today), 'solar')}
      </div>
    </div>`;
  }).join('');
}

// --- chart -------------------------------------------------------------------
const SERIES_COLORS = {
  PV: '#f5a524', Load: '#e5634d', Grid: '#4a9bf0', Battery: '#2ecc8f', SOC: '#9b8cff',
};
function colorFor(label) {
  const key = Object.keys(SERIES_COLORS).find((k) => label.toLowerCase().includes(k.toLowerCase()));
  return SERIES_COLORS[key] || '#8892a6';
}

function renderChart(hist) {
  $('chart-date').textContent = hist.date || '';
  const powerSeries = (hist.series || []).filter((s) => !/soc/i.test(s.label));
  if (!powerSeries.length) return;

  const labels = powerSeries[0].points.map((p) => p.time);
  const datasets = powerSeries.map((s) => {
    const c = colorFor(s.label);
    return {
      label: s.label,
      data: s.points.map((p) => p.value),
      borderColor: c,
      backgroundColor: c + '22',
      borderWidth: 2,
      pointRadius: 0,
      tension: 0.35,
      fill: false,
    };
  });

  if (chart) {
    chart.data.labels = labels;
    chart.data.datasets = datasets;
    chart.update('none');
    return;
  }

  chart = new Chart($('chart').getContext('2d'), {
    type: 'line',
    data: { labels, datasets },
    options: {
      responsive: true,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#99a2b3', font: { family: 'JetBrains Mono', size: 11 }, usePointStyle: true, boxWidth: 8 } },
        tooltip: { backgroundColor: '#161a22', borderColor: '#262c38', borderWidth: 1, titleColor: '#eef1f6', bodyColor: '#99a2b3' },
      },
      scales: {
        x: { grid: { color: '#1d2230' }, ticks: { color: '#5d6577', maxTicksLimit: 8, font: { family: 'JetBrains Mono', size: 10 } } },
        y: { grid: { color: '#1d2230' }, ticks: { color: '#5d6577', font: { family: 'JetBrains Mono', size: 10 } } },
      },
    },
  });
}

// --- load cycle --------------------------------------------------------------
async function refresh() {
  const btn = $('refresh');
  btn.classList.add('loading');
  $('error').hidden = true;
  try {
    const data = await getJSON('/api/overview');
    if (data.inverters[0] && data.inverters[0].plantName) {
      $('plant-name').textContent = data.inverters.find((i) => i.plantName)?.plantName || 'Live';
    }
    renderFlow(data.totals);
    renderTiles(data.totals);
    renderInverters(data.inverters);
    const d = new Date(data.generatedAt);
    $('updated').textContent = 'updated ' + d.toLocaleTimeString();
    document.querySelectorAll('.stale').forEach((e) => e.classList.remove('stale'));

    // history is heavier and changes slowly; refresh it at most every HISTORY_MS
    // (and always on first load, before any chart exists). Doesn't block the tiles.
    if (!chart || Date.now() - lastHistoryAt >= HISTORY_MS) {
      lastHistoryAt = Date.now();
      getJSON('/api/history').then(renderChart).catch(() => {});
    }
  } catch (err) {
    $('error').hidden = false;
    $('error').textContent = '⚠ ' + err.message + '  — check credentials in .env and that the server can reach api.sunsynk.net';
  } finally {
    btn.classList.remove('loading');
  }
}

function schedule() {
  clearInterval(timer);
  if ($('auto').checked) timer = setInterval(refresh, REFRESH_MS);
}

$('refresh').addEventListener('click', refresh);
$('auto').addEventListener('change', schedule);

refresh();
schedule();
