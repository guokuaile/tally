// Samples the complete upstream renderer, including morphs and depth-sorted decoration.
// jeremy-prt/bloub, MIT; see LICENSE and README.md.
const { resolve } = require('node:path');
const { writeFileSync } = require('node:fs');
const compiled = resolve(process.argv[2]);
const { BotEngine } = require(resolve(compiled, 'engine.js'));
const { EXPRESSION_BY_ID } = require(resolve(compiled, 'expressions.js'));
const SESSION_FPS = 30, CREW_FPS = 20, R = 100, TAU = Math.PI * 2;
const numbers = s => (s.match(/-?\d+(?:\.\d+)?/g) ?? []).map(Number);
function path(d, lift = 0) {
  const ops = { M: 0, L: 1, C: 2, Z: 3 };
  if (/[^MLCZ0-9.,\s\-]/.test(d)) throw Error(`Unsupported path: ${d}`);
  return [...d.matchAll(/([MLCZ])([^MLCZ]*)/g)].flatMap(([, op, values]) =>
    [ops[op], ...numbers(values).map((n, i) => n + (i % 2 ? lift : 0))]);
}
// A dot without an explicit colour or depth fog is a piece of the body ("!" dot, thinking side dots):
// the native renderer paints it with the body's material instead of a flat colour.
const dot = (d, lift = 0) => ({ ...d, y: d.y + lift, path: d.d ? path(d.d) : null, d: undefined,
  ...(!d.color && d.depth == null ? { piece: true } : {}) });

// ---- session clips (AI page and pills), unchanged parameters ----
const cycles = {
  working: [['play', 2], ['orbit', 3.4], ['idle', 1]],
  permission: [['notify', 2], ['wide', 2]],
  input: [['egg', 2], ['hexagon', 2]],
  compacting: [['burst', 2.6], ['thinking', 1.2]],
  happy: [['wink', 1.6], ['idle', 1.6]],
  stale: [['idle', 1]]
};
function sample(mood, cycle) {
  const fps = SESSION_FPS;
  const engine = new BotEngine(100, cycle[0][0], null, mood === 'stale' ? EXPRESSION_BY_ID.get('triste') : null);
  const frames = [];
  const frameCount = cycle.reduce((n, [, duration]) => n + Math.round(duration * fps), 0);
  const waiting = mood === 'permission' || mood === 'input';
  const notification = mood === 'permission' ? new BotEngine(100, 'notify').sample(1).notif : null;
  let index = 0;
  // A warm-up cycle preserves the upstream transition across the loop boundary.
  for (let pass = 0; pass < 2; pass++) {
    for (const [state, duration] of cycle) {
      engine.setState(state, index / fps);
      for (let j = 0; j < Math.round(duration * fps); j++, index++) {
        if (!pass) continue;
        const f = engine.sample(index / fps);
        const wave = (1 - Math.cos(frames.length / frameCount * 2 * Math.PI)) / 2;
        const lift = waiting ? -18 * wave : 0;
        const badge = notification ? { ...notification, x: -notification.x, y: notification.y + lift - 8 * wave, r: 14 + 3 * wave } : f.notif;
        frames.push({
          body: path(f.bodyPath, lift), bodyAlpha: f.bodyAlpha,
          eyes: f.eyes.map(e => {
            const n = numbers(e.d);
            const matrix = numbers(e.matrix);
            matrix[5] += lift;
            return { width: -2*n[0], height: 2*(n[2]-n[1]), matrix, alpha: e.alpha };
          }),
          dots: f.dots.map(d => dot(d, lift)),
          dotsBehind: f.dotsBehind,
          arcs: f.arcs.map(a => ({ front: path(a.front), back: path(a.back), width: a.width, opacity: a.opacity, grad: a.grad })),
          notif: badge, notch: notification ? { ...badge, r: badge.r + 5.4 } : f.notch,
          ...(waiting ? { symbol: mood === 'permission' ? '!' : '?', symbolY: lift } : {})
        });
      }
    }
  }
  return { fps, frames };
}

