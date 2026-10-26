// Bootstrap for Connect Four: build the actor and transport, hand off to
// duel-game-core's generic wiring for the panel (lobby, turn bar, claim
// clock, debrief), drive the 3D board beside it from the same client, and
// wire the bot dialog.
// Bundled by esbuild (../build.js) into dist/app.js, so every import
// resolves from node_modules at build time.

import { Actor, HttpAgent } from "@icp-sdk/core/agent";
import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";
import { makeIdlFactory } from "@research-ag/duel-game-core/idl.js";
import { start } from "@research-ag/duel-game-core/app.js";
import { connectTransport } from "@research-ag/duel-game-core/transport.js";
import { resolveAnonymousIdentity } from "@research-ag/duel-game-core/anon-identity.js";
import { deriveHost } from "@research-ag/duel-game-core/ic-env.js";
import { atTableOf, viewOf, viewTagOf, withLocalMove } from "@research-ag/duel-game-core/client.js";
import { debriefVerdict, tag } from "@research-ag/duel-game-core/render.js";
import { decodeGame, plugin } from "./connect-four-plugin.js";
import { screens } from "./screens.js";
import { createBotChallenge } from "./bots.js";
import { createStage } from "./stage.js";
import { createSound } from "./sound.js";

const env = safeGetCanisterEnv();
const canisterId = env?.["PUBLIC_CANISTER_ID:backend"];
if (!canisterId) {
  document.body.innerHTML =
    "<p style='color:#ff7b72;padding:2rem'>Could not find " +
    "<code>PUBLIC_CANISTER_ID:backend</code> in the <code>ic_env</code> " +
    "cookie. Serve this page from its frontend canister, with that " +
    "canister environment variable set to the backend's id.</p>";
  throw new Error("missing canister id");
}

// ── sound: unlocked by the first gesture, toggled in the header ──────────
const sound = createSound();
const unlock = () => sound.unlock();
window.addEventListener("pointerdown", unlock, { capture: true, once: true });
window.addEventListener("keydown", unlock, { capture: true, once: true });
const musicBtn = document.getElementById("music-toggle");
const sfxBtn = document.getElementById("sfx-toggle");
musicBtn.addEventListener("click", () => sound.setMusic(!sound.prefs.music));
sfxBtn.addEventListener("click", () => sound.setSfx(!sound.prefs.sfx));
sound.subscribe(({ music, sfx, playing }) => {
  musicBtn.setAttribute("aria-pressed", String(music));
  musicBtn.classList.toggle("playing", playing);
  sfxBtn.setAttribute("aria-pressed", String(sfx));
});

// ── the 3D board, framed in whatever the panel leaves free ──────────────
const header = document.querySelector("header");
const panel = document.querySelector(".panel");

function safeArea(w, h) {
  const pad = 14;
  const area = { left: pad, top: header.getBoundingClientRect().bottom + 2, right: w - pad, bottom: h - pad };
  const p = panel.getBoundingClientRect();
  if (p.width > 0 && p.height > 0) {
    if (p.right < w * 0.6 && p.height > h * 0.4) area.left = p.right + pad; // a column on the left
    else area.bottom = Math.min(area.bottom, p.top - 2); // a sheet at the bottom
  }
  return area;
}

let client = null;
const stage = createStage(document.getElementById("stage"), {
  safeArea,
  onDrop(col) {
    const state = client?.getState();
    if (!state || state.pending !== null) return;
    const v = viewOf(state.status, "inGame");
    if (!v || v.youSubmitted) return;
    void client.submit({ drop: { col } });
  },
  onHover: () => sound.tick(),
  onImpact: (strength) => sound.clack(strength),
  onRelease: () => sound.release(),
});
new ResizeObserver(() => stage.relayout()).observe(panel);
window.addEventListener("resize", () => stage.relayout());

// ── the backend ─────────────────────────────────────────────────────────
const host = deriveHost();
// The same identity must build the agent and sign the transport calls;
// the backend checks the two match on every request.
const session = resolveAnonymousIdentity();
const agent = await HttpAgent.create({
  host,
  identity: session.identity,
  rootKey: env.IC_ROOT_KEY,
});
const idlFactory = makeIdlFactory(plugin.idlTypes);
const actor = Actor.createActor(idlFactory, { agent, canisterId });

const transport = connectTransport({ actor, gameIdlTypes: plugin.idlTypes });

client = start({ plugin, transport, session, screens });

createBotChallenge({ actor, agent, backendId: canisterId, client, plugin });

// What the board shows: the status as drawn (your pending drop already
// applied), mapped onto a stage scene.
function sceneOf(status, pending) {
  const inGame = viewOf(status, "inGame");
  if (inGame) {
    return {
      mode: "play",
      ...decodeGame(inGame.game),
      mySeat: tag(inGame.seat),
      yourTurn: !inGame.youSubmitted && pending === null,
    };
  }
  const debrief = viewOf(status, "debrief");
  if (debrief) {
    const mySeat = tag(debrief.seat);
    return { mode: "final", ...decodeGame(debrief.finalGame), mySeat, outcome: debriefVerdict(debrief.end, mySeat).outcome };
  }
  return { mode: "attract" };
}

let endedKey = "";
function onState(state) {
  const shown = withLocalMove(state.status, state.pending, plugin.applyLocal.bind(plugin));
  document.body.dataset.phase = viewTagOf(shown) ?? (shown ? "browsing" : "connecting");
  stage.show(sceneOf(shown, state.pending));

  const debrief = viewOf(state.status, "debrief");
  if (debrief) {
    const key = `${atTableOf(state.status)?.id}:${debrief.gen}`;
    if (key !== endedKey) {
      endedKey = key;
      sound.outcome(debriefVerdict(debrief.end, tag(debrief.seat)).outcome);
    }
  }
}
client.subscribe((state, prev) => {
  if (state.status !== prev.status || state.pending !== prev.pending) onState(state);
});
onState(client.getState());

// The column buttons in the panel aim the board's ghost disc.
document.getElementById("screen").addEventListener("pointerover", (ev) => {
  const b = ev.target.closest?.("[data-col]");
  if (b) stage.preview(Number(b.dataset.col));
});

// Keys: 1–7 drop straight in; ← → aim, Enter / Space / ↓ drop.
window.addEventListener("keydown", (ev) => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  if (ev.target.closest?.("input, textarea, select")) return;
  const onButton = !!ev.target.closest?.("button");
  if (/^[1-7]$/.test(ev.key)) {
    stage.preview(Number(ev.key) - 1);
    stage.dropSelected();
  } else if (ev.key === "ArrowLeft") stage.nudge(-1);
  else if (ev.key === "ArrowRight") stage.nudge(1);
  else if (ev.key === "ArrowDown" || (!onButton && (ev.key === "Enter" || ev.key === " "))) stage.dropSelected();
  else return;
  ev.preventDefault();
});
