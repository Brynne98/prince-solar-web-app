(() => {
const $ = id => document.getElementById(id);
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ---------- the example plant's day, minute by minute ---------- */
const N = 1440, CAP = 46, RES = .2, MAXC = 7.2, CUT0 = 1080, CUT1 = 1125;
const g = (h, c, w) => Math.exp(-0.5 * ((h - c) / w) ** 2);
const nz = (m, s) => Math.sin(m * 0.031 + s) * Math.sin(m * 0.011 + s * 2);
const pvPot = (h, m, s, peak) => { if (h < 6.2 || h > 18.45) return 0; const x = Math.min(1, Math.abs(h - 12.333) / 6.15); return peak * Math.pow(Math.cos(Math.PI / 2 * x), 2.4) * (1 - 0.015 * (1 + nz(m, s))); };
const load = (h, m, s) => 1.04 * (0.95 + 1.5 * g(h, 6.9, .6) + 2.2 * g(h, 12.8, 2.3) + 2.6 * g(h, 18.9, 1.4) + 1.0 * g(h, 21.6, .9) + 0.06 * (1 + nz(m, s + 5)));
function sim(seed, peak, soc0, peakMin) {
  const o = { pv: [], home: [], bat: [], grid: [], soc: [], made: [], used: [], toHome: 0, toBatt: 0 };
  let s = soc0, made = 0, used = 0;
  for (let m = 0; m < N; m++) {
    const h = m / 60; let P = pvPot(h, m, seed, peak);
    if (peakMin != null) P = m === peakMin ? 9.99 : Math.min(P, 9.9);
    const L = load(h, m, seed); let b = 0, gr = 0, sol;
    if (P >= L) { b = Math.min(P - L, MAXC, (1 - s) * CAP * 60); sol = L + b; o.toHome += L / 60; }
    else { const need = L - P; if (s > RES) b = -Math.min(need, MAXC, (s - RES) * CAP * 60); gr = need + b; sol = P; o.toHome += P / 60; }
    s += b / 60 / CAP; made += sol / 60; used += L / 60; o.toBatt += Math.max(0, b) / 60;
    o.pv.push(sol); o.home.push(L); o.bat.push(b); o.grid.push(gr); o.soc.push(s); o.made.push(made); o.used.push(used);
  }
  return o;
}
const D = sim(1, 9.6, .48, 740);

const fmtP = kw => kw < 1 ? [Math.round(kw * 1000 / 10) * 10 + '', 'W'] : [kw.toFixed(2), 'kW'];
const hm = h => { const m = Math.round(h * 60); return m >= 60 ? Math.floor(m / 60) + 'h' + (m % 60 ? ' ' + m % 60 + 'm' : '') : m + 'm'; };
const clock = m => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

/* ---------- chart helpers ---------- */
const NS = 'http://www.w3.org/2000/svg';
function el(tag, attrs, parent) { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); parent && parent.appendChild(e); return e; }
// 30-minute rolling average, so lines read as a shape rather than noise
const smooth = a => a.map((_, i) => { let t = 0, n = 0; for (let k = Math.max(0, i - 15); k <= Math.min(a.length - 1, i + 15); k++) { t += a[k]; n++; } return t / n; });
function path(arr, w, h, max, step = 5, area = true) {
  let d = ''; arr = smooth(arr);
  for (let m = 0; m < arr.length; m += step) { const x = m / (N - 1) * w, y = h - Math.max(0, arr[m]) / max * h; d += (m ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1); }
  return area ? d + `L${w} ${h}L0 ${h}Z` : d;
}
function grad(svg, id, color, a = .45) {
  const defs = svg.querySelector('defs') || el('defs', {}, svg);
  const lg = el('linearGradient', { id, x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
  el('stop', { offset: 0, 'stop-color': color, 'stop-opacity': a }, lg); el('stop', { offset: 1, 'stop-color': color, 'stop-opacity': 0 }, lg);
}

/* live card's Today chart */
const T = $('todaySvg'), TW = 512, TH = 66;
grad(T, 'gS', '#3ddc84', .5);
const clip = el('clipPath', { id: 'tc' }, T.querySelector('defs'));
const clipR = el('rect', { x: 0, y: -10, width: 0, height: TH + 20 }, clip);
for (let i = 0; i <= 4; i++) el('line', { x1: i * TW / 4, x2: i * TW / 4, y1: 0, y2: TH, stroke: 'rgba(255,255,255,.05)' }, T);
const gTc = el('g', { 'clip-path': 'url(#tc)' }, T);
// grid off, shaded like the app's Grid chart: red at 18% (tabs.jsx DayLineChart outages)
el('rect', { x: CUT0 / N * TW, y: 0, width: (CUT1 - CUT0) / N * TW, height: TH, fill: '#ef4444', 'fill-opacity': .18 }, gTc);
el('path', { d: path(D.pv, TW, TH, 10.5), fill: 'url(#gS)' }, gTc);
el('path', { d: path(D.pv, TW, TH, 10.5, 5, false), fill: 'none', stroke: '#3ddc84', 'stroke-width': 1.8, 'vector-effect': 'non-scaling-stroke' }, gTc);
el('path', { d: path(D.home, TW, TH, 10.5, 5, false), fill: 'none', stroke: '#f87171', 'stroke-width': 1.3, 'stroke-opacity': .8, 'vector-effect': 'non-scaling-stroke' }, gTc);
['00', '06', '12', '18', '24'].forEach((t, i) => { const tx = el('text', { x: i * TW / 4, y: TH + 15, 'text-anchor': i === 0 ? 'start' : i === 4 ? 'end' : 'middle', class: 'axis' }, T); tx.textContent = t; });

/* ---------- look back at any day: a year of example days, the chart glides between them ---------- */
(() => {
const TODAY=new Date(2026,9,28),FIRST=new Date(2025,10,1);
const DOW=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'],MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],MFULL=['January','February','March','April','May','June','July','August','September','October','November','December'];
const key=d=>d.getFullYear()+'-'+d.getMonth()+'-'+d.getDate();
const rnd=n=>{let x=Math.sin(n*127.1+311.7)*43758.5453;return x-Math.floor(x)};
const FEAT={'2026-9-3':{made:54.1,peak:9.99,at:'12:20'}};
function info(d){const k=key(d),n=d.getFullYear()*3+d.getMonth()*31+d.getDate();
 const doy=Math.round((d-new Date(d.getFullYear(),0,0))/864e5),sn=Math.cos(2*Math.PI*(doy-355)/365);
 const R=j=>rnd(n*13+j),cloud=R(1)<.143,f=FEAT[k];
 const rise=6.15-.8*sn,set=18.2+.8*sn,len=set-rise,mid=(rise+set)/2;
 let pkT=(8.25+1.5*sn)*(.96+.08*R(2));if(cloud)pkT*=.6+.15*R(3);
 let shift=(R(4)<.5?-1:1)*(10+30*R(5))/60;
 if(f)shift=12+20/60-mid;
 const u0=Math.min(.7,Math.max(.3,.5+shift/len)),g=Math.log(.5)/Math.log(u0);
 const dips=[];let nd=cloud?2+Math.floor(R(6)*3):(R(6)<.4?1:0);
 if(f)nd=0;
 for(let q=0;q<nd;q++)dips.push({c:rise+1.5+R(10+q)*(len-3),sg:(20+40*R(20+q))/60/2.355,d:cloud?.25+.35*R(30+q):.15+.1*R(30+q)});
 const haze=!f&&R(7)<.4?{c:R(8)<.5?mid-3:mid+3,sg:1.6,d:.1+.15*R(9)}:null;
 const build=(p,pk)=>{const ys=[];let sum=0,mx=0;for(let t=0;t<=288;t++){const h=t/12;let v=0;if(h>rise&&h<set){const u=(h-rise)/len;v=Math.pow(Math.sin(Math.PI*Math.pow(u,g)),p);
   for(const q of dips)v*=1-q.d*Math.exp(-.5*Math.pow((h-q.c)/q.sg,2));
   if(haze)v*=1-haze.d*Math.exp(-.5*Math.pow((h-haze.c)/haze.sg,2))}ys.push(v);if(v>mx)mx=v}
  const c=pk/mx;return ys.map(v=>v*c)};
 const area=a=>a.reduce((x,v)=>x+v,0)/12;
 let ys;
 if(f){let lo=1.5,hi=5;for(let it=0;it<30;it++){const p=(lo+hi)/2;ys=build(p,f.peak);if(area(ys)>f.made)lo=p;else hi=p}}
 else{ys=build(3,pkT);const inLast=d>=new Date(2026,8,28)&&d<=new Date(2026,9,27);if(inLast&&area(ys)>52){const c=52/area(ys);ys=ys.map(v=>v*c)}}
 let pk=0,pi=0;ys.forEach((v,i)=>{if(v>pk){pk=v;pi=i}});
 const at=String(Math.floor(pi/12)).padStart(2,'0')+':'+String((pi%12)*5).padStart(2,'0');
 return{made:area(ys),ys,peak:pk,at}}
const fmtD=d=>DOW[d.getDay()]+' '+d.getDate()+' '+MON[d.getMonth()];
let sel=new Date(2026,9,3),view=new Date(2026,9,1),cur=null,raf=0;
const $=id=>document.getElementById('lb-'+id);
const ok=d=>d>=FIRST&&d<=TODAY;
const mob=()=>innerWidth<=860;
function pick(d){sel=d;view=new Date(d.getFullYear(),d.getMonth(),1);$('cal').classList.remove('open');draw()}
// bars: 28 Sep..27 Oct
const days=[];for(let i=0;i<30;i++)days.push(new Date(2026,8,28+i));
const mx=Math.max(...days.map(d=>info(d).made));
days.forEach(d=>{const b=document.createElement('button'),I=info(d);b.setAttribute('aria-label',fmtD(d)+', '+I.made.toFixed(1)+' kWh');b.dataset.k=key(d);if(I.made===mx)b.classList.add('best');b.innerHTML='<i style="height:'+(I.made/mx*100)+'%"></i>';b.onclick=()=>pick(d);$('bars').append(b)});
function chart(I){
 const W=$('svg').clientWidth||600,H=mob()?180:190,L=30,B=24,T=10,pw=W-L-4,ph=H-B-T,max=12,X=h=>L+h/24*pw,Y=v=>T+ph-v/max*ph;
 let s='';for(const v of[0,4,8,12])s+=`<line x1="${L}" x2="${W-4}" y1="${Y(v)}" y2="${Y(v)}" stroke="rgba(255,255,255,.07)"/><text x="${L-8}" y="${Y(v)+4}" text-anchor="end" fill="#8d99a8" font-size="12" font-family="JetBrains Mono">${v}</text>`;
 for(const h of[0,6,12,18,24])s+=`<text x="${X(h)}" y="${H-5}" text-anchor="${h==0?'start':h==24?'end':'middle'}" fill="#8d99a8" font-size="12" font-family="JetBrains Mono">${String(h).padStart(2,'0')}</text>`;
 const line=I.ys.map((v,i)=>`${i?'L':'M'}${X(i/12).toFixed(1)} ${Y(v).toFixed(1)}`).join('');
 s+=`<defs><linearGradient id="lbgr" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3ddc84" stop-opacity=".5"/><stop offset="1" stop-color="#3ddc84" stop-opacity=".04"/></linearGradient></defs><path d="${line}L${X(24)} ${Y(0)}L${X(0)} ${Y(0)}Z" fill="url(#lbgr)"/><path d="${line}" fill="none" stroke="#3ddc84" stroke-width="2.2" stroke-linejoin="round"/>`;
 $('svg').setAttribute('viewBox',`0 0 ${W} ${H}`);$('svg').setAttribute('height',H);$('svg').innerHTML=s}
function stats(m,p,at){$('sm').innerHTML=m.toFixed(1)+'<small>kWh</small>';$('sp').innerHTML=p.toFixed(2).replace(/0$/,'')+'<small>kW at '+at+'</small>'}
function draw(keep){
 const k=key(sel),I=info(sel);
 $('dtext').textContent=fmtD(sel);$('cdate').textContent=fmtD(sel);
 $('prev').disabled=!ok(new Date(sel.getFullYear(),sel.getMonth(),sel.getDate()-1));$('next').disabled=!ok(new Date(sel.getFullYear(),sel.getMonth(),sel.getDate()+1));
 document.querySelectorAll('#lb-bars button').forEach(b=>b.classList.toggle('sel',b.dataset.k===k));
 $('mname').textContent=MFULL[view.getMonth()]+' '+view.getFullYear();
 $('mprev').disabled=view<=new Date(2025,10,1);$('mnext').disabled=view>=new Date(2026,9,1);
 const g=$('grid');g.innerHTML='';const lead=(new Date(view.getFullYear(),view.getMonth(),1).getDay()+6)%7;
 for(let i=0;i<lead;i++)g.append(document.createElement('span'));
 const dim=new Date(view.getFullYear(),view.getMonth()+1,0).getDate();
 for(let n=1;n<=dim;n++){const d=new Date(view.getFullYear(),view.getMonth(),n),good=ok(d);
  const e=document.createElement(good?'button':'span');e.className='d num'+(good?'':' off')+(key(d)===key(TODAY)?' is-today':'')+(key(d)===k?' sel':'');e.textContent=n;
  if(good){e.setAttribute('aria-label',fmtD(d));e.onclick=()=>pick(d)}g.append(e)}
 cancelAnimationFrame(raf);
 const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
 if(keep&&cur&&cur.k===k)return;
 if(!cur||reduce){cur={...I,k};chart(cur);stats(I.made,I.peak,I.at);return}
 const A=cur,t0=performance.now();
 const step=t=>{let p=Math.min(1,(t-t0)/500);const e=1-Math.pow(1-p,3),L=(a,b)=>a+(b-a)*e;
  cur={ys:I.ys.map((v,i)=>L(A.ys[i],v)),made:L(A.made,I.made),peak:L(A.peak,I.peak),at:I.at,k};
  chart(cur);stats(cur.made,cur.peak,I.at);if(p<1)raf=requestAnimationFrame(step)};
 raf=requestAnimationFrame(step);
}
$('prev').onclick=()=>pick(new Date(sel.getFullYear(),sel.getMonth(),sel.getDate()-1));
$('next').onclick=()=>pick(new Date(sel.getFullYear(),sel.getMonth(),sel.getDate()+1));
$('dbox').onclick=()=>{if(mob())$('cal').classList.toggle('open')};
$('mprev').onclick=()=>{view=new Date(view.getFullYear(),view.getMonth()-1,1);draw(1)};$('mnext').onclick=()=>{view=new Date(view.getFullYear(),view.getMonth()+1,1);draw(1)};
addEventListener('resize',()=>chart(cur));
draw();
})();

/* ---------- sky ---------- */
const { hex, mix, rgb, skyAt } = window.Sky; // sky.js

/* stars */
const st = $('stars'); let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
for (let i = 0; i < 140; i++) { const s = document.createElement('i'); s.style.left = rnd() * 100 + '%'; s.style.top = rnd() * 62 + '%'; s.style.opacity = (.25 + rnd() * .75).toFixed(2); if (rnd() > .85) { s.style.width = s.style.height = '3px'; } st.appendChild(s); }

/* ---------- five moments: each one sets the sky and the card once ---------- */
const MO = [[0, 0], [9.0, 540], [12.333, 740], [18.333, 1100], [21.5, 1290]];
$('chEmpty').textContent = 'Empty in ' + hm((D.soc[1290] - RES) * CAP / -D.bat[1290]);
const day = $('day'), stage = $('stage'), top = $('top'), cardEl = $('card');
const card = { tGrid: $('tGrid') };
const moments = [...document.querySelectorAll('.moment')];
// sizes and positions are read here, once and again when they change, never in a scroll frame:
// a read after that frame's writes forced a fresh style and layout pass, ~30 ms a frame on a mid-range phone
let L;
function measure() {
  const y = scrollY, r = cardEl.getBoundingClientRect();
  L = { W: stage.clientWidth, H: stage.clientHeight, dayEnd: day.offsetTop + day.offsetHeight,
    // the card sticks at its sticky top until its column's foot pushes it up; drawn smaller than its box on a phone
    cardTop: parseFloat(getComputedStyle(cardEl).top), cardDrawn: r.height,
    cardLast: cardEl.parentElement.getBoundingClientRect().bottom + y - cardEl.offsetHeight,
    mo: moments.map(e => ({ top: e.getBoundingClientRect().top + y, h: e.offsetHeight })) };
}
function placeSun(h, y, vw) {
  const sunEl = $('sun'), W = L.W, Hh = L.H;
  // the arc's foot and crown; a phone keeps it in the open sky between the card's foot and the hills
  const cardFoot = Math.min(L.cardTop, L.cardLast - y) + L.cardDrawn;
  const phone = vw <= 860, foot = phone ? Hh - 40 : Hh - 110, crown = phone ? cardFoot + 56 : 110;
  const t = (h - 5.9) / (18.8 - 5.9), up = Math.min(1, Math.max(0, t));
  const sx = W * (.06 + .88 * up), sy = foot - Math.pow(Math.sin(Math.PI * up), .55) * (foot - crown);
  sunEl.style.transform = `translate(${sx}px,${sy}px)`;
  sunEl.style.opacity = t > -.02 && t < 1.02 ? 1 : 0;
  const warm = Math.sin(Math.PI * up);
  sunEl.style.setProperty('--sunc', rgb(mix([233, 110, 40], [255, 214, 120], warm)));
  sunEl.style.setProperty('--glow', `rgba(255,${Math.round(150 + warm * 70)},${Math.round(70 + warm * 50)},${(.45 + warm * .2).toFixed(2)})`);
  // the moon crosses the night sky on the same arc
  const moon = $('moon'), mt = ((h < 12 ? h + 24 : h) - 13.3) / 32.7;
  const mx = W * (.06 + .88 * mt), my = foot - Math.pow(Math.sin(Math.PI * Math.min(1, Math.max(0, mt))), .55) * (foot - crown);
  moon.style.transform = `translate(${mx}px,${my}px)`;
}
let navInk, navWas;
function inkNav(y, vh) {
  const inDay = y < L.dayEnd - vh, now = inDay ? navInk : '';
  if (now === navWas) return;
  navWas = now; top.style.color = now; top.classList.toggle('solid', !inDay);
}
function cardAt(m, h) {
  // live card
  const pv = D.pv[m], home = D.home[m], bat = D.bat[m], grid = D.grid[m], soc = D.soc[m];
  const off = m >= CUT0 && m < CUT1;
  $('cTime').textContent = clock(m);
  const [sv, su] = fmtP(pv); $('vSolar').textContent = sv; $('uSolar').textContent = su;
  $('sSolar').textContent = pv < .01 ? (h < 12 ? 'Waiting for sunrise' : 'Sun is down') : `${Math.round(pv / 12.6 * 100)}% of your panels`;
  const [hv, hu] = fmtP(home); $('vHome').textContent = hv; $('vHome').nextElementSibling.textContent = hu;
  const fromBatt = bat < -.1;
  $('sHome').textContent = pv >= home - .05 && pv > .05 ? 'All from solar' : fromBatt && pv > .05 ? `${Math.round(pv / home * 100)}% from solar` : fromBatt ? 'From the battery' : grid > .05 ? 'From the grid' : 'All from solar';
  $('vBatt').textContent = Math.round(soc * 100) + '%'; $('bBatt').style.width = (soc * 100).toFixed(1) + '%'; $('iBatt').setAttribute('width', (soc * 12).toFixed(2));
  const [bv, bu] = fmtP(Math.abs(bat)); $('vBattW').textContent = bv; $('uBattW').textContent = bu;
  $('sBatt').innerHTML = bat > .05 ? (soc > .995 ? 'Full' : (1 - soc) * CAP / bat > 10 ? 'Charging' : 'Full in <b>' + hm((1 - soc) * CAP / bat) + '</b>') : fromBatt ? 'Empty in <b>' + hm((soc - RES) * CAP / -bat) + '</b>' : 'Resting';
  card.tGrid.classList.toggle('off', off);
  const [gv, gu] = fmtP(off ? 0 : grid); $('vGrid').textContent = gv; $('uGrid').textContent = gu;
  $('sGrid').textContent = off ? 'Off since 18:00' : grid > .05 ? 'Importing' : 'On, not in use';
  $('pGrid').textContent = off ? 'Grid off' : 'Grid on';
  // boxes light in their colour while power moves; shares show where solar goes and where home's power comes from
  $('tSolar').classList.toggle('on', pv > .01); $('tBatt').classList.toggle('on', Math.abs(bat) > .03); $('tGrid').classList.toggle('on', !off && grid > .05);
  const share = (id, parts) => { parts = parts.map(v => v > .01 ? v : 0); const t = parts.reduce((a, v) => a + v, 0) || 1; [...$(id).children].forEach((e, i) => { e.style.flexGrow = parts[i] / t; e.style.flexBasis = 0; }); };
  share('spSolar', [Math.min(pv, home), Math.max(0, bat)]);
  share('spHome', [Math.min(pv, home), Math.max(0, -bat), Math.max(0, grid)]);

  const B_ = '<b style="color:#a78bfa">battery</b>', S_ = '<b style="color:#3ddc84">Solar</b>';
  let n;
  if (off) n = fromBatt ? `<b>The grid is off.</b> Your ${B_} is powering the home, with about ${hm((soc - RES) * CAP / -bat)} left.` : `<b>The grid is off.</b> ${S_} is covering the home${bat > .05 ? ' and charging the battery' : ''}.`;
  else if (pv > .05 && pv >= home - .05) n = `${S_} is covering the home${bat > .05 ? ' and charging the battery' : ''}.`;
  else if (fromBatt && pv > .05) n = `${S_} and your ${B_} are powering the home.`;
  else if (fromBatt) n = `Your ${B_} is powering the home.`;
  else if (grid < .05) n = `${S_} is covering the home.`;
  else n = `Using <b style="color:#facc15">${fmtP(grid).join(' ')}</b> from the grid.`;
  const narr = $('narr'); if (narr.innerHTML !== n) narr.innerHTML = n; narr.classList.toggle('alert', off);

  // flow pulses: speed follows power
  const line = (id, kw, rev) => { const on = kw > .01, d = $(id), b = $(id + 'B'); d.classList.toggle('on', on); b.classList.toggle('on', on); d.classList.toggle('rev', !!rev);
    const dur = Math.max(.9, 3.2 - Math.min(kw, 8) / 8 * 2.3).toFixed(1) + 's'; if (d.style.getPropertyValue('--d') !== dur) d.style.setProperty('--d', dur); };
  line('lSolar', pv); line('lBatt', Math.abs(bat), bat > 0); line('lGrid', off ? 0 : grid); line('lHome', home);
  $('lGridB').classList.toggle('cut', off);

  // today chart
  const cx = m / (N - 1) * TW; clipR.setAttribute('width', cx);
  $('stMade').textContent = D.made[m].toFixed(1); $('stUsed').textContent = D.used[m].toFixed(1);
  let peak = 0; for (let k = 0; k <= m; k += 1) if (D.pv[k] > peak) peak = D.pv[k];
  const [pkv, pku] = fmtP(peak); $('stPeak').textContent = pkv; $('stPeakU').textContent = pku;

  // toasts
  $('toastPct').textContent = Math.round(D.soc[CUT0] * 100) + '%';
  $('toastDown').classList.toggle('on', m >= CUT0 && m < CUT1);
  $('toastBack').classList.toggle('on', m >= CUT1 && m < CUT1 + 60);

}
/* the day runs 00:00 to 24:00 with the scroll; sky, sun, moon and the card's numbers and graph move together, eased so they glide */
// the colours go on the few elements that paint them: set on #day they restyled the whole scene, all 140 stars too
const sky = $('sky'), ground = [...document.querySelectorAll('.land,.house')], panels = [...document.querySelectorAll('#panels path')], wins = [...document.querySelectorAll('.win')];
let darkWas, litWas;
function skyTo(h) {
  const s = skyAt(h);
  sky.style.setProperty('--s1', s.c[0]); sky.style.setProperty('--s2', s.c[1]); sky.style.setProperty('--s3', s.c[2]);
  ground.forEach(e => { e.style.setProperty('--l1', s.c[3]); e.style.setProperty('--l2', s.c[4]); });
  const dark = s.ink > .5;
  if (dark !== darkWas) {
    darkWas = dark; const set = (n, v) => day.style.setProperty(n, v);
    set('--ink', dark ? '#20160a' : '#f3eee4'); set('--ink-soft', dark ? 'rgba(32,22,10,.78)' : 'rgba(243,238,228,.8)'); set('--accent', dark ? '#7a3f00' : '#ffd27a');
    navInk = dark ? '#20160a' : '#f3eee4'; navWas = null;
  }
  st.style.opacity = s.stars; $('moon').style.opacity = Math.min(1, s.stars * 1.4);
  const panelLit = Math.max(0, Math.sin(Math.PI * (h - 6.2) / 12.25));
  panels.forEach(e => e.setAttribute('fill', `rgba(${120 + panelLit * 130},${150 + panelLit * 90},${200 - panelLit * 40},${.35 + panelLit * .55})`));
  const lit = h < 6.6 || h > 17.6;
  if (lit !== litWas) { litWas = lit; wins.forEach(e => e.setAttribute('fill', lit ? '#ffd27a' : 'rgba(0,0,0,.35)')); }
}
function hourAtScroll(y, vh, vw) {
  // a moment's hour lands where it settles: centred on desktop, its foot on the screen's foot on a phone
  const c = y + vh / 2, mid = o => o.top + (vw <= 860 ? o.h - vh / 2 : o.h / 2);
  for (let i = 0; i < L.mo.length - 1; i++) {
    const a = mid(L.mo[i]), b = mid(L.mo[i + 1]);
    if (c <= b) { const t = Math.min(1, Math.max(0, (c - a) / (b - a))); return MO[i][0] + (MO[i + 1][0] - MO[i][0]) * (t * t * (3 - 2 * t)); }
  }
  // after the last moment the clock runs on to midnight as that moment leaves
  const lastM = L.mo[L.mo.length - 1], a = mid(lastM), b = a + lastM.h / 2;
  const t = Math.min(1, Math.max(0, (c - a) / (b - a)));
  return MO[MO.length - 1][0] + (24 - MO[MO.length - 1][0]) * t;
}
/* each moment fades in while it holds the middle of the screen, and out as it leaves */
const cardOut = (y, vh) => {
  L.mo.forEach((o, i) => moments[i].classList.toggle('on', Math.abs(o.top - y + o.h / 2 - vh / 2) < vh * .3));
  const lastM = L.mo[L.mo.length - 1];
  cardEl.classList.toggle('gone', lastM.top + lastM.h - y < vh * .4);
};
let hNow, hDrawn, mDrawn, last = 0, raf = 0;
// every read comes first, then the writes; the scene redraws only when the hour moved, the card only when the minute did
function tick(ts) {
  const y = scrollY, vh = innerHeight, vw = innerWidth;
  const target = hourAtScroll(y, vh, vw), dt = last && ts ? ts - last : 16; last = ts || 0;
  hNow = reduce || hNow == null ? target : hNow + (target - hNow) * (1 - Math.exp(-dt / 220));
  if (Math.abs(target - hNow) < .002) hNow = target;
  if (hNow !== hDrawn) { hDrawn = hNow; skyTo(hNow); }
  // every frame: on a phone the arc rides under the card, and the card scrolls away after the day
  placeSun(hNow, y, vw);
  const m = Math.min(N - 1, Math.round(hNow * 60));
  if (m !== mDrawn) { mDrawn = m; cardAt(m, hNow); }
  inkNav(y, vh); cardOut(y, vh);
  raf = hNow === target ? 0 : requestAnimationFrame(tick);
  if (!raf) last = 0;
}
const kick = () => { if (!raf) raf = requestAnimationFrame(tick); };
addEventListener('scroll', kick, { passive: true });
/* phone: the card fits the width, and also leaves room under it for the tallest moment's words */
const fitCard = () => {
  let k = Math.min(1, (innerWidth - 32) / cardEl.offsetWidth);
  if (innerWidth <= 860) {
    const words = Math.max(...moments.map(m => { const c = [...m.children].filter(e => e.offsetHeight); return c[c.length - 1].getBoundingClientRect().bottom - c[0].getBoundingClientRect().top; }));
    k = Math.min(k, (innerHeight - 68 - 20 - parseFloat(getComputedStyle(moments[0]).paddingBottom) - words) / cardEl.offsetHeight);
  }
  cardEl.style.setProperty('--k', k.toFixed(3));
};
const refit = () => { fitCard(); measure(); hDrawn = mDrawn = null; cancelAnimationFrame(raf); raf = 0; tick(); };
refit();
addEventListener('resize', refit);
// late fonts change the words' heights, and with them where each moment sits
document.fonts.ready.then(refit);

/* ---------- reveals ---------- */
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -12% 0px' });
document.querySelectorAll('.rv').forEach(e => io.observe(e));
const pr = $('pricing');
pr.querySelectorAll('.period button').forEach(b => b.addEventListener('click', () => {
  pr.dataset.period = b.dataset.p;
  pr.querySelectorAll('.period button').forEach(x => x.setAttribute('aria-pressed', x === b));
  pr.querySelectorAll('[data-plan]').forEach(a => a.href = `https://app.princesolarhub.co.za/?signup&plan=${a.dataset.plan}&period=${b.dataset.p === 'y' ? 'yearly' : 'monthly'}`);
}));

pr.querySelectorAll('[data-plan]').forEach(a => a.addEventListener('click', () => window.track?.('plan_picked', { plan: a.dataset.plan, period: pr.dataset.period === 'y' ? 'yearly' : 'monthly' })));

/* ---------- an open offer (SOLAR-330): the list prices above stay if this can't be read ---------- */
addEventListener('DOMContentLoaded', async () => {
  const cfg = window.SUNSYNK_CONFIG;
  if (!cfg) return;
  let r;
  try {
    const res = await fetch(`${cfg.url}/rest/v1/rpc/api_offer`, { method: 'POST', headers: { apikey: cfg.key, 'Content-Type': 'application/json' }, body: '{}' });
    r = res.ok ? await res.json() : null;
  } catch (e) { return; }
  if (!r?.offer) return;
  const R = (n) => 'R' + Math.round(n).toLocaleString('en-US').replace(/,/g, '\u00a0'); // "R1 799", as the app
  const at = { m: r.prices.monthly, y: r.prices.yearly }, was = { m: r.listPrices.monthly, y: r.listPrices.yearly };
  const unit = { m: 'a month', y: 'a year' };
  for (const k of ['m', 'y']) {
    for (const p of ['home', 'family']) {
      pr.querySelector(`.price[data-offer="${p}"] .${k}`).innerHTML = `<s>${R(was[k][p])}</s>${R(at[k][p])}<small>${unit[k]}</small>`;
      pr.querySelector(`.per[data-offer="${p}"] .${k}`).textContent = `Save ${R(was[k][p] - at[k][p])} ${unit[k]}`;
    }
  }
  // Free keeps its price level with the struck-out prices beside it
  pr.querySelector('.price[data-offer="free"]').innerHTML = '<s aria-hidden="true" style="visibility:hidden">R0</s>R0';
  const o = r.offer, off = Math.round(100 * (1 - at.m.home / was.m.home));
  const head = `${o.id === 'launch' ? 'Launch price' : 'Offer price'}: ${off >= 45 && off <= 55 ? 'half off' : `${off}% off`}${o.cap ? ` for the first ${o.cap} members` : ''}`;
  const keep = o.months ? `For your first ${o.months} months, then the usual price.` : 'Keep it while your plan stays paid.';
  const band = pr.querySelector('.offer-band');
  band.innerHTML = `<b>${head}.</b> ${keep}`;
  band.hidden = false;
  const bar = document.querySelector('.offer-bar');
  bar.firstChild.textContent = head + '. ';
  bar.hidden = false;
  document.documentElement.style.setProperty('--bar', bar.offsetHeight + 'px');
  const q = document.querySelector('.offer-q');
  q.querySelector('summary').firstChild.textContent = `What is the ${o.id === 'launch' ? 'launch' : 'offer'} price?`;
  q.querySelector('p').textContent = [o.cap ? `The first ${o.cap} members to pay` : 'Members who join now',
    ` get Home for ${R(at.m.home)} and Family for ${R(at.m.family)} a month, instead of ${R(was.m.home)} and ${R(was.m.family)}. `,
    o.months ? `It lasts your first ${o.months} months, then the usual price applies.` : 'You keep it while your plan stays paid. Move to Free and it ends.',
    o.cap ? ` Once ${o.cap} members have joined, it's gone.` : ''].join('');
  q.hidden = false;
});

/* ---------- questions: one open at a time, eased ---------- */
(() => {
const qs = [...document.querySelectorAll('.qs details')];
document.querySelector('.qs').classList.add('js');
const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
const ease = 'cubic-bezier(.2,.8,.2,1)';
const run = (p, frames, ms) => still ? { finished: Promise.resolve() } : p.animate(frames, { duration: ms, easing: ease });
const shut = d => {
  const p = d.querySelector('p');
  d.classList.remove('on');
  run(p, [{ height: p.offsetHeight + 'px', paddingBottom: '26px', opacity: 1 }, { height: '0px', paddingBottom: '0px', opacity: 0 }], 260)
    .finished.then(() => { if (!d.classList.contains('on')) d.open = false; }, () => {}); // cancelled by a reopen
};
qs.forEach(d => d.querySelector('summary').addEventListener('click', e => {
  e.preventDefault();
  if (d.classList.contains('on')) return shut(d);
  qs.filter(x => x.classList.contains('on')).forEach(shut);
  d.open = true; d.classList.add('on');
  const p = d.querySelector('p');
  p.getAnimations().forEach(a => a.cancel());
  run(p, [{ height: '0px', paddingBottom: '0px', opacity: 0, transform: 'translateY(-6px)' }, { height: p.offsetHeight + 'px', paddingBottom: '26px', opacity: 1, transform: 'none' }], 360);
}));
// the browser can open one itself (find in page): keep the class and the one-open rule in step
qs.forEach(d => d.addEventListener('toggle', () => {
  if (!d.open || d.classList.contains('on')) return;
  qs.filter(x => x.classList.contains('on')).forEach(shut);
  d.classList.add('on');
}));
})();

/* ---------- inbox: open any of the example emails ---------- */
(() => {
const C={solar:'#3ddc84',home:'#f87171',grid:'#facc15',cyan:'#22d3ee',batt:'#a78bfa',plain:'#e7ecf2',ok:'#84cc16',bad:'#ef4444'};
const d=(n,prev,good)=>({n,prev,good});
const delta=x=>!x?'':`<div class="ib-d"><b style="color:${x.good===undefined?'#9aa5b3':x.good?C.ok:C.bad}">${x.n>0?'↑':'↓'} ${Math.abs(x.n)}%</b> vs ${x.prev}</div>`;
const card=c=>`<div class="ib-card"><div class="ib-l">${c.l}</div><div class="ib-v" style="color:${C[c.tone||'plain']}">${c.v}${c.u?`<small>${c.u}</small>`:''}</div>${c.sub?`<div class="ib-d">${c.sub}</div>`:''}${delta(c.delta)}</div>`;
// The example plant's mail, worded and laid out as the app's own emails (supabase/functions/_shared/email.ts)
const MAIL=[
 {k:'week',dot:C.solar,time:'26 Oct',at:'Mon 26 Oct, 07:00',subject:'Weekly solar report for Example plant: 19 – 25 Oct 2026',preview:'Made 341 kWh, est. saved R1 027',
  title:'19 – 25 Oct 2026',sub:'Example plant',
  stats:[{l:'Made',v:'341',u:'kWh',tone:'solar',delta:d(6,'last week',true)},{l:'Home',v:'367',u:'kWh',tone:'home',delta:d(-3,'last week',true)},{l:'Imported',v:'70.0',u:'kWh',tone:'grid',delta:d(-12,'last week',true)},{l:'Independence',v:'81%',tone:'cyan',delta:d(4,'last week',true)},{l:'Est. saved',v:'R1 027',tone:'batt',delta:d(5,'last week',true)}],
  bars:{title:'Solar each day',side:'Average 48.7 kWh a day',labels:['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],vals:[46.2,51.3,38.4,49.8,48.1,55.6,51.6]},
  facts:[{l:'Best day',v:'55.6',u:'kWh',tone:'solar',sub:'Sat 24 Oct'},{l:'Busiest day',v:'58.9',u:'kWh',tone:'home',sub:'Sun 25 Oct'}],
  btn:'Open Live'},
 {k:'panels',dot:C.bad,time:'20 Oct',at:'Tue 20 Oct, 11:55',subject:'Panels stopped producing at Example plant',preview:'Inverter 1, string 3: no power since 11:42',
  title:'Panels stopped producing at Example plant',stack:1,stats:[{l:'Inverter 1, string 3',v:'No power',tone:'bad',sub:'since 11:42 today'},{l:'Other panels',v:'OK',tone:'ok'}],btn:'Open Equipment'},
 {k:'hot',dot:C.bad,time:'12 Oct',at:'Mon 12 Oct, 14:21',subject:'Battery hot at Example plant',preview:'Battery 41 °C at 14:20',
  title:'Battery hot at Example plant',stack:1,stats:[{l:'Battery',v:'41&nbsp;°C',tone:'bad',sub:'at 14:20 today'}],btn:'Open Equipment'},
 {k:'back',dot:C.grid,time:'3 Oct',at:'Sat 3 Oct, 18:45',subject:'Grid back at Example plant',preview:'Grid on since 18:45 today, outage 45m',
  title:'Grid back at Example plant',stack:1,stats:[{l:'Grid',v:'On',tone:'ok',sub:'since 18:45 today'},{l:'Outage',v:'45m'}],btn:'Open Grid'},
 {k:'down',dot:C.bad,time:'3 Oct',at:'Sat 3 Oct, 18:00',subject:'Grid down at Example plant',preview:'Grid off since 18:00 today, battery 86%',
  title:'Grid down at Example plant',stack:1,stats:[{l:'Grid',v:'Off',tone:'bad',sub:'since 18:00 today'},{l:'Battery',v:'86%',tone:'batt'}],btn:'Open Grid'}
];
const rows=document.getElementById('ib-rows'),view=document.getElementById('ib-view'),box=view.parentNode,rowEls=[];
let cur=0;
// phone: the open email sits right under its row; a tapped row then glides up to just under the top bar.
// Move the email only when it is in the wrong place: re-inserting it replays its fade, and a phone fires
// resize each time its address bar hides or shows, which made the email flicker on every scroll turn.
function place(y){
 const r=rowEls[cur],phone=innerWidth<=860;
 if(phone&&view.previousElementSibling!==r)r.after(view);else if(!phone&&view.parentNode!==box)box.append(view);
 // a laptop always shows one email beside the list, so one closed on a phone opens again
 if(!phone&&view.hidden){view.hidden=false;r.setAttribute('aria-selected',true)}
 if(y===undefined||!phone)return;
 scrollBy({top:r.getBoundingClientRect().top-y,behavior:'instant'});
 scrollBy({top:r.getBoundingClientRect().top-68,behavior:'smooth'});
}
function show(i,tap){
 const m=MAIL[i],y=rowEls[i].getBoundingClientRect().top;cur=i;
 rowEls.forEach((r,j)=>{r.setAttribute('aria-selected',j===i);r.tabIndex=j===i?0:-1});
 let h=`<div class="ib-from"><span class="ib-orb"></span><span><b>Prince Solar Hub</b></span><span>${m.at}</span></div><div class="ib-subj">${m.subject}</div><div class="ib-title">${m.title}</div>${m.sub?`<div class="ib-sub">${m.sub}</div>`:''}`;
 h+=`<div class="ib-stats${m.stack?' ib-stack':''}">${m.stats.map(card).join('')}</div>`;
 if(m.note)h+=`<p class="ib-note">${m.note}</p>`;
 if(m.bars){const b=m.bars,mx=Math.max(...b.vals),bi=b.vals.indexOf(mx);
  h+=`<div class="ib-chart"><div class="ib-ch"><b>${b.title}</b><span>${b.side}</span></div><div class="ib-bars">${b.vals.map((v,j)=>`<div ${j===bi?`class="ib-best" data-v="${v} kWh"`:''} style="height:${v/mx*100}%"></div>`).join('')}</div><div class="ib-lbls">${b.labels.map((l,j)=>`<span${j===bi?' class="ib-best"':''}>${l}</span>`).join('')}</div>
  <div class="ib-facts">${m.facts.map(card).join('')}</div></div>`}
 h+=`<button type="button" class="ib-btn">${m.btn}</button>`;
 view.innerHTML=h;view.hidden=false;
 place(tap?y:undefined);
}
MAIL.forEach((m,i)=>{const r=document.createElement('button');r.className='ib-row';r.setAttribute('role','tab');
 r.innerHTML=`<i style="background:${m.dot}"></i><span class="ib-s">${m.subject}</span><span class="ib-t">${m.time}</span><span class="ib-p">${m.preview}</span>`;
 // phone: tapping the open email's row closes it
 r.onclick=()=>{if(innerWidth<=860&&i===cur&&!view.hidden){view.hidden=true;r.setAttribute('aria-selected',false);return}show(i,true)};
 r.onkeydown=e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();const n=(i+(e.key==='ArrowDown'?1:-1)+MAIL.length)%MAIL.length;show(n);rowEls[n].focus()}};
 rows.append(r);rowEls.push(r)});
show(0);
addEventListener('resize',()=>place());
})();


})();

/* ---------- selling demos (SOLAR-334): each plays on its own while on screen; a click or drag hands it to the viewer ---------- */
const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
function autoplay(el, ms, step) {
  let t = null, held = false;
  new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting && !t && !held && !calm) t = setInterval(step, ms);
    if (!e.isIntersecting) { clearInterval(t); t = null; }
  }), { threshold: .3 }).observe(el);
  return () => { held = true; clearInterval(t); t = null; };
}
const hm = m => String(Math.floor(m / 60) % 24).padStart(2, '0') + ':' + String(Math.round(m % 60)).padStart(2, '0');
const rand = n => 'R' + Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');

