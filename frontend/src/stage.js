// The 3D board: a Three.js scene in its own persistent element beside the
// default shell's `#screen` (references/rich-ui.md, "Persistent DOM
// alongside the default shell"). It never talks to the backend: app.js
// hands it what to show (`show(scene)`) and it reports a chosen column
// through `hooks.onDrop`, which app.js submits through the one client.
//
// A scene is one of
//   { mode: "attract" }                                  lobby: a slow demo
//   { mode: "play", cells, lastMove, winLine, mySeat, yourTurn }
//   { mode: "final", cells, lastMove, winLine, mySeat, outcome }
// with `cells`/`lastMove`/`winLine` as decodeGame() returns them.
//
// Whatever is on screen is synced to the latest scene one animation at a
// time: new discs fall in, a board that is no longer a continuation (a
// rematch, a new table) is released through the bottom first.

import * as THREE from "three";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { COLS, ROWS, landingRow, linesThrough, seatToMove, winSegments } from "./connect-four-plugin.js";

const PITCH = 1;
const HOLE_R = 0.41;
const DISC_R = 0.435;
const DISC_T = 0.24;
const GAP = 0.3; // the slot between the two faces the discs fall through
const FACE_T = 0.12;
const BEVEL = 0.035;
const MARGIN_X = 0.32;
const BOARD_W = COLS * PITCH + 2 * MARGIN_X;
const BOARD_TOP = (ROWS / 2) * PITCH + 0.26;
const BOARD_BOTTOM = -(ROWS / 2) * PITCH - 0.5;
const FRONT_Z = GAP / 2 + FACE_T + 2 * BEVEL;
const GROUND_Y = BOARD_BOTTOM - 0.85;
const DROP_Y = BOARD_TOP + 0.85;
const GRAVITY = 24;
const SLIDER_TRAVEL = 1.35;

// What the camera keeps in frame.
const EXT_W_HALF = BOARD_W / 2 + 0.45;
const EXT_TOP = DROP_Y + 0.55;
const EXT_BOTTOM = GROUND_Y - 0.1;
const LOOK = new THREE.Vector3(0, (EXT_TOP + EXT_BOTTOM) / 2, 0);

const COLOR = { p1: 0xdf4249, p2: 0xf3bf3a, board: 0x2556c4 };

const colX = (c) => (c - (COLS - 1) / 2) * PITCH;
const rowY = (r) => (r - (ROWS - 1) / 2) * PITCH;
const clamp01 = (k) => Math.min(1, Math.max(0, k));
const easeInOut = (k) => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);
const easeOutBack = (k) => 1 + 2.2 * Math.pow(k - 1, 3) + 1.2 * Math.pow(k - 1, 2);
const damp = (from, to, rate, dt) => to + (from - to) * Math.exp(-rate * dt);
const EMPTY = () => new Array(COLS * ROWS).fill(null);

function roundedRect(shape, x, y, w, h, r) {
  shape.moveTo(x + r, y);
  shape.lineTo(x + w - r, y);
  shape.quadraticCurveTo(x + w, y, x + w, y + r);
  shape.lineTo(x + w, y + h - r);
  shape.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  shape.lineTo(x + r, y + h);
  shape.quadraticCurveTo(x, y + h, x, y + h - r);
  shape.lineTo(x, y + r);
  shape.quadraticCurveTo(x, y, x + r, y);
}

function faceGeometry() {
  const shape = new THREE.Shape();
  roundedRect(shape, -BOARD_W / 2, BOARD_BOTTOM, BOARD_W, BOARD_TOP - BOARD_BOTTOM, 0.3);
  for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      const hole = new THREE.Path();
      hole.absarc(colX(c), rowY(r), HOLE_R, 0, Math.PI * 2, true);
      shape.holes.push(hole);
    }
  }
  return new THREE.ExtrudeGeometry(shape, {
    depth: FACE_T,
    bevelEnabled: true,
    bevelThickness: BEVEL,
    bevelSize: BEVEL,
    bevelSegments: 3,
    curveSegments: 28,
  });
}

// A classic disc: rounded rim, a raised ring and a shallow dish on each
// face. Turned on a lathe around Y, then stood up to face +Z.
function discGeometry() {
  const R = DISC_R;
  const h = DISC_T / 2;
  const top = [
    [0, h - 0.035],
    [0.19, h - 0.035],
    [0.215, h - 0.004],
    [0.245, h - 0.004],
    [0.27, h - 0.03],
    [0.34, h - 0.026],
    [R - 0.04, h],
    [R - 0.01, h - 0.014],
    [R, h - 0.05],
  ];
  // Bottom centre -> rim -> top centre: LatheGeometry's normal is
  // (dy, -dx) along the profile, so this order points them outwards.
  const bottom = top.map(([x, y]) => [x, -y]);
  const pts = [...bottom, ...top.slice().reverse()].map(([x, y]) => new THREE.Vector2(x, y));
  const g = new THREE.LatheGeometry(pts, 56);
  g.rotateX(Math.PI / 2);
  return g;
}

