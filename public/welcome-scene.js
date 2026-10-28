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
el('rect', { x: CUT0 / N * TW, y: 0, width: (CUT1 - CUT0) / N * TW, height: TH, fill: '#f87171', 'fill-opacity': .18 }, gTc);
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

/* stars */
const st = $('stars'); let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
for (let i = 0; i < 140; i++) { const s = document.createElement('i'); s.style.left = rnd() * 100 + '%'; s.style.top = rnd() * 62 + '%'; s.style.opacity = (.25 + rnd() * .75).toFixed(2); if (rnd() > .85) { s.style.width = s.style.height = '3px'; } st.appendChild(s); }

/* ---------- five moments: each one sets the sky and the card once ---------- */
const MO = [[0, 0], [9.0, 540], [12.333, 740], [18.333, 1100], [21.5, 1290]];
$('chMade').textContent = D.made[N - 1].toFixed(1) + ' kWh';
$('chEmpty').textContent = 'Empty in ' + hm((D.soc[1290] - RES) * CAP / -D.bat[1290]);
const day = $('day'), stage = $('stage'), top = $('top'), cardEl = $('card');
const card = { tGrid: $('tGrid') };
function placeSun(h) {
  const sunEl = $('sun'), W = stage.clientWidth, Hh = stage.clientHeight;
  const t = (h - 5.9) / (18.8 - 5.9), up = Math.min(1, Math.max(0, t));
  const sx = W * (.06 + .88 * up), sy = Hh - 110 - Math.pow(Math.sin(Math.PI * up), .55) * (Hh - 220);
  sunEl.style.transform = `translate(${sx}px,${sy}px)`;
  sunEl.style.opacity = t > -.02 && t < 1.02 ? 1 : 0;
  const warm = Math.sin(Math.PI * up);
  sunEl.style.setProperty('--sunc', rgb(mix([233, 110, 40], [255, 214, 120], warm)));
  sunEl.style.setProperty('--glow', `rgba(255,${Math.round(150 + warm * 70)},${Math.round(70 + warm * 50)},${(.45 + warm * .2).toFixed(2)})`);
  // the moon crosses the night sky on the same arc
  const moon = $('moon'), mt = ((h < 12 ? h + 24 : h) - 13.3) / 32.7;
  const mx = W * (.06 + .88 * mt), my = Hh - 110 - Math.pow(Math.sin(Math.PI * Math.min(1, Math.max(0, mt))), .55) * (Hh - 220);
  moon.style.transform = `translate(${mx}px,${my}px)`;
}
function inkNav() {
  const inDay = scrollY < day.offsetTop + day.offsetHeight - innerHeight;
  top.style.color = inDay ? top.dataset.ink || '' : '';
  top.classList.toggle('solid', !inDay);
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
function skyTo(h) {
  const s = skyAt(h), set = (n, v) => day.style.setProperty(n, v);
  set('--s1', s.c[0]); set('--s2', s.c[1]); set('--s3', s.c[2]); set('--l1', s.c[3]); set('--l2', s.c[4]);
  const dark = s.ink > .5;
  set('--ink', dark ? '#20160a' : '#f3eee4'); set('--ink-soft', dark ? 'rgba(32,22,10,.78)' : 'rgba(243,238,228,.8)'); set('--accent', dark ? '#7a3f00' : '#ffd27a');
  st.style.opacity = s.stars; $('moon').style.opacity = Math.min(1, s.stars * 1.4);
  const panelLit = Math.max(0, Math.sin(Math.PI * (h - 6.2) / 12.25));
  document.querySelectorAll('#panels path').forEach(e => e.setAttribute('fill', `rgba(${120 + panelLit * 130},${150 + panelLit * 90},${200 - panelLit * 40},${.35 + panelLit * .55})`));
  const lit = h < 6.6 || h > 17.6;
  document.querySelectorAll('.win').forEach(e => e.setAttribute('fill', lit ? '#ffd27a' : 'rgba(0,0,0,.35)'));
  placeSun(h);
  top.dataset.ink = dark ? '#20160a' : '#f3eee4'; inkNav();
}
const moments = [...document.querySelectorAll('.moment')];
function hourAtScroll() {
  const y = scrollY + innerHeight / 2, mid = e => e.getBoundingClientRect().top + scrollY + e.offsetHeight / 2;
  for (let i = 0; i < moments.length - 1; i++) {
    const a = mid(moments[i]), b = mid(moments[i + 1]);
    if (y <= b) { const t = Math.min(1, Math.max(0, (y - a) / (b - a))); return MO[i][0] + (MO[i + 1][0] - MO[i][0]) * (t * t * (3 - 2 * t)); }
  }
  // after the last moment the clock runs on to midnight as that moment leaves
  const lastM = moments[moments.length - 1], a = mid(lastM), b = a + lastM.offsetHeight / 2;
  const t = Math.min(1, Math.max(0, (y - a) / (b - a)));
  return MO[MO.length - 1][0] + (24 - MO[MO.length - 1][0]) * t;
}
let hNow = hourAtScroll(), last = 0, raf = 0;
function tick(ts) {
  const target = hourAtScroll(), dt = last ? ts - last : 16; last = ts;
  hNow = reduce ? target : hNow + (target - hNow) * (1 - Math.exp(-dt / 220));
  if (Math.abs(target - hNow) < .002) hNow = target;
  skyTo(hNow); cardAt(Math.min(N - 1, Math.round(hNow * 60)), hNow);
  raf = hNow === target ? 0 : requestAnimationFrame(tick);
  if (!raf) last = 0;
}
const kick = () => { if (!raf) raf = requestAnimationFrame(tick); };
skyTo(hNow); cardAt(Math.min(N - 1, Math.round(hNow * 60)), hNow);
/* each moment fades in while it holds the middle of the screen, and out as it leaves */
const cardOut = () => {
  moments.forEach(e => { const r = e.getBoundingClientRect(); e.classList.toggle('on', Math.abs(r.top + r.height / 2 - innerHeight / 2) < innerHeight * .3); });
  cardEl.classList.toggle('gone', moments[moments.length - 1].getBoundingClientRect().bottom < innerHeight * .4);
};
cardOut();
addEventListener('scroll', () => { inkNav(); kick(); cardOut(); }, { passive: true });
const fitCard = () => cardEl.style.setProperty('--k', Math.min(1, (innerWidth - 32) / cardEl.offsetWidth).toFixed(3));
fitCard();
addEventListener('resize', () => { placeSun(hNow); fitCard(); });

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
const C={solar:'#3ddc84',home:'#f87171',grid:'#facc15',cyan:'#22d3ee',batt:'#a78bfa',plain:'#e7ecf2'};
const d=(n,prev,good)=>({n,prev,good});
const delta=x=>!x?'':`<div class="ib-d"><b style="color:${x.good===undefined?'#9aa5b3':x.good?C.solar:C.home}">${x.n>0?'↑':'↓'} ${Math.abs(x.n)}%</b> vs ${x.prev}</div>`;
const card=c=>`<div class="ib-card"><div class="ib-l">${c.l}</div><div class="ib-v" style="color:${C[c.tone||'plain']}">${c.v}${c.u?`<small>${c.u}</small>`:''}</div>${c.sub?`<div class="ib-d">${c.sub}</div>`:''}${delta(c.delta)}</div>`;
// The example plant's mail, worded and laid out as the app's own emails (supabase/functions/_shared/email.ts)
const MAIL=[
 {k:'week',dot:C.solar,time:'26 Oct',at:'Mon 26 Oct, 07:00',subject:'Weekly solar report for Example plant: 19 – 25 Oct 2026',preview:'Made 341 kWh, est. saved R1 027',
  title:'19 – 25 Oct 2026',sub:'Example plant',
  stats:[{l:'Made',v:'341',u:'kWh',tone:'solar',delta:d(6,'last week',true)},{l:'Home',v:'367',u:'kWh',tone:'home',delta:d(-3,'last week',true)},{l:'Imported',v:'70.0',u:'kWh',tone:'grid',delta:d(-12,'last week',true)},{l:'Independence',v:'81%',tone:'cyan',delta:d(4,'last week',true)},{l:'Est. saved',v:'R1 027',tone:'batt',delta:d(5,'last week',true)}],
  bars:{title:'Solar each day',side:'Average 48.7 kWh a day',labels:['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],vals:[46.2,51.3,38.4,49.8,48.1,55.6,51.6]},
  facts:[{l:'Best day',v:'55.6',u:'kWh',tone:'solar',sub:'Sat 24 Oct'},{l:'Busiest day',v:'58.9',u:'kWh',tone:'home',sub:'Sun 25 Oct'}],
  btn:'Open Live',foot:"You get this every week. Don't want it? Turn it off in your notification settings."},
 {k:'panels',dot:C.home,time:'20 Oct',at:'Tue 20 Oct, 11:55',subject:'Some panels stopped producing at Example plant',preview:'PV3 on Inverter 1: no power since 11:42',
  title:'Some panels stopped producing at Example plant',stack:1,stats:[{l:'PV3 · 1',v:'No power',tone:'home',sub:'since 11:42 today'},{l:'Other panels',v:'OK',tone:'solar',sub:'producing as normal'}],
  note:'One group of panels on Inverter 1 has stopped making power. The rest are still working.',btn:'Open Equipment',foot:"Alert for Example plant. Don't want these? Turn them off in your notification settings."},
 {k:'hot',dot:C.batt,time:'12 Oct',at:'Mon 12 Oct, 14:21',subject:'Battery hot at Example plant',preview:'Battery 41 °C at 14:20',
  title:'Battery hot at Example plant',stack:1,stats:[{l:'Battery',v:'41&nbsp;°C',tone:'home',sub:'at 14:20 today'}],
  note:'Batteries wear faster when they run hot.',btn:'Open Equipment',foot:"Alert for Example plant. Don't want these? Turn them off in your notification settings."},
 {k:'back',dot:C.grid,time:'3 Oct',at:'Sat 3 Oct, 18:45',subject:'Grid back at Example plant',preview:'Grid on since 18:45 today, outage 45m',
  title:'Grid back at Example plant',stack:1,stats:[{l:'Grid',v:'On',tone:'grid',sub:'since 18:45 today'},{l:'Outage',v:'45m',sub:'without grid'}],btn:'Open Grid',foot:"Alert for Example plant. Don't want these? Turn them off in your notification settings."},
 {k:'down',dot:C.home,time:'3 Oct',at:'Sat 3 Oct, 18:00',subject:'Grid down at Example plant',preview:'Grid off since 18:00 today, battery 86%',
  title:'Grid down at Example plant',stack:1,stats:[{l:'Grid',v:'Off',tone:'home',sub:'since 18:00 today'},{l:'Battery',v:'86%',tone:'batt',sub:'running the house'}],btn:'Open Grid',foot:"Alert for Example plant. Don't want these? Turn them off in your notification settings."}
];
const rows=document.getElementById('ib-rows'),view=document.getElementById('ib-view');
function show(i){
 const m=MAIL[i];
 rows.querySelectorAll('.ib-row').forEach((r,j)=>{r.setAttribute('aria-selected',j===i);r.tabIndex=j===i?0:-1});
 let h=`<div class="ib-from"><span class="ib-orb"></span><span><b>Prince Solar Hub</b></span><span>${m.at}</span></div><div class="ib-subj">${m.subject}</div><div class="ib-title">${m.title}</div>${m.sub?`<div class="ib-sub">${m.sub}</div>`:''}`;
 h+=`<div class="ib-stats${m.stack?' ib-stack':''}">${m.stats.map(card).join('')}</div>`;
 if(m.note)h+=`<p class="ib-note">${m.note}</p>`;
 if(m.bars){const b=m.bars,mx=Math.max(...b.vals),bi=b.vals.indexOf(mx);
  h+=`<div class="ib-chart"><div class="ib-ch"><b>${b.title}</b><span>${b.side}</span></div><div class="ib-bars">${b.vals.map((v,j)=>`<div ${j===bi?`class="ib-best" data-v="${v} kWh"`:''} style="height:${v/mx*100}%"></div>`).join('')}</div><div class="ib-lbls">${b.labels.map((l,j)=>`<span${j===bi?' class="ib-best"':''}>${l}</span>`).join('')}</div>
  <div class="ib-facts">${m.facts.map(card).join('')}</div></div>`}
 h+=`<span class="ib-btn">${m.btn}</span><p class="ib-foot">${m.foot}</p>`;
 view.innerHTML=h;
}
MAIL.forEach((m,i)=>{const r=document.createElement('button');r.className='ib-row';r.setAttribute('role','tab');
 r.innerHTML=`<i style="background:${m.dot}"></i><span class="ib-s">${m.subject}</span><span class="ib-t">${m.time}</span><span class="ib-p">${m.preview}</span>`;
 r.onclick=()=>show(i);
 r.onkeydown=e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();const n=(i+(e.key==='ArrowDown'?1:-1)+MAIL.length)%MAIL.length;show(n);rows.children[n].focus()}};
 rows.append(r)});
show(0);
})();


})();