/* battery time left: a night on the example plant, the countdown redone every 5 minutes */
(() => {
const g = id => document.getElementById('bt-' + id), svg = g('svg');
if (!svg) return;
const CAP = 20, RES = 20, STEP = 5;
// the home's use from each hour on, kW: the stove at 18:30, quiet from 23:00, the kettle at 06:00
const USE = [[18, 2.6], [18.5, 4.2], [19, 2.1], [20, 1.5], [21, 1.2], [22, .7], [23, .45], [29, .6], [30, 1.3]];
const use = h => USE.reduce((v, [a, k]) => h >= a ? k : v, USE[0][1]);
const pts = [];
for (let m = 18 * 60, soc = 90; m <= 31 * 60; m += STEP) { const k = use(m / 60); pts.push({ m, soc, k }); soc -= k * STEP / 60 / CAP * 100; }
const X = m => 10 + (m - 18 * 60) / (13 * 60) * 500, Y = s => 12 + (100 - s) * 1.1;
const dur = h => { const t = Math.round(h * 60); return Math.floor(t / 60) + ' h ' + t % 60 + ' m'; };
const line = pts.map((p, i) => (i ? 'L' : 'M') + X(p.m).toFixed(1) + ' ' + Y(p.soc).toFixed(1)).join(' ');
svg.innerHTML = `<defs><linearGradient id="bt-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#a78bfa" stop-opacity=".35"/><stop offset="1" stop-color="#a78bfa" stop-opacity="0"/></linearGradient><clipPath id="bt-clip"><rect id="bt-cr" x="0" y="0" width="10" height="150"/></clipPath></defs>`
  + `<line x1="10" x2="510" y1="${Y(RES)}" y2="${Y(RES)}" stroke="#a78bfa" stroke-opacity=".55" stroke-dasharray="4 4"/><text x="510" y="${Y(RES) - 6}" text-anchor="end" class="axis">reserve ${RES}%</text>`
  + `<path d="${line}" fill="none" stroke="rgba(167,139,250,.35)" stroke-width="2" stroke-dasharray="3 5"/>`
  + `<g clip-path="url(#bt-clip)"><path d="${line} L510 ${Y(0)} L10 ${Y(0)}Z" fill="url(#bt-g)"/><path d="${line}" fill="none" stroke="#a78bfa" stroke-width="2.5"/></g>`
  + `<line id="bt-now" y1="4" y2="${Y(0)}" stroke="rgba(255,255,255,.3)"/><circle id="bt-dot" r="5.5" fill="#a78bfa" stroke="#0c1117" stroke-width="2.5"/>`
  + [18, 22, 26, 30].map((h, i) => `<text x="${X(h * 60)}" y="144" text-anchor="${i ? 'middle' : 'start'}" class="axis">${hm(h * 60)}</text>`).join('');
let i = 0, hold = 0, at = { x: 0, y: 0 }, raf = 0;
function place(x, y) {
  at = { x, y };
  g('cr').setAttribute('width', x);
  ['x1', 'x2'].forEach(a => g('now').setAttribute(a, x));
  g('dot').setAttribute('cx', x); g('dot').setAttribute('cy', y);
}
// linear over one step, so steps join into one steady movement; back to the start it jumps
function glide(x, y, ms) {
  cancelAnimationFrame(raf);
  if (!ms || x < at.x) return place(x, y);
  const from = at, t0 = performance.now();
  const f = t => { const k = Math.min(1, (t - t0) / ms); place(from.x + (x - from.x) * k, from.y + (y - from.y) * k); if (k < 1) raf = requestAnimationFrame(f); };
  raf = requestAnimationFrame(f);
}
function show(n, ms) {
  i = n;
  const p = pts[n], left = (p.soc - RES) / 100 * CAP / p.k, end = p.m + left * 60;
  g('clock').textContent = hm(p.m);
  g('left').innerHTML = dur(left).replace(/ ([hm])/g, '<small>$1</small>');
  g('at').textContent = 'Reaches the ' + RES + '% reserve ' + (end >= 30 * 60 ? 'after sunrise' : 'at ' + hm(end));
  g('soc').textContent = Math.round(p.soc) + '%';
  g('load').textContent = p.k < 1 ? Math.round(p.k * 1000) + ' W' : p.k.toFixed(1) + ' kW';
  g('load').classList.toggle('hi', p.k >= 3);
  glide(X(p.m), Y(p.soc), ms);
  g('range').value = n;
  g('range').setAttribute('aria-valuetext', hm(p.m) + ', empty in ' + dur(left));
}
g('range').max = pts.length - 1;
const stop = autoplay(svg.parentNode, 160, () => { if (i === pts.length - 1 && hold++ < 16) return; hold = 0; show((i + 1) % pts.length, 160); });
g('range').addEventListener('input', e => { stop(); show(+e.target.value); });
show(calm ? 6 : 0);
})();