function radialTexture(stops, size = 128) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const ctx = c.getContext("2d");
  const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [at, color] of stops) g.addColorStop(at, color);
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, size, size);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

// Brightest at the top, fading down the column and out at both sides.
function columnGlowTexture() {
  const c = document.createElement("canvas");
  c.width = 64;
  c.height = 128;
  const ctx = c.getContext("2d");
  const down = ctx.createLinearGradient(0, 0, 0, 128);
  down.addColorStop(0, "rgba(255,255,255,0.9)");
  down.addColorStop(0.35, "rgba(255,255,255,0.35)");
  down.addColorStop(1, "rgba(255,255,255,0)");
  ctx.fillStyle = down;
  ctx.fillRect(0, 0, 64, 128);
  const across = ctx.createLinearGradient(0, 0, 64, 0);
  across.addColorStop(0, "rgba(0,0,0,0)");
  across.addColorStop(0.3, "rgba(0,0,0,1)");
  across.addColorStop(0.7, "rgba(0,0,0,1)");
  across.addColorStop(1, "rgba(0,0,0,0)");
  ctx.globalCompositeOperation = "destination-in";
  ctx.fillStyle = across;
  ctx.fillRect(0, 0, 64, 128);
  return new THREE.CanvasTexture(c);
}

export function createStage(container, hooks = {}) {
  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: "high-performance" });
  } catch (err) {
    console.warn("WebGL unavailable", err);
    document.body.classList.add("no-webgl"); // style.css shows the 2D board instead
    return { show() {}, preview() {}, nudge() {}, dropSelected() {}, relayout() {} };
  }
  const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.setClearColor(0x000000, 0);
  container.appendChild(renderer.domElement);
  const canvas = renderer.domElement;

  const scene3 = new THREE.Scene();
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene3.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  scene3.environmentIntensity = 0.5;

  const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 200);

  // ── lights ────────────────────────────────────────────────────────────
  scene3.add(new THREE.HemisphereLight(0xc9d5ff, 0x3b2516, 0.6));
  const key = new THREE.DirectionalLight(0xffe1c2, 2.3);
  key.position.set(-5, 9, 8);
  key.castShadow = true;
  const small = Math.min(window.screen?.width ?? 1024, window.screen?.height ?? 1024) < 700;
  key.shadow.mapSize.setScalar(small ? 1024 : 2048);
  Object.assign(key.shadow.camera, { left: -8, right: 8, top: 8, bottom: -8, near: 1, far: 30 });
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.02;
  scene3.add(key);
  const rim = new THREE.DirectionalLight(0x8eaeff, 1.3);
  rim.position.set(6, 5, -7);
  scene3.add(rim);
  const lamp = new THREE.PointLight(0xffa864, 26, 32, 2);
  lamp.position.set(-7, 1.5, 5);
  scene3.add(lamp);

  // ── table: a shadow catcher and a warm pool of light ─────────────────
  const shadow = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), new THREE.ShadowMaterial({ opacity: 0.34 }));
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.y = GROUND_Y;
  shadow.receiveShadow = true;
  scene3.add(shadow);
  const pool = new THREE.Mesh(
    new THREE.PlaneGeometry(22, 14),
    new THREE.MeshBasicMaterial({
      map: radialTexture([
        [0, "rgba(255,196,140,0.22)"],
        [0.55, "rgba(255,170,110,0.07)"],
        [1, "rgba(255,170,110,0)"],
      ]),
      transparent: true,
      depthWrite: false,
    }),
  );
  pool.rotation.x = -Math.PI / 2;
  pool.position.y = GROUND_Y + 0.002;
  scene3.add(pool);

  // ── the board ─────────────────────────────────────────────────────────
  const board = new THREE.Group();
  scene3.add(board);
  const boardMat = new THREE.MeshPhysicalMaterial({
    color: COLOR.board,
    roughness: 0.36,
    clearcoat: 0.6,
    clearcoatRoughness: 0.28,
  });
  const faceGeo = faceGeometry();
  const front = new THREE.Mesh(faceGeo, boardMat);
  front.position.z = GAP / 2 + BEVEL;
  const back = new THREE.Mesh(faceGeo, boardMat);
  back.position.z = -GAP / 2 - FACE_T - BEVEL;
  for (const m of [front, back]) {
    m.castShadow = true;
    m.receiveShadow = true;
    board.add(m);
  }
  const railGeo = new THREE.BoxGeometry(0.24, BOARD_TOP - BOARD_BOTTOM - 0.08, GAP);
  for (const side of [-1, 1]) {
    const rail = new THREE.Mesh(railGeo, boardMat);
    rail.position.set(side * (BOARD_W / 2 - 0.14), (BOARD_TOP + BOARD_BOTTOM) / 2, 0);
    board.add(rail);
  }
  const slider = new THREE.Mesh(new RoundedBoxGeometry(BOARD_W - 0.5, 0.26, GAP - 0.02, 3, 0.05), boardMat);
  slider.position.set(0, BOARD_BOTTOM + 0.22, 0);
  slider.castShadow = true;
  board.add(slider);
  const legGeo = new RoundedBoxGeometry(0.3, BOARD_BOTTOM + 1.55 - (GROUND_Y + 0.14), 0.82, 4, 0.1);
  const footGeo = new RoundedBoxGeometry(0.38, 0.16, 2.5, 4, 0.07);
  for (const side of [-1, 1]) {
    const leg = new THREE.Mesh(legGeo, boardMat);
    leg.position.set(side * (BOARD_W / 2 + 0.15), (BOARD_BOTTOM + 1.55 + GROUND_Y + 0.14) / 2, 0);
    const foot = new THREE.Mesh(footGeo, boardMat);
    foot.position.set(side * (BOARD_W / 2 + 0.15), GROUND_Y + 0.08, 0);
    for (const m of [leg, foot]) {
      m.castShadow = true;
      m.receiveShadow = true;
      board.add(m);
    }
  }

  // ── discs ─────────────────────────────────────────────────────────────
  const discGeo = discGeometry();
  const discMat = {};
  const glowMat = {};
  const ghostMat = {};
  for (const seat of ["p1", "p2"]) {
    discMat[seat] = new THREE.MeshPhysicalMaterial({
      color: COLOR[seat],
      roughness: 0.3,
      clearcoat: 1,
      clearcoatRoughness: 0.16,
    });
    glowMat[seat] = discMat[seat].clone();
    glowMat[seat].emissive = new THREE.Color(COLOR[seat]);
    glowMat[seat].emissiveIntensity = 0.3;
    ghostMat[seat] = discMat[seat].clone();
    Object.assign(ghostMat[seat], { transparent: true, opacity: 0.45, depthWrite: false });
  }
  const discs = new THREE.Group();
  board.add(discs);

  function makeDisc(seat) {
    const m = new THREE.Mesh(discGeo, discMat[seat]);
    m.castShadow = true;
    m.receiveShadow = true;
    return m;
  }

  // The ghost: your disc hovering over the column you would drop into.
  const ghost = new THREE.Mesh(discGeo, ghostMat.p1);
  ghost.visible = false;
  board.add(ghost);
  let ghostOpacity = 0;

  // A soft light down the hovered column.
  const columnGlow = new THREE.Mesh(
    new THREE.PlaneGeometry(1.1, BOARD_TOP - BOARD_BOTTOM - 0.25),
    new THREE.MeshBasicMaterial({
      map: columnGlowTexture(),
      color: 0xfff1d6,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
  );
  columnGlow.position.set(0, (BOARD_TOP + BOARD_BOTTOM) / 2, FRONT_Z + 0.004);
  board.add(columnGlow);

  // The most recent drop: a ring of light around its hole.
  const ring = new THREE.Mesh(
    new THREE.TorusGeometry(HOLE_R + 0.025, 0.022, 12, 64),
    new THREE.MeshBasicMaterial({ color: 0xfff6e6, transparent: true, opacity: 0, depthWrite: false }),
  );
  ring.visible = false;
  board.add(ring);
  let ringAge = 0;

  // The winning line(s): bars of light across the discs.
  const winBars = new THREE.Group();
  board.add(winBars);
  const barMat = new THREE.MeshBasicMaterial({
    color: 0xffe2a6,
    transparent: true,
    opacity: 0,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });
  const haloMat = barMat.clone();
  let winAge = 0;

  // ── atmosphere: drifting bokeh, and sparkles for a win ───────────────
  const dot = radialTexture([
    [0, "rgba(255,255,255,1)"],
    [0.4, "rgba(255,255,255,0.45)"],
    [1, "rgba(255,255,255,0)"],
  ]);
  const bokeh = [];
  const bokehLayer = (count, size, color, opacity, zMin, zMax) => {
    const pos = new Float32Array(count * 3);
    const seed = [];
    for (let i = 0; i < count; i++) {
      pos[i * 3] = (Math.random() - 0.5) * 30;
      pos[i * 3 + 1] = GROUND_Y + Math.random() * 15;
      pos[i * 3 + 2] = zMin + Math.random() * (zMax - zMin);
      seed.push({ speed: 0.08 + Math.random() * 0.18, phase: Math.random() * 10 });
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    const pts = new THREE.Points(
      geo,
      new THREE.PointsMaterial({
        size,
        map: dot,
        color,
        transparent: true,
        opacity,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      }),
    );
    scene3.add(pts);
    bokeh.push({ pts, seed });
  };
  bokehLayer(70, 0.32, 0xffc995, 0.35, -14, -3);
  bokehLayer(40, 0.55, 0x9db9ff, 0.22, -16, -4);
  bokehLayer(10, 1.4, 0xffd7a8, 0.07, 2, 6);

  const SPARKS = 140;
  const sparkPos = new Float32Array(SPARKS * 3);
  const sparkCol = new Float32Array(SPARKS * 3);
  const sparkGeo = new THREE.BufferGeometry();
  sparkGeo.setAttribute("position", new THREE.BufferAttribute(sparkPos, 3));
  sparkGeo.setAttribute("color", new THREE.BufferAttribute(sparkCol, 3));
  const sparks = new THREE.Points(
    sparkGeo,
    new THREE.PointsMaterial({
      size: 0.16,
      map: dot,
      vertexColors: true,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    }),
  );
  sparks.frustumCulled = false;
  board.add(sparks);
  const sparkState = [];

  function burst(cellsAt) {
    sparkState.length = 0;
    for (let i = 0; i < SPARKS; i++) {
      const at = cellsAt[i % cellsAt.length];
      const a = Math.random() * Math.PI * 2;
      const s = 0.6 + Math.random() * 1.6;
      sparkState.push({
        x: colX(at % COLS),
        y: rowY(Math.floor(at / COLS)),
        z: FRONT_Z + 0.1,
        vx: Math.cos(a) * s,
        vy: Math.sin(a) * s + 1.2,
        vz: Math.random() * 0.8,
        life: 1.6 + Math.random() * 1.6,
        age: 0,
        warm: Math.random(),
      });
    }
  }

  // ── animation primitives ─────────────────────────────────────────────
  const tasks = new Set();
  const run = (step) =>
    new Promise((resolve) => {
      tasks.add((dt) => {
        if (!step(dt)) return false;
        resolve();
        return true;
      });
    });
  const tween = (seconds, fn, ease = (k) => k) => {
    let t = 0;
    return run((dt) => {
      t += dt;
      const k = clamp01(t / seconds);
      fn(ease(k));
      return k >= 1;
    });
  };
  const wait = (seconds) => tween(seconds, () => {});

  // ── what is on the board ─────────────────────────────────────────────
  const shown = EMPTY(); // { seat, mesh } per cell
  let current = null; // the latest scene
  let syncing = false;
  let decoKey = "";
  let celebratedKey = "";

  const shownCells = () => shown.map((s) => (s ? s.seat : null));

  function fallFrom(mesh, row, { soft = false } = {}) {
    const yTarget = rowY(row);
    let y = mesh.position.y;
    let v = 0;
    let impacts = 0;
    return run((dt) => {
      v -= GRAVITY * dt;
      y += v * dt;
      if (y <= yTarget) {
        y = yTarget;
        const speed = -v;
        hooks.onImpact?.(soft ? 0.3 : Math.min(1, speed / 11) * (impacts === 0 ? 1 : 0.45));
        v = soft || reducedMotion ? 0 : speed * 0.22;
        impacts++;
        if (v < 0.6 || impacts >= 3) {
          mesh.position.y = yTarget;
          return true;
        }
      }
      mesh.position.y = y;
      return false;
    });
  }

  async function dropDisc(i, seat, { soft = false, delay = 0 } = {}) {
    const col = i % COLS;
    const row = Math.floor(i / COLS);
    const mesh = makeDisc(seat);
    shown[i] = { seat, mesh };
    if (delay) await wait(delay);
    mesh.position.set(colX(col), DROP_Y, 0);
    discs.add(mesh);
    if (!soft) {
      mesh.scale.setScalar(0.001);
      await tween(0.18, (k) => mesh.scale.setScalar(Math.max(0.001, k)), easeOutBack);
    }
    await fallFrom(mesh, row, { soft });
  }

  function fade(mesh) {
    mesh.material = mesh.material.clone();
    mesh.material.transparent = true;
    return mesh.material;
  }

  function discard(mesh) {
    discs.remove(mesh);
    if (mesh.material !== discMat.p1 && mesh.material !== discMat.p2) mesh.material.dispose();
  }

  // A disc the latest scene no longer has on top of a column (a move the
  // rules refused after it was drawn): lifted out.
  async function liftOut(i) {
    const { mesh } = shown[i];
    shown[i] = null;
    const mat = fade(mesh);
    const y0 = mesh.position.y;
    await tween(0.4, (k) => {
      mesh.position.y = y0 + k * 1.2;
      mat.opacity = 1 - k;
    });
    discard(mesh);
  }

  // The classic end of a game: the slider at the bottom pulls out and
  // every disc falls through.
  async function releaseAll() {
    const all = shown.filter(Boolean);
    shown.fill(null);
    clearDecorations();
    if (all.length === 0) return;
    hooks.onRelease?.();
    const x0 = slider.position.x;
    await tween(0.5, (k) => (slider.position.x = x0 + k * SLIDER_TRAVEL), easeInOut);
    await Promise.all(
      all.map(async ({ mesh }) => {
        await wait(Math.random() * 0.2);
        const mat = fade(mesh);
        const spin = (Math.random() - 0.5) * 4;
        let v = 0;
        const fadeFrom = BOARD_BOTTOM;
        const gone = GROUND_Y + 0.3;
        await run((dt) => {
          v -= GRAVITY * 0.75 * dt;
          mesh.position.y += v * dt;
          mesh.rotation.z += spin * dt;
          mat.opacity = clamp01((mesh.position.y - gone) / (fadeFrom - gone));
          return mesh.position.y <= gone;
        });
        discard(mesh);
      }),
    );
    await tween(0.45, (k) => (slider.position.x = x0 + (1 - k) * SLIDER_TRAVEL), easeInOut);
  }

  function clearBars() {
    for (const bar of winBars.children) bar.geometry.dispose();
    winBars.clear();
  }

  function clearDecorations() {
    decoKey = "";
    ring.visible = false;
    for (const s of shown) if (s) s.mesh.material = discMat[s.seat];
    clearBars();
  }

  function decorate(want) {
    const lm = want.lastMove;
    if (lm && current.mode !== "attract") {
      const moved = !ring.visible || ring.userData.at !== lm.row * COLS + lm.col;
      ring.position.set(colX(lm.col), rowY(lm.row), FRONT_Z + 0.012);
      ring.userData.at = lm.row * COLS + lm.col;
      if (moved) ringAge = 0;
      ring.visible = true;
    } else ring.visible = false;

    const key = want.winLine.join(",");
    if (key === decoKey) return;
    decoKey = key;
    for (const s of shown) if (s) s.mesh.material = discMat[s.seat];
    clearBars();
    if (want.winLine.length === 0) return;
    winAge = 0;
    for (const i of want.winLine) if (shown[i]) shown[i].mesh.material = glowMat[shown[i].seat];
    for (const line of winSegments(want.cells, want.winLine)) {
      const a = line[0];
      const b = line[line.length - 1];
      const from = new THREE.Vector3(colX(a % COLS), rowY(Math.floor(a / COLS)), FRONT_Z + 0.07);
      const to = new THREE.Vector3(colX(b % COLS), rowY(Math.floor(b / COLS)), FRONT_Z + 0.07);
      const len = from.distanceTo(to) + 0.35;
      const mid = from.clone().add(to).multiplyScalar(0.5);
      const angle = Math.atan2(to.y - from.y, to.x - from.x);
      for (const [radius, mat] of [
        [0.06, barMat],
        [0.2, haloMat],
      ]) {
        const bar = new THREE.Mesh(new THREE.CapsuleGeometry(radius, len, 6, 16), mat);
        bar.rotation.z = angle - Math.PI / 2;
        bar.position.copy(mid);
        bar.scale.y = 0.001;
        winBars.add(bar);
      }
    }
  }

  // ── the lobby's demo game ────────────────────────────────────────────
  const demo = { cells: EMPTY(), winLine: [], nextAt: 0, limit: 18, holding: false };
  let clock = 0;

  function resetDemo(delay) {
    demo.cells = EMPTY();
    demo.winLine = [];
    demo.holding = false;
    demo.limit = 14 + Math.floor(Math.random() * 12);
    demo.nextAt = clock + delay;
  }

  function demoTick() {
    if (current?.mode !== "attract" || syncing || clock < demo.nextAt) return;
    if (demo.holding) {
      resetDemo(2.2);
    } else {
      const seat = seatToMove(demo.cells);
      const open = [];
      for (let c = 0; c < COLS; c++) {
        if (landingRow(demo.cells, c) === null) continue;
        const w = 4 - Math.abs(c - 3); // centre-heavy, like real play
        for (let k = 0; k < w; k++) open.push(c);
      }
      const col = open[Math.floor(Math.random() * open.length)];
      const row = landingRow(demo.cells, col);
      demo.cells = demo.cells.slice();
      demo.cells[row * COLS + col] = seat;
      const lines = linesThrough(demo.cells, row, col, seat);
      if (lines.length > 0) {
        demo.winLine = [...new Set(lines.flat())].sort((a, b) => a - b);
        demo.holding = true;
        demo.nextAt = clock + 4;
      } else if (demo.cells.filter(Boolean).length >= demo.limit) {
        demo.holding = true;
        demo.nextAt = clock + 3;
      } else demo.nextAt = clock + 1.4 + Math.random() * 0.8;
    }
    sync();
  }

  // ── syncing the board to the latest scene ────────────────────────────
  const wanted = () =>
    current.mode === "attract"
      ? { cells: demo.cells, lastMove: null, winLine: demo.winLine }
      : { cells: current.cells, lastMove: current.lastMove, winLine: current.winLine };

  // What the board has finished drawing, for automated tests: 42 cells,
  // bottom row first, R / Y / "."; `data-settled` is "false" mid-animation.
  function publish(settled) {
    container.dataset.settled = String(settled);
    if (settled) container.dataset.board = shownCells().map((c) => (c === "p1" ? "R" : c === "p2" ? "Y" : ".")).join("");
  }

  async function sync() {
    if (syncing || current === null) return;
    syncing = true;
    publish(false);
    try {
      for (;;) {
        const want = wanted();
        const have = shownCells();
        const gone = [];
        const added = [];
        for (let i = 0; i < have.length; i++) {
          if (have[i] !== null && want.cells[i] !== have[i]) gone.push(i);
          else if (have[i] === null && want.cells[i] !== null) added.push(i);
        }
        if (gone.length > 0) {
          const i = gone[0];
          const onTop = i + COLS >= have.length || have[i + COLS] === null;
          if (gone.length === 1 && want.cells[i] === null && onTop && added.length === 0) await liftOut(i);
          else await releaseAll();
          continue;
        }
        if (added.length === 0) {
          decorate(want);
          celebrate(want);
          publish(true);
          return;
        }
        clearDecorations();
        // Lower rows first; the most recent drop last.
        const last = want.lastMove ? want.lastMove.row * COLS + want.lastMove.col : -1;
        added.sort((a, b) => (a === last) - (b === last) || a - b);
        if (added.length <= 2) {
          for (const i of added) await dropDisc(i, want.cells[i]);
        } else {
          // Joining a game under way: the position cascades in.
          await Promise.all(added.map((i, k) => dropDisc(i, want.cells[i], { soft: true, delay: k * 0.09 })));
        }
      }
    } finally {
      syncing = false;
    }
  }

  function celebrate(want) {
    if (current.mode !== "final" || current.outcome !== "win" || want.winLine.length === 0) return;
    const key = want.winLine.join(",") + want.cells.join("");
    if (key === celebratedKey) return;
    celebratedKey = key;
    burst(want.winLine);
  }

  // ── input ─────────────────────────────────────────────────────────────
  let hoverCol = null;
  let armed = false; // touch: the first tap aims, the second drops
  const pointer = { x: 0, y: 0, sx: 0, sy: 0 };
  const ray = new THREE.Raycaster();
  const ndc = new THREE.Vector2();
  const boardPlane = new THREE.Plane(new THREE.Vector3(0, 0, 1), 0);
  const hit = new THREE.Vector3();

  const playable = () => current?.mode === "play" && current.yourTurn;
  const canDrop = (col) => playable() && col !== null && landingRow(current.cells, col) !== null;

  function colAt(ev) {
    const rect = canvas.getBoundingClientRect();
    ndc.set(((ev.clientX - rect.left) / rect.width) * 2 - 1, -((ev.clientY - rect.top) / rect.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    if (!ray.ray.intersectPlane(boardPlane, hit)) return null;
    if (hit.y < BOARD_BOTTOM - 0.3 || hit.y > DROP_Y + 1.2) return null;
    if (Math.abs(hit.x) > BOARD_W / 2 + 0.2) return null;
    return Math.min(COLS - 1, Math.max(0, Math.floor(hit.x / PITCH + COLS / 2)));
  }

  function aim(col) {
    if (col === hoverCol) return;
    hoverCol = col;
    armed = false;
    if (col !== null && playable()) hooks.onHover?.(col);
  }

  function drop(col) {
    if (!canDrop(col)) return;
    armed = false;
    hooks.onDrop?.(col);
  }

  canvas.addEventListener("pointermove", (ev) => {
    if (ev.pointerType === "mouse") {
      aim(colAt(ev));
      canvas.style.cursor = canDrop(hoverCol) ? "pointer" : "";
    }
  });
  canvas.addEventListener("pointerleave", (ev) => {
    if (ev.pointerType === "mouse") aim(null);
  });
  let downAt = null;
  canvas.addEventListener("pointerdown", (ev) => {
    downAt = { x: ev.clientX, y: ev.clientY };
  });
  canvas.addEventListener("pointerup", (ev) => {
    if (!downAt || Math.hypot(ev.clientX - downAt.x, ev.clientY - downAt.y) > 12) return;
    downAt = null;
    const col = colAt(ev);
    if (col === null) return;
    if (ev.pointerType === "mouse") return drop(col);
    if (hoverCol === col && armed) return drop(col);
    aim(col);
    armed = true;
  });
  window.addEventListener("pointermove", (ev) => {
    if (ev.pointerType !== "mouse") return;
    pointer.x = (ev.clientX / window.innerWidth) * 2 - 1;
    pointer.y = (ev.clientY / window.innerHeight) * 2 - 1;
  });

  // ── framing: the board fits the free part of the viewport ────────────
  const frame = { dist: 30, dx: 0, dy: 0 };
  const frameTarget = { dist: 30, dx: 0, dy: 0 };
  let width = 1;
  let height = 1;
  let framedOnce = false;

  function relayout() {
    width = Math.max(1, container.clientWidth);
    height = Math.max(1, container.clientHeight);
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    const safe = hooks.safeArea?.(width, height) ?? { left: 0, top: 0, right: width, bottom: height };
    const sw = Math.max(140, safe.right - safe.left);
    const sh = Math.max(140, safe.bottom - safe.top);
    const tanHalf = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
    const extH = (EXT_TOP - EXT_BOTTOM) / 2;
    const byHeight = (extH / tanHalf) * (height / sh);
    const byWidth = (EXT_W_HALF / (tanHalf * camera.aspect)) * (width / sw);
    frameTarget.dist = Math.min(80, Math.max(byHeight, byWidth) * 1.04 + 1.2);
    frameTarget.dx = (safe.left + safe.right) / 2 - width / 2;
    frameTarget.dy = (safe.top + safe.bottom) / 2 - height / 2;
    if (!framedOnce) {
      Object.assign(frame, frameTarget);
      framedOnce = true;
    }
  }
  new ResizeObserver(relayout).observe(container);
  relayout();

  // ── the loop ──────────────────────────────────────────────────────────
  let last = performance.now();
  let attractBlend = 1;

  function loop(now) {
    requestAnimationFrame(loop);
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    clock += dt;

    for (const task of [...tasks]) if (task(dt)) tasks.delete(task);
    demoTick();

    // Camera: a slow drift, wider in the lobby; a hint of parallax.
    for (const k of ["dist", "dx", "dy"]) frame[k] = damp(frame[k], frameTarget[k], 3, dt);
    attractBlend = damp(attractBlend, current?.mode === "attract" ? 1 : 0, 1.2, dt);
    pointer.sx = damp(pointer.sx, pointer.x, 2, dt);
    pointer.sy = damp(pointer.sy, pointer.y, 2, dt);
    const motion = reducedMotion ? 0 : 1;
    const az =
      motion *
      (attractBlend * Math.sin(clock * 0.07) * 0.42 +
        (1 - attractBlend) * Math.sin(clock * 0.11) * 0.035 +
        pointer.sx * 0.05);
    const el = 0.1 + attractBlend * 0.07 + motion * (Math.sin(clock * 0.08) * 0.015 - pointer.sy * 0.025);
    camera.position.set(
      LOOK.x + Math.sin(az) * Math.cos(el) * frame.dist,
      LOOK.y + Math.sin(el) * frame.dist,
      LOOK.z + Math.cos(az) * Math.cos(el) * frame.dist,
    );
    camera.lookAt(LOOK);
    camera.setViewOffset(width, height, -frame.dx, -frame.dy, width, height);
    camera.updateProjectionMatrix();

    // Ghost disc and column light.
    const showGhost = playable() && hoverCol !== null;
    if (showGhost) {
      const seat = current.mySeat;
      if (ghost.material !== ghostMat[seat]) ghost.material = ghostMat[seat];
      if (!ghost.visible) ghost.position.x = colX(hoverCol);
      ghost.visible = true;
    }
    const full = hoverCol !== null && current && current.mode === "play" && landingRow(current.cells, hoverCol) === null;
    ghostOpacity = damp(ghostOpacity, showGhost ? (full ? 0.12 : 0.5) : 0, 12, dt);
    if (ghost.visible) {
      ghost.material.opacity = ghostOpacity;
      if (hoverCol !== null) ghost.position.x = damp(ghost.position.x, colX(hoverCol), 16, dt);
      ghost.position.y = DROP_Y + Math.sin(clock * 2.2) * 0.05 * motion;
      if (ghostOpacity < 0.01 && !showGhost) ghost.visible = false;
    }
    columnGlow.material.opacity = damp(columnGlow.material.opacity, showGhost && !full ? 0.11 : 0, 10, dt);
    if (hoverCol !== null) columnGlow.position.x = ghost.visible ? ghost.position.x : colX(hoverCol);

    // Last-move ring and the win line, breathing.
    if (ring.visible) {
      ringAge += dt;
      ring.material.opacity = Math.min(1, ringAge * 2.5) * (0.55 + 0.3 * Math.sin(clock * 2.4));
    }
    if (winBars.children.length > 0) {
      winAge += dt;
      const grow = easeInOut(clamp01(winAge / 0.7));
      for (const bar of winBars.children) bar.scale.y = Math.max(0.001, grow);
      const pulse = 0.5 + 0.5 * Math.sin(clock * 2.2);
      barMat.opacity = grow * (0.55 + 0.25 * pulse);
      haloMat.opacity = grow * (0.16 + 0.1 * pulse);
      for (const seat of ["p1", "p2"]) glowMat[seat].emissiveIntensity = 0.12 + 0.3 * pulse;
    }

    // Atmosphere.
    for (const { pts, seed } of bokeh) {
      const p = pts.geometry.attributes.position;
      for (let i = 0; i < seed.length; i++) {
        let y = p.getY(i) + seed[i].speed * dt * motion;
        if (y > GROUND_Y + 15) y = GROUND_Y - 0.5;
        p.setY(i, y);
        p.setX(i, p.getX(i) + Math.sin(clock * 0.2 + seed[i].phase) * 0.003 * motion);
      }
      p.needsUpdate = true;
    }
    if (sparkState.length > 0) {
      let alive = 0;
      for (let i = 0; i < SPARKS; i++) {
        const s = sparkState[i];
        s.age += dt;
        const k = clamp01(1 - s.age / s.life);
        if (k > 0) alive++;
        s.vy -= 0.9 * dt;
        s.x += s.vx * dt;
        s.y += s.vy * dt;
        s.z += s.vz * dt;
        s.vx *= 0.985;
        sparkPos.set([s.x, s.y, s.z], i * 3);
        const b = k * k;
        sparkCol.set([b, b * (0.78 + 0.2 * s.warm), b * (0.45 + 0.4 * (1 - s.warm))], i * 3);
      }
      sparkGeo.attributes.position.needsUpdate = true;
      sparkGeo.attributes.color.needsUpdate = true;
      if (alive === 0) sparkState.length = 0;
    }
    sparks.visible = sparkState.length > 0;

    renderer.render(scene3, camera);
  }
  requestAnimationFrame(loop);

  return {
    show(scene) {
      const wasAttract = current?.mode === "attract";
      if (scene.mode === "attract" && !wasAttract) resetDemo(current === null ? 0.8 : 2.5);
      if (scene.mode !== "play" || !scene.yourTurn) armed = false;
      current = scene;
      canvas.style.cursor = canDrop(hoverCol) ? "pointer" : "";
      sync();
    },
    /// Aims the ghost at `col` (a hovered column button, the keyboard).
    preview(col) {
      aim(col);
    },
    /// The first press shows the ghost over the middle column.
    nudge(delta) {
      if (!playable()) return;
      aim(hoverCol === null ? 3 : Math.min(COLS - 1, Math.max(0, hoverCol + delta)));
    },
    dropSelected() {
      drop(hoverCol);
    },
    relayout,
  };
}
