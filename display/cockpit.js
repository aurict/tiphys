// Drive scene: cam strip on the map card, the 2×2 cockpit tiles and the header title. Numbers ease toward the
// 20 Hz samples every frame; the DOM is written only when a shown value changes.
import { icon } from './icons.js';
import { fmtInt, fmtMoney, fmtDistance, fmtGameTime, fmtGear, fmtDuration } from './format.js';

const $ = (s) => document.querySelector(s);
const KMH = 3.6;
// Contract: nav.time is in real seconds. ETS2's default time compression (1 real s ≈ 19 game s on roads) turns it into
// a game-clock ETA. If the source ever sends game seconds, set this to 1.
const GAME_TIME_SCALE = 19;

export function createCockpit() {
  const el = {
    mapCard: $('#map-card'), empty: $('#map-empty'), emptyT: $('#map-empty-t'), emptyS: $('#map-empty-s'),
    dest: $('#cam-dest'), dist: $('#cam-dist'), distU: $('#cam-dist-u'), eta: $('#cam-eta'), income: $('#cam-income'), cargo: $('#map-cargo'),
    speedTile: $('#t-speed'), speedV: $('#speed-v'), speedArc: $('#t-speed .arc'), limit: $('#speed-limit'), limitV: $('#speed-limit span'),
    gearV: $('#gear-v'), rpmV: $('#rpm-v'), gearOf: $('#gear-of'), rpmArc: $('#t-gear .arc.outer'), gearArc: $('#t-gear .arc.inner'),
    fuelTile: $('#t-fuel'), fuelRange: $('#fuel-range'), fuelFill: $('#fuel-fill'), fuelL: $('#fuel-l'), fuelPct: $('#fuel-pct'),
    chips: $('#chips'),
  };
  for (const n of document.querySelectorAll('[data-icon]')) if (!n.innerHTML) n.innerHTML = icon(n.dataset.icon, n.classList.contains('empty-ic') ? 36 : 20);

  let truck = null;
  let clock24 = true;
  const shown = new Map();
  const set = (node, key, value, fn) => { if (shown.get(key) !== value) { shown.set(key, value); fn(node, value); } };
  const text = (node, v) => { node.textContent = v; };
  // Round caps draw a dot at 0: hide an empty arc.
  const arc = (node, v) => { node.style.strokeDasharray = `${v} 100`; node.style.opacity = v > 0 ? '1' : '0'; };
  const disp = { speed: 0, rpm: 0, range: 0, fuel: 0 };

  // Status rows: built once, updated in place.
  const rows = {};
  for (const [key, ic, label] of [['cruise', 'cruise', 'Hız sabitleyici'], ['park', 'parking', 'Park freni'], ['lights', 'beam', 'Farlar'],
    ['wear', 'wrench', 'Hasar'], ['rest', 'rest', 'Mola']]) {
    const r = document.createElement('div');
    r.className = 'srow';
    r.innerHTML = `${icon(ic, 20)}<span class="sl">${label}</span><span class="sv">–</span>`;
    el.chips.append(r);
    rows[key] = { r, v: r.querySelector('.sv'), ic: r.querySelector('.ic') };
  }
  const row = (key, value, cls) => {
    set(rows[key].v, key + 'v', value, text);
    set(rows[key].r, key + 'c', cls, (n, c) => { n.className = 'srow' + (c ? ' ' + c : ''); });
  };

  function setTruck(tr) {
    truck = tr;
    const live = tr && tr.state !== 'none' && tr.x != null;
    el.empty.hidden = live;
    el.mapCard.classList.toggle('no-truck', !live);
    document.querySelector('.cockpit').classList.toggle('off', !live || tr.state !== 'driving');
    if (!tr || tr.state === 'none') {
      el.emptyT.textContent = 'Euro Truck Simulator 2 çalışmıyor';
      el.emptyS.textContent = "Oyunu başlatınca konum ve kokpit burada görünür. Oyun açıkken de boş kalıyorsa SCS telemetri eklentisini Tiphys › Oyun Modu › Kurulum'dan kur.";
    } else if (tr.state === 'menu') {
      el.empty.hidden = false;
      el.emptyT.textContent = 'Oyun menüde';
      el.emptyS.textContent = 'Yola çıkınca harita ve kokpit canlanır.';
    }
    const job = live ? tr.job : null;
    el.mapCard.classList.toggle('no-job', !job);
    if (job) {
      set(el.dest, 'dest', job.to ?? '–', text);
      set(el.income, 'income', fmtMoney(job.income, job.currency), text);
      set(el.cargo, 'cargo', [job.cargo, job.from && job.to ? `${job.from} → ${job.to}` : null].filter(Boolean).join(' · '), text);
    }
    if (live && tr.nav) {
      const d = fmtDistance(tr.nav.distance);
      set(el.dist, 'dist', d.value, text);
      set(el.distU, 'distU', d.unit, text);
      const eta = tr.gameTime != null && tr.nav.time != null ? tr.gameTime + (tr.nav.time * GAME_TIME_SCALE) / 60 : null;
      set(el.eta, 'eta', fmtGameTime(eta, clock24), text);
    } else if (live) {
      set(el.dist, 'dist', '–', text); set(el.eta, 'eta', job?.deadlineGameTime != null ? fmtGameTime(job.deadlineGameTime, clock24) : '–', text);
    }
    if (!live) return;

    // Limit sign + over-limit state (2 km/h tolerance).
    const limit = tr.speedLimit ? Math.round(tr.speedLimit * KMH) : 0;
    set(el.limit, 'limitOn', limit > 0, (n, v) => { n.hidden = !v; });
    if (limit) set(el.limitV, 'limit', String(limit), text);
    set(el.speedTile, 'over', limit > 0 && Math.abs(tr.speed) * KMH > limit + 2, (n, v) => n.classList.toggle('over', v));
    set(el.gearOf, 'gearOf', tr.gears ? `${fmtGear(tr.gear)} / ${tr.gears}` : fmtGear(tr.gear), text);
    set(el.gearV, 'gear', fmtGear(tr.gear), text);

    const cap = tr.fuelCap || 1;
    const fr = Math.max(0, Math.min(1, tr.fuel / cap));
    set(el.fuelL, 'fuelL', `${fmtInt(tr.fuel)} / ${fmtInt(cap)} l`, text);
    set(el.fuelPct, 'fuelPct', `%${fmtInt(fr * 100)}`, text);
    set(el.fuelTile, 'fuelCls', fr < 0.08 ? 'crit' : fr < 0.15 ? 'low' : '', (n, c) => { n.classList.toggle('low', c === 'low'); n.classList.toggle('crit', c === 'crit'); });

    row('cruise', tr.cruise > 0 ? `${fmtInt(tr.cruise * KMH)} km/sa` : 'Kapalı', tr.cruise > 0 ? 'on' : '');
    row('park', tr.parkingBrake ? 'Çekili' : 'Serbest', tr.parkingBrake ? 'warn' : '');
    row('lights', tr.highBeam ? 'Uzun' : tr.lowBeam ? 'Kısa' : 'Kapalı', tr.highBeam || tr.lowBeam ? 'on' : '');
    const wear = Math.round((tr.wear ?? 0) * 100);
    const cargo = tr.cargoDamage != null ? ` · yük %${Math.round(tr.cargoDamage * 100)}` : '';
    row('wear', `%${wear}${cargo}`, wear >= 30 ? 'bad' : wear >= 10 ? 'warn' : '');
    if (tr.restMinutes == null) row('rest', '–', '');
    else row('rest', tr.restMinutes <= 0 ? 'Şimdi' : fmtDuration(tr.restMinutes), tr.restMinutes <= 0 ? 'bad' : tr.restMinutes < 60 ? 'warn' : '');
  }

  function frame(dt) {
    if (!truck || truck.state === 'none' || truck.x == null) return;
    const a = 1 - Math.exp(-dt / 110);
    disp.speed += (Math.abs(truck.speed) * KMH - disp.speed) * a;
    disp.rpm += ((truck.rpm ?? 0) - disp.rpm) * a;
    disp.range += ((truck.fuelRange ?? 0) - disp.range) * (1 - Math.exp(-dt / 400));
    disp.fuel += ((truck.fuelCap ? truck.fuel / truck.fuelCap : 0) - disp.fuel) * (1 - Math.exp(-dt / 400));
    const kmh = Math.round(disp.speed);
    set(el.speedV, 'speed', String(kmh), text);
    const limit = truck.speedLimit ? truck.speedLimit * KMH : 0;
    // Ring: speed against the limit (full at the limit); without a limit, against 130 km/h.
    const k = Math.min(1, disp.speed / (limit || 130));
    set(el.speedArc, 'speedArc', Math.round(k * 200) / 2, arc);
    set(el.rpmV, 'rpm', fmtInt(Math.round(disp.rpm / 10) * 10), text);
    const rk = truck.rpmMax ? Math.min(1, disp.rpm / truck.rpmMax) : 0;
    set(el.rpmArc, 'rpmArc', Math.round(rk * 200) / 2, arc);
    const gk = truck.gears ? Math.max(0, truck.gear) / truck.gears : 0;
    set(el.gearArc, 'gearArc', Math.round(gk * 200) / 2, arc);
    set(el.fuelRange, 'range', fmtInt(Math.round(disp.range)), text);
    set(el.fuelFill, 'fuelK', Math.round(disp.fuel * 500) / 500, (n, v) => { n.style.transform = `scaleX(${v})`; });
  }

  return {
    setTruck, frame,
    setClock24(v) { clock24 = v; shown.delete('eta'); if (truck) setTruck(truck); },
    /** Header title for Drive. */
    title() {
      const job = truck && truck.state !== 'none' ? truck.job : null;
      if (job?.from && job?.to) return { from: job.from, to: job.to };
      return null;
    },
  };
}