/* faults: the Equipment card, all working or with one problem, worded as the app words it (tabs.jsx) */
(() => {
const card = document.getElementById('fl-card'), picks = document.getElementById('fl-picks'), tiles = document.getElementById('fl-tiles');
if (!card) return;
const ok = ['ok', 'Working'], look = ['warn', 'Needs a look'], chg = ['ok', 'Charging'];
const T = (pv, batt, inv) => [['Solar panels', 'var(--solar)', pv[0], 'kW', pv[1]], ['Battery', 'var(--batt)', batt[0], '%', batt[1]], ['Inverters', inv[1] === ok ? 'var(--ok)' : 'var(--warn)', inv[0], '', inv[1]]];
const S = [
  { k: 'All working', tiles: T(['4.82', ok], ['64', chg], ['All on', ok]) },
  { k: 'Panels stopped', title: 'Some panels made nothing today', todo: 'Check the breaker or isolator for your panels.', since: 'Since 11:42', tiles: T(['3.06', look], ['58', chg], ['All on', ok]) },
  { k: 'Panels weak', title: 'Some panels are making less than usual', todo: 'Check for shade, dirt or a tripped breaker.', since: 'Today', tiles: T(['3.91', look], ['61', chg], ['All on', ok]) },
  { k: 'Battery hot', title: 'The battery is hot, 46 °C', todo: 'Make sure air can move around it.', since: 'Since 13:20', tiles: T(['4.82', ok], ['64', look], ['All on', ok]) },
  { k: 'Uneven batteries', title: 'Batteries charging unevenly', todo: 'Pack 1 is at 72%, pack 2 at 60%. The gap has grown all week.', since: 'For over an hour', tiles: T(['4.82', ok], ['66', look], ['All on', ok]) },
  { k: 'Inverter quiet', title: 'Inverter 2 isn’t reporting', todo: 'Check it is on and its Wi-Fi dongle shows a light.', since: 'Last reading 40 min ago', tiles: T(['2.47', ok], ['64', chg], ['1 of 2', look]) },
];
let cur = 0;
function show(n) {
  cur = n;
  const s = S[n];
  card.classList.toggle('warn', !!s.title);
  document.getElementById('fl-head').textContent = s.title ? '1 thing needs a look' : 'Everything is working';
  if (s.title) [['title', s.title], ['todo', s.todo], ['since', s.since]].forEach(([k, v]) => document.getElementById('fl-' + k).textContent = v);
  if (!tiles.children.length) tiles.innerHTML = s.tiles.map(() => '<div class="fl-tile"><div class="v"></div><div class="l"></div><div class="s"><i></i><span></span></div></div>').join('');
  s.tiles.forEach(([l, c, v, u, [tone, word]], j) => {
    const t = tiles.children[j];
    t.className = 'fl-tile ' + tone;
    t.querySelector('.v').style.color = c;
    t.querySelector('.v').innerHTML = v + (u ? `<small>${u}</small>` : '');
    t.querySelector('.l').textContent = l;
    t.querySelector('.s span').textContent = word;
  });
  [...picks.children].forEach((b, j) => b.setAttribute('aria-pressed', j === n));
}
S.forEach((s, n) => { const b = document.createElement('button'); b.type = 'button'; b.textContent = s.k; b.addEventListener('click', () => { stop(); show(n); }); picks.appendChild(b); });
const stop = autoplay(card, 3200, () => show((cur + 1) % S.length));
show(0);
})();

