// Samples the complete upstream renderer, including morphs and depth-sorted decoration.
// jeremy-prt/bloub, MIT; see LICENSE and README.md.
const { resolve } = require('node:path');
const { writeFileSync } = require('node:fs');
const compiled = resolve(process.argv[2]);
const { BotEngine } = require(resolve(compiled, 'engine.js'));
const { EXPRESSION_BY_ID } = require(resolve(compiled, 'expressions.js'));
const fps = 30;
const numbers = s => (s.match(/-?\d+(?:\.\d+)?/g) ?? []).map(Number);
function path(d) {
  const ops = { M: 0, L: 1, C: 2, Z: 3 };
  if (/[^MLCZ0-9.,\s\-]/.test(d)) throw Error(`Unsupported path: ${d}`);
  return [...d.matchAll(/([MLCZ])([^MLCZ]*)/g)].flatMap(([, op, values]) => [ops[op], ...numbers(values)]);
}
const cycles = {
  working: [['play', 2], ['orbit', 3.4], ['idle', 1]],
  permission: [['alert', 2.4], ['idle', 1.2]],
  input: [['notify', 2.2], ['wide', 1.8], ['idle', .8]],
  compacting: [['burst', 2.6], ['thinking', 1.2]],
  happy: [['wink', 1.6], ['idle', 1.6]],
  stale: [['idle', 1]]
};
function sample(mood, cycle) {
  const engine = new BotEngine(100, cycle[0][0], null, mood === 'stale' ? EXPRESSION_BY_ID.get('triste') : null);
  const frames = [];
  let index = 0;
  // A warm-up cycle preserves the upstream transition across the loop boundary.
  for (let pass = 0; pass < 2; pass++) {
    for (const [state, duration] of cycle) {
      engine.setState(state, index / fps);
      for (let j = 0; j < Math.round(duration * fps); j++, index++) {
        if (!pass) continue;
        const f = engine.sample(index / fps);
        frames.push({
          body: path(f.bodyPath), bodyAlpha: f.bodyAlpha,
          eyes: f.eyes.map(e => {
            const n = numbers(e.d);
            return { width: -2*n[0], height: 2*(n[2]-n[1]), matrix: numbers(e.matrix), alpha: e.alpha };
          }),
          dots: f.dots.map(d => ({ ...d, path: d.d ? path(d.d) : null, d: undefined })),
          dotsBehind: f.dotsBehind,
          arcs: f.arcs.map(a => ({ front: path(a.front), back: path(a.back), width: a.width, opacity: a.opacity, grad: a.grad })),
          notif: f.notif, notch: f.notch
        });
      }
    }
  }
  return frames;
}
const clips = Object.fromEntries(Object.entries(cycles).map(([mood, cycle]) => [mood, sample(mood, cycle)]));
writeFileSync(resolve(__dirname, 'frames.json'), JSON.stringify({ fps, clips }, (_, v) => typeof v === 'number' ? Math.round(v*1000)/1000 : v));
