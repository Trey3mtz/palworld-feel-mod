#!/usr/bin/env python3
"""
Emit a single self-contained HTML previewer with the baked clips inlined.

The PNG contact sheets show pose; this shows TIMING, which is most of what a
0.47s clip lives or dies on. Orbit with the mouse, scrub the frame slider,
compare the sprint and walk versions at matched playback speed.
"""

import json
import os

import render

TEMPLATE = """<title>SkidTurn preview - TheCameraIsAPal</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#12141a; color:#c8cede;
         font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
  header { padding:14px 18px 10px; border-bottom:1px solid #23262f; }
  h1 { margin:0 0 2px; font-size:15px; font-weight:600; color:#e8ecf5; letter-spacing:.02em; }
  .sub { color:#6f778a; font-size:12px; }
  main { display:flex; flex-wrap:wrap; gap:18px; padding:16px 18px 28px; }
  #stage { background:#0d0f14; border:1px solid #23262f; border-radius:6px; touch-action:none; }
  .panel { min-width:250px; flex:1; }
  .row { display:flex; align-items:center; gap:8px; margin-bottom:10px; flex-wrap:wrap; }
  button, select { background:#1b1e27; color:#c8cede; border:1px solid #2e323e;
                   border-radius:4px; padding:5px 11px; font:inherit; cursor:pointer; }
  button:hover, select:hover { border-color:#454b5c; }
  button.on { background:#2b3346; border-color:#4d5a78; }
  input[type=range] { flex:1; min-width:150px; accent-color:#ff7a3c; }
  table { border-collapse:collapse; font-size:12px; margin-top:6px; }
  td { padding:2px 12px 2px 0; color:#8b93a7; }
  td.v { color:#e8ecf5; }
  .beat { color:#ffd166; }
  .legend span { display:inline-block; margin-right:12px; }
  .sw { display:inline-block; width:9px; height:9px; border-radius:2px; margin-right:5px;
        vertical-align:baseline; }
</style>
<header>
  <h1>Skid turn &mdash; quick-turn clips for horizontalmove.lua</h1>
  <div class="sub">Baked from Animation/SkidTurn/poses.py &middot; drag to orbit &middot;
    the character starts facing screen-right, turning to its own left</div>
</header>
<main>
  <canvas id="stage" width="620" height="470"></canvas>
  <div class="panel">
    <div class="row">
      <select id="clip"></select>
      <button id="play">pause</button>
      <button id="ghost" class="on">onion</button>
    </div>
    <div class="row"><span>frame</span><input id="scrub" type="range" min="0" value="0"></div>
    <div class="row"><span>speed</span><input id="speed" type="range" min="5" max="100" value="35">
      <span id="speedv" class="v">0.35x</span></div>
    <div class="row">
      <button data-view="side">side</button>
      <button data-view="front">front</button>
      <button data-view="top">top</button>
      <button data-view="iso" class="on">3/4</button>
    </div>
    <table>
      <tr><td>frame</td><td class="v" id="mFrame"></td></tr>
      <tr><td>time</td><td class="v" id="mTime"></td></tr>
      <tr><td>beat</td><td class="beat" id="mBeat"></td></tr>
      <tr><td>hip height</td><td class="v" id="mHip"></td></tr>
      <tr><td>plant foot ahead of hips</td><td class="v" id="mReach"></td></tr>
      <tr><td>shoulders vs hips</td><td class="v" id="mSep"></td></tr>
    </table>
    <p class="legend">
      <span><i class="sw" style="background:#3a96ff"></i>right leg (plant)</span>
      <span><i class="sw" style="background:#ff7a3c"></i>left leg</span>
      <span><i class="sw" style="background:#96d6ff"></i>right arm</span>
      <span><i class="sw" style="background:#ffce82"></i>left arm</span>
    </p>
  </div>
</main>
<script>
const CLIPS = __DATA__;
const COLOURS = __COLOURS__;

const cv = document.getElementById('stage'), ctx = cv.getContext('2d');
const el = id => document.getElementById(id);
let clip = CLIPS[0], frame = 0, playing = true, ghost = true;
let yaw = 0.62, pitch = 0.22, speed = 0.35, last = 0, acc = 0;

const VIEWS = { side:[0,0.1], front:[Math.PI/2,0.1], top:[0,1.35], iso:[0.62,0.22] };

CLIPS.forEach((c,i) => {
  const o = document.createElement('option');
  o.value = i; o.textContent = c.name;
  el('clip').appendChild(o);
});

function project(p, w, h) {
  // rig space: +X left, +Y forward, +Z up.  screen: right = -X rotated by yaw
  const cy = Math.cos(yaw), sy = Math.sin(yaw);
  const x = p[1]*cy - p[0]*sy;          // in-plane horizontal
  const d = p[1]*sy + p[0]*cy;          // depth, folded in by pitch
  const cp = Math.cos(pitch), sp = Math.sin(pitch);
  return [w*0.5 + x*SCALE, h - GROUND - (p[2]*cp - d*sp)*SCALE];
}
let SCALE = 1.9, GROUND = 60;

function draw() {
  const w = cv.width, h = cv.height;
  ctx.clearRect(0,0,w,h);
  ctx.fillStyle = '#0d0f14'; ctx.fillRect(0,0,w,h);

  // ground grid, drawn in rig space so it orbits with the figure
  ctx.strokeStyle = '#1e2230'; ctx.lineWidth = 1;
  for (let i=-3; i<=3; i++) {
    let a = project([i*30, -110, 0], w, h), b = project([i*30, 110, 0], w, h);
    ctx.beginPath(); ctx.moveTo(a[0],a[1]); ctx.lineTo(b[0],b[1]); ctx.stroke();
    a = project([-100, i*35, 0], w, h); b = project([100, i*35, 0], w, h);
    ctx.beginPath(); ctx.moveTo(a[0],a[1]); ctx.lineTo(b[0],b[1]); ctx.stroke();
  }

  const drawPose = (pts, alpha, width) => {
    ctx.lineCap = 'round';
    for (let i=0; i<clip.parents.length; i++) {
      const p = clip.parents[i];
      if (p < 0) continue;
      const a = project(pts[p], w, h), b = project(pts[i], w, h);
      ctx.strokeStyle = COLOURS[clip.bones[i]] || '#e2e6f0';
      ctx.globalAlpha = alpha; ctx.lineWidth = width;
      ctx.beginPath(); ctx.moveTo(a[0],a[1]); ctx.lineTo(b[0],b[1]); ctx.stroke();
    }
    const head = project(pts[clip.bones.indexOf('head')], w, h);
    ctx.globalAlpha = alpha; ctx.fillStyle = '#e8ecf5';
    ctx.beginPath(); ctx.arc(head[0], head[1], 7, 0, 7); ctx.fill();
    ctx.globalAlpha = 1;
  };

  if (ghost) for (let k=3; k>0; k--) {
    const f = frame - k*2;
    if (f >= 0) drawPose(clip.frames[f], 0.10 + 0.05*(3-k), 2);
  }
  drawPose(clip.frames[frame], 1, 4.5);
  readout();
}

function idx(n) { return clip.bones.indexOf(n); }
function readout() {
  const p = clip.frames[frame];
  const pelvis = p[idx('pelvis')], fr = p[idx('foot_r')];
  const cl = p[idx('clavicle_l')], cr = p[idx('clavicle_r')];
  const tl = p[idx('thigh_l')], tr = p[idx('thigh_r')];
  const yawOf = (l,r) => Math.atan2(-(l[1]-r[1]), l[0]-r[0]) * 180/Math.PI;
  el('mFrame').textContent = frame + ' / ' + (clip.frames.length-1);
  el('mTime').textContent = (frame/clip.fps).toFixed(3) + ' s';
  const label = clip.labels[frame];
  el('mBeat').textContent = label.includes(' ') ? label.split(' ')[1] : '\\u2014';
  el('mHip').textContent = pelvis[2].toFixed(1) + ' cm';
  el('mReach').textContent = (fr[1]-pelvis[1]).toFixed(1) + ' cm';
  el('mSep').textContent = (yawOf(cl,cr) - yawOf(tl,tr)).toFixed(0) + '\\u00b0';
  el('scrub').value = frame;
}

function tick(now) {
  if (playing) {
    acc += (now - last) / 1000 * speed * clip.fps;
    while (acc >= 1) { frame = (frame + 1) % clip.frames.length; acc -= 1; }
  }
  last = now;
  draw();
  requestAnimationFrame(tick);
}

el('clip').onchange = e => { clip = CLIPS[e.target.value]; frame = 0;
                             el('scrub').max = clip.frames.length-1; draw(); };
el('play').onclick = e => { playing = !playing; e.target.textContent = playing ? 'pause':'play'; };
el('ghost').onclick = e => { ghost = !ghost; e.target.classList.toggle('on', ghost); };
el('scrub').oninput = e => { frame = +e.target.value; playing = false;
                             el('play').textContent = 'play'; draw(); };
el('speed').oninput = e => { speed = e.target.value/100;
                             el('speedv').textContent = speed.toFixed(2)+'x'; };
document.querySelectorAll('[data-view]').forEach(b => b.onclick = () => {
  [yaw, pitch] = VIEWS[b.dataset.view];
  document.querySelectorAll('[data-view]').forEach(o => o.classList.remove('on'));
  b.classList.add('on'); draw();
});

let drag = null;
cv.addEventListener('pointerdown', e => { drag = [e.clientX, e.clientY, yaw, pitch];
                                          cv.setPointerCapture(e.pointerId); });
cv.addEventListener('pointerup', () => drag = null);
cv.addEventListener('pointermove', e => {
  if (!drag) return;
  yaw = drag[2] + (e.clientX - drag[0]) * 0.01;
  pitch = Math.max(-0.2, Math.min(1.45, drag[3] + (e.clientY - drag[1]) * 0.006));
  draw();
});

el('scrub').max = clip.frames.length-1;
requestAnimationFrame(t => { last = t; tick(t); });
</script>
"""


def _colours(rig):
    out = {}
    for name in rig.names:
        c = render.bone_colour(name)
        out[name] = "#%02x%02x%02x" % c
    return out


def write(path, rig, clip_datas):
    html = (TEMPLATE
            .replace("__DATA__", json.dumps(clip_datas, separators=(",", ":")))
            .replace("__COLOURS__", json.dumps(_colours(rig), separators=(",", ":"))))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(html)
    return path