/* savings: saved so far, against the time before; the line draws itself on each change */
(() => {
const svg = document.getElementById('sv-svg'), seg = document.getElementById('sv-seg');
if (!svg) return;
const g = id => document.getElementById('sv-' + id);
const P = {
  week: { saved: 1027, prev: 978, ind: 81, indPrev: 77, n: 7, k1: '19-25 Oct', k2: '12-18 Oct', from: 'the week before', ax: [[0, 'Mon'], [3, 'Thu'], [6, 'Sun']] },
  month: { saved: 4509, prev: 4208, ind: 81, indPrev: 78, n: 31, k1: 'October', k2: 'September', from: 'September', ax: [[0, '1'], [14, '15'], [30, '31']] },
  year: { saved: 48960, prev: 43410, ind: 79, indPrev: 77, n: 12, k1: '2025', k2: '2024', from: '2024', ax: [[0, 'Jan'], [5, 'Jun'], [11, 'Dec']] },
};
// each day's or month's share, uneven like real weather, summed so the line ends on the total
const run = (n, total, seed) => { const v = Array.from({ length: n }, (_, i) => 1 + .32 * Math.sin(i * 1.9 + seed) + .18 * Math.sin(i * 4.3 + seed * 2)); const s = v.reduce((a, b) => a + b, 0); let c = 0; return v.map(x => c += x / s * total); };
let shown = 0, raf = 0, on = 'month';
function draw(k, anim) {
  on = k;
  const p = P[k], a = run(p.n, p.saved, 1), b = run(p.n, p.prev, 2.4), max = Math.max(p.saved, p.prev) * 1.12;
  const X = i => 20 + i / (p.n - 1) * 470, Y = v => 186 - v / max * 170;
  const path = arr => arr.map((v, i) => (i ? 'L' : 'M') + X(i).toFixed(1) + ' ' + Y(v).toFixed(1)).join(' ');
  svg.innerHTML = `<defs><linearGradient id="sv-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#a78bfa" stop-opacity=".3"/><stop offset="1" stop-color="#a78bfa" stop-opacity="0"/></linearGradient></defs>`
    + `<line x1="20" x2="490" y1="186" y2="186" stroke="rgba(255,255,255,.1)"/>`
    + `<path d="${path(b)}" fill="none" stroke="#7f8da0" stroke-width="2" stroke-dasharray="5 5"/>`
    + `<path id="sv-area" d="${path(a)} L490 186 L20 186Z" fill="url(#sv-g)"/>`
    + `<path id="sv-line" d="${path(a)}" fill="none" stroke="#a78bfa" stroke-width="2.8" stroke-linejoin="round"/>`
    + `<text x="498" y="${Y(p.saved) + 4}" class="axis" style="fill:#a78bfa;font-weight:700">${rand(p.saved)}</text>`
    + `<text x="498" y="${Y(p.prev) + (Y(p.prev) - Y(p.saved) < 14 ? 16 : 4)}" class="axis">${rand(p.prev)}</text>`
    + p.ax.map(([at, t], i) => `<text x="${X(at).toFixed(1)}" y="206" text-anchor="${['start', 'middle', 'end'][i]}" class="axis">${t}</text>`).join('');
  const up = n => (n >= 0 ? '↑ ' : '↓ ') + Math.abs(n) + '%';
  g('st').innerHTML = `<b>${up(Math.round((p.saved / p.prev - 1) * 100))}</b> on ${p.from}`;
  g('it').innerHTML = `<b>${up(p.ind - p.indPrev)}</b> on ${p.from}`;
  g('ind').textContent = p.ind + '%';
  g('bar').style.transform = `scaleX(${p.ind / 100})`;
  g('k1').textContent = p.k1; g('k2').textContent = p.k2;
  seg.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', x.dataset.k === k));
  cancelAnimationFrame(raf);
  if (!anim || calm) { shown = p.saved; g('saved').textContent = rand(p.saved); return; }
  const line = document.getElementById('sv-line'), len = line.getTotalLength(), from = shown, t0 = performance.now();
  line.style.strokeDasharray = len; line.style.strokeDashoffset = len;
  document.getElementById('sv-area').style.opacity = 0;
  const step = t => {
    const f = Math.min(1, (t - t0) / 900), e = 1 - Math.pow(1 - f, 3);
    line.style.strokeDashoffset = len * (1 - e);
    document.getElementById('sv-area').style.opacity = e;
    shown = from + (p.saved - from) * e;
    g('saved').textContent = rand(shown);
    if (f < 1) raf = requestAnimationFrame(step);
  };
  raf = requestAnimationFrame(step);
}
seg.addEventListener('click', e => { const b = e.target.closest('button'); if (b) draw(b.dataset.k, true); });
draw('month');
const io = new IntersectionObserver(es => { if (es[0].isIntersecting) { io.disconnect(); draw(on, true); } }, { threshold: .4 });
io.observe(svg);
})();