// ---- crew clips (小刻 beside the notch): 20 fps, every transform baked into the coordinates ----
const eye = (w, h, tilt = 0, open = 1) => ({ w, h, tilt, open });
// 小刻's own face is a level gaze with round eyes; upstream expressions are rescaled to those proportions.
const XK = { id: 'neutre', gaze: { yaw: 0, pitch: 6, roll: 0 }, split: 19, eyes: [eye(.3, .36), eye(.3, .36)] };
const face = id => { const e = EXPRESSION_BY_ID.get(id);
  return { id: e.id, gaze: { ...e.gaze }, split: e.split, eyes: e.eyes.map(c => eye(.3*Math.sqrt(c.w/.186), .36*Math.sqrt(c.h/.412), c.tilt, c.open)) }; };
const ease = x => x < .5 ? 2*x*x : 1 - Math.pow(-2*x + 2, 2)/2;
function kf(p, pts) {
  if (p <= pts[0][0]) return pts[0][1];
  for (let i = 1; i < pts.length; i++) if (p <= pts[i][0]) {
    const [p0, v0] = pts[i-1], [p1, v1] = pts[i];
    return v0 + (v1 - v0) * (p1 === p0 ? 1 : ease((p - p0)/(p1 - p0)));
  }
  return pts[pts.length-1][1];
}
const breathe = p => .25 + .45*Math.max(0, Math.sin(p*TAU - .4));
// `looks` are gaze changes replayed at the given clip time (null = back to the free gaze); `lids` may be a function of clip time.
const crew = {
  'crew-run':        { blocks: [['idle', 3], ['swirl', 1.3]], face: XK,
    looks: [[.7, { yaw: 18, pitch: -3, mix: 1, spin: 0, wander: .2 }], [2.1, null]] },
  'crew-permission': { blocks: [['alert', 2.4], ['wide', 1.6]], face: XK, glow: t => breathe(t/4) },
  'crew-input':      { blocks: [['idle', 4]], face: face('curieux'), symbol: '?', glow: t => breathe(t/4),
    motion: t => ({ rot: kf(t/4, [[0, 0], [.12, 0], [.28, 9], [.68, 9], [.84, 0], [1, 0]]), dy: -6 }) },
  'crew-compacting': { blocks: [['burst', 2.6], ['thinking', 1.2]], face: XK },
  'crew-done':       { blocks: [['comet', 2.4], ['idle', 3.6]], face: XK, arcEyesFrom: 2.4,
    ring: t => t < 2.4 ? 0 : kf((t - 2.4)/3.6, [[0, 0], [.08, 1], [.45, 1], [.75, 0]]) },
  'crew-stale':      { blocks: [['idle', 5]], face: face('triste'), lookDown: true,
    lids: t => kf(t/5, [[0, .5], [.55, .5], [.61, 1], [.67, 1], [.76, .5], [1, .5]]),
    motion: t => ({ rot: kf(t/5, [[0, -5], [.5, -7.5], [1, -5]]), sq: [1.03, .95] }) }
};
// Rotation about the ball's bottom (0, R), squash, then vertical lift: the order the approved preview composed them.
function transform({ rot = 0, dy = 0, sq = [1, 1] } = {}) {
  const c = Math.cos(rot*Math.PI/180), s = Math.sin(rot*Math.PI/180);
  return [c*sq[0], s*sq[0], -s*sq[1], c*sq[1], s*sq[1]*R, R + dy - c*sq[1]*R];
}
const apply = (T, x, y) => [T[0]*x + T[2]*y + T[4], T[1]*x + T[3]*y + T[5]];
const compose = (T, M) => [T[0]*M[0] + T[2]*M[1], T[1]*M[0] + T[3]*M[1], T[0]*M[2] + T[2]*M[3], T[1]*M[2] + T[3]*M[3],
  T[0]*M[4] + T[2]*M[5] + T[4], T[1]*M[4] + T[3]*M[5] + T[5]];
function mapPath(values, T, scale = 1) {
  const out = [];
  for (let i = 0; i < values.length;) {
    const op = values[i++];
    out.push(op);
    for (let k = 0, n = op === 2 ? 3 : op === 3 ? 0 : 1; k < n; k++, i += 2) out.push(...apply(T, values[i]*scale, values[i+1]*scale));
  }
  return out;
}
const circle = (c, T) => c && (([x, y]) => ({ x, y, r: c.r }))(apply(T, c.x, c.y));
// One decimal is 0.01 pt at the 22 pt crew size and keeps the file under the 4.8 MB budget; the session clips keep three.
const round1 = v => Array.isArray(v) ? v.map(round1) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, round1(x)]))
  : typeof v === 'number' ? Math.round(v*10)/10 : v;