/* wall view: the hero's power flow, copied onto a TV, moving through a day */
(() => {
const box = document.getElementById('w-in'), src = document.querySelector('#card .flow');
if (!box || !src) return;
const f = src.cloneNode(true);
f.querySelectorAll('[id]').forEach(e => e.id = 'w-' + e.id);
f.querySelectorAll('.on,.rev,.off,.cut').forEach(e => e.classList.remove('on', 'rev', 'off', 'cut'));
box.appendChild(f);
const w = id => document.getElementById('w-' + id);
const screen = box.parentNode;
const fit = () => box.style.transform = `scale(${screen.clientWidth / 800})`;
fit();
new ResizeObserver(fit).observe(screen);
// solar, battery (+ out, - in), grid in, home: kW; soc %
const S = [
  { t: '12:40', narr: 'The sun runs the house and fills the battery.', solar: 6.42, batt: -4.91, grid: 0, home: 1.51, soc: 74 },
  { t: '16:10', narr: 'The battery is full. The sun runs the house.', solar: 2.38, batt: 0, grid: 0, home: 2.38, soc: 100 },
  { t: '18:05', narr: 'Grid off. The battery runs the house.', solar: 0, batt: 1.86, grid: 0, home: 1.86, soc: 92, off: 1 },
  { t: '21:30', narr: 'The battery runs the house through the night.', solar: 0, batt: 0.72, grid: 0, home: 0.72, soc: 71 },
];
const kw = v => v < 1 ? [Math.round(v * 1000), 'W'] : [v.toFixed(2), 'kW'];
const lane = (k, on, rev, v) => { w('l' + k + 'B').classList.toggle('on', on); const d = w('l' + k); d.classList.toggle('on', on); d.classList.toggle('rev', !!rev); };
const grow = (id, parts) => { const t = parts.reduce((a, b) => a + b, 0) || 1; [...w(id).children].forEach((e, i) => { e.style.flexGrow = parts[i] / t; e.style.flexBasis = 0; }); };
let cur = 0;
function show(n) {
  cur = n;
  const s = S[n], bIn = s.batt < 0 ? -s.batt : 0, bOut = s.batt > 0 ? s.batt : 0;
  w('clock').textContent = s.t;
  w('narr').textContent = s.narr;
  [['Solar', s.solar], ['Grid', s.grid], ['BattW', Math.abs(s.batt)]].forEach(([k, v]) => { const [a, u] = v ? kw(v) : [0, 'W']; w('v' + k).textContent = a; w('u' + k).textContent = u; });
  w('vHome').textContent = s.home.toFixed(2);
  w('sSolar').textContent = s.solar ? 'Making power' : 'Waiting for sunrise';
  w('sBatt').textContent = bIn ? 'Charging' : bOut ? 'Powering the house' : 'Full, resting';
  w('sGrid').textContent = 'On, not in use';
  w('pGrid').textContent = s.off ? 'Grid off' : 'Grid on';
  w('sHome').textContent = s.solar >= s.home ? 'From solar' : 'From the battery';
  w('vBatt').textContent = s.soc + '%';
  w('bBatt').style.width = s.soc + '%';
  w('tSolar').classList.toggle('on', s.solar > 0);
  w('tBatt').classList.toggle('on', s.batt !== 0);
  w('tHome').classList.add('on');
  w('tGrid').classList.toggle('off', !!s.off);
  w('lGridB').classList.toggle('cut', !!s.off);
  lane('Solar', s.solar > 0, 0, s.solar);
  lane('Batt', s.batt !== 0, bIn, Math.abs(s.batt));
  lane('Grid', s.grid > 0, 0, s.grid);
  lane('Home', true, 0, s.home);
  grow('spSolar', [Math.min(s.solar, s.home), bIn]);
  grow('spHome', [Math.min(s.solar, s.home), bOut, s.grid]);
}
show(0);
autoplay(screen, 4200, () => show((cur + 1) % S.length));
})();

/* every plant in one place: the app's plant menu, switching between three example plants */
(() => {
const card = document.getElementById('pl-card');
if (!card) return;
const menu = document.getElementById('pl-menu'), pick = document.getElementById('pl-pick'), view = document.getElementById('pl-view');
const PL = [
  { name: 'Home', login: 'you@example.com', batt: 64, peak: 6.2 },
  { name: 'Holiday house', login: 'you@example.com', batt: 98, peak: 2.6 },
  { name: 'Mum and Dad', login: 'mum@example.com', batt: 81, peak: 4.4, note: 'Grid off since 12:10.' },
];
// kW at minute m of the day: a sun arc 06:00 to 18:40 with passing cloud
const kwAt = (p, m) => Math.max(0, Math.sin(Math.PI * (m - 360) / 760)) * p.peak * (.88 + .12 * Math.sin(m / 23));
PL.forEach(p => { p.now = kwAt(p, 785); let e = 0; for (let m = 360; m < 785; m += 5) e += (kwAt(p, m) + kwAt(p, m + 5)) / 2 * 5 / 60; p.made = e; });
menu.innerHTML = [...new Set(PL.map(p => p.login))].map(l => `<div role="group" aria-label="${l}"><div class="pl-login" aria-hidden="true">${l}</div>`
  + PL.map((p, i) => p.login !== l ? '' : `<button type="button" role="option"><span class="tick" aria-hidden="true"></span><b>${p.name}</b><span class="st"><i></i>Live</span></button>`).join('') + '</div>').join('');
const rows = [...menu.querySelectorAll('button')];
// solar so far today, 06:00 to now (13:05), against a whole day's width
const curve = p => { const pts = []; for (let m = 360; m <= 785; m += 5) pts.push([20 + (m - 360) / 760 * 480, 92 - kwAt(p, m) / 7 * 80]); return pts; };
let cur = 0, timers = [];
function render(n) {
  cur = n;
  const p = PL[n], c = curve(p), d = c.map(([x, y], i) => (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1)).join(' ');
  document.getElementById('pl-name').textContent = p.name;
  rows.forEach((r, i) => { r.setAttribute('aria-selected', i === n); r.firstChild.textContent = i === n ? '✓' : ''; });
  view.innerHTML = `<div class="pl-stats"><div>Solar now<b style="color:var(--solar)">${p.now.toFixed(2)}<small>kW</small></b></div><div>Battery<b style="color:var(--batt)">${p.batt}<small>%</small></b></div><div>Made today<b>${p.made.toFixed(1)}<small>kWh</small></b></div></div>`
    + `<p class="pl-note">${p.note || ''}</p>`
    + `<div class="pl-ch"><span>Solar today</span><span class="num">06:00 to now</span></div>`
    + `<svg class="pl-svg" viewBox="0 0 520 100" aria-hidden="true"><defs><linearGradient id="pl-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3ddc84" stop-opacity=".35"/><stop offset="1" stop-color="#3ddc84" stop-opacity="0"/></linearGradient></defs><line x1="20" x2="500" y1="92" y2="92" stroke="rgba(255,255,255,.1)"/><path d="${d} L${c[c.length - 1][0].toFixed(1)} 92 L20 92Z" fill="url(#pl-g)"/><path d="${d}" fill="none" stroke="#3ddc84" stroke-width="2.4"/></svg>`;
}
const open = on => { card.classList.toggle('open', on); pick.setAttribute('aria-expanded', on); if (!on) rows.forEach(r => r.classList.remove('hov')); };
function choose(n) {
  open(false);
  if (n === cur) return;
  view.classList.add('swap');
  setTimeout(() => { render(n); view.classList.remove('swap'); }, calm ? 0 : 180);
}
const stopPlay = autoplay(card, 4000, () => {
  const n = (cur + 1) % PL.length;
  open(true);
  timers = [setTimeout(() => rows[n].classList.add('hov'), 700), setTimeout(() => choose(n), 1400)];
});
const stop = () => { stopPlay(); timers.forEach(clearTimeout); };
pick.addEventListener('click', () => { stop(); open(!card.classList.contains('open')); });
rows.forEach((r, i) => r.addEventListener('click', () => { stop(); choose(i); }));
document.addEventListener('click', e => { if (!card.contains(e.target)) open(false); });
card.addEventListener('keydown', e => { if (e.key === 'Escape') { open(false); pick.focus(); } });
render(0);
})();