function sampleCrew(spec) {
  const fps = CREW_FPS;
  const total = spec.blocks.reduce((n, [, duration]) => n + duration, 0);
  const engine = new BotEngine(R, spec.blocks[0][0], null, spec.face);
  if (spec.lookDown) engine.setLook({ yaw: 4, pitch: -16, mix: 1, spin: 0, wander: .3 }, -10, .24);
  // Every clip loops: warm up one pass so the loop boundary keeps the upstream transition.
  const passes = 2;
  const frames = [];
  const looks = (spec.looks ?? []).flatMap(([at, look]) => Array.from({ length: passes }, (_, pass) => [pass * total + at, look])).sort((a, b) => a[0] - b[0]);
  let nextLook = 0;
  for (let pass = 0; pass < passes; pass++) {
    let clock = pass * total, offset = 0;
    for (const [state, duration] of spec.blocks) {
      engine.setState(state, clock);
      for (let j = 0, n = Math.round(duration * fps); j < n; j++) {
        // `local` is summed from the block offset, not `t - total`: the subtraction lands 0.1 µs short of 2.4 and the
        // `arcEyesFrom` / `ring` envelopes would miss the first ball frame
        const t = clock + j / fps, local = offset + j / fps;
        while (nextLook < looks.length && looks[nextLook][0] <= t) { engine.setLook(looks[nextLook][1], looks[nextLook][0]); nextLook++; }
        if (pass < passes - 1) continue;
        const f = engine.sample(t);
        const motion = spec.motion ? spec.motion(local) : {};
        const T = transform(motion);
        const scale = spec.arcScale ?? 1;
        frames.push({ ...round1({
          body: mapPath(path(f.bodyPath), T), bodyAlpha: f.bodyAlpha,
          eyes: f.eyes.map(e => {
            const n = numbers(e.d), width = Math.round(-20*n[0])/10;
            // 小刻 keeps round eyes: upstream capsules taller than 1.3 × width are capped (floored so rounding cannot push the ratio over)
            return { width, height: Math.floor(Math.min(2*(n[2]-n[1]), 1.3*width)*10)/10, matrix: compose(T, numbers(e.matrix)), alpha: e.alpha };
          }),
          dots: f.dots.map(d => { const [x, y] = apply(T, d.x, d.y);
            return { ...dot(d), x, y, rot: d.rot == null ? undefined : d.rot + (motion.rot ?? 0) }; }),
          dotsBehind: f.dotsBehind,
          arcs: f.arcs.map(a => { const [x1, y1] = apply(T, a.grad.x1*scale, a.grad.y1*scale), [x2, y2] = apply(T, a.grad.x2*scale, a.grad.y2*scale);
            return { front: mapPath(path(a.front), T, scale), back: mapPath(path(a.back), T, scale), width: a.width*scale, opacity: a.opacity, grad: { ...a.grad, x1, y1, x2, y2 } }; }),
          notif: circle(f.notif, T), notch: circle(f.notch, T) }),
          // scalar envelopes keep three decimals: a 0.1 step in glow alpha would be a visible stutter
          ...(spec.symbol ? { symbol: spec.symbol } : {}),
          ...(spec.glow ? { glow: spec.glow(local) } : {}),
          ...(spec.ring ? { ring: spec.ring(local) } : {}),
          ...(spec.lids ? { lids: typeof spec.lids === 'function' ? spec.lids(local) : spec.lids } : {}),
          ...(spec.arcEyes || (spec.arcEyesFrom != null && local >= spec.arcEyesFrom) ? { arcEyes: true } : {})
        });
      }
      clock += duration;
      offset += duration;
    }
  }
  return { fps, frames };
}

const clips = {
  ...Object.fromEntries(Object.entries(cycles).map(([mood, cycle]) => [mood, sample(mood, cycle)])),
  ...Object.fromEntries(Object.entries(crew).map(([name, spec]) => [name, sampleCrew(spec)]))
};
writeFileSync(resolve(__dirname, 'frames.json'), JSON.stringify({ clips }, (_, v) => typeof v === 'number' ? Math.round(v*1000)/1000 : v));
