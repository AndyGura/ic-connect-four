# Connect Four

Classic Connect Four for two players on the Internet Computer, built on
[duel-game-core](https://github.com/research-ag/duel-core): a 3D board
with slow, relaxed animations, quiet generative lounge music, and the
framework's lobby, seating, rematch, idle takeover and claim-a-win.

## The game

- A 7 × 6 board standing upright. Red (the first seat) drops first, then
  the players alternate, one disc per turn.
- A disc falls to the lowest empty cell of the chosen column; a full
  column cannot be chosen.
- Four or more discs of one colour in a row — horizontally, vertically or
  diagonally — win at once.
- All 42 cells filled without a line of four is a draw.

Play by clicking a column on the board (on a phone: tap once to aim, tap
again to drop), with the column buttons in the panel, or with the keys
1–7 (← → to aim, Enter or ↓ to drop). The music and sound-effect toggles
sit in the header and are remembered per browser.

The backend publishes the full rules for anyone building their own
frontend or bot at `https://<backend-id>.raw.icp0.io/semantics`.

## Canisters

| Canister | Id                            |                                                    |
| -------- | ----------------------------- | -------------------------------------------------- |
| backend  | `co6yk-kyaaa-aaaau-ahgea-cai` | module `29f5b4a2…`, in hosty.live's store, verified |
| frontend | `cj766-haaaa-aaaau-ahgeq-cai` | https://cj766-haaaa-aaaau-ahgeq-cai.icp0.io/        |

Both are controlled by the owner's hosty.live account. The game is
unlisted until its frontend is registered on the
[Duel dashboard](https://n6plc-4yaaa-aaaaj-qshia-cai.icp.net/).

**Cycles and the freezing threshold.** Both canisters were created with
a 365-day freezing threshold, and on their subnet that made the
frontend refuse to grow its memory (`IC0532`, "cannot grow memory … due
to insufficient cycles") however much it was topped up. Resetting it in
the hosty.live web app set 30 days, and it worked at once. The backend
still has 365 days: if its update calls ever fail with `IC0532`, lower
its freezing threshold rather than adding cycles, and don't reset it,
which would wipe its tables. Check both with `hosty_get_canister_status`.

## Layout

| Path                                 | What it is                                                                                   |
| ------------------------------------ | -------------------------------------------------------------------------------------------- |
| `src/ConnectFourRules.mo`            | The rules: a pure `#turnBased` module (`State`, `Action`, `View`, `SEMANTICS`).              |
| `src/Host.mo`                        | The host actor, from the framework's template (idle timeout 150 s, claim timeout 120 s).     |
| `test/RulesUnit.test.mo`             | Unit checks of every rule, win direction, draw and rejection.                                |
| `test/Lifecycle.test.mo`             | Whole games through the real engine: a win, a rematch, a 42-disc draw, the engine's gates.   |
| `frontend/src/connect-four-plugin.js`| The `GamePlugin`: Candid types, the panel's player strip, column buttons, `applyLocal`.      |
| `frontend/src/stage.js`              | The Three.js board beside the panel: disc physics, hover, last-move ring, win glow.          |
| `frontend/src/sound.js`              | Web Audio lounge loop and sound effects; no audio files.                                     |
| `frontend/src/screens.js`            | The lobby and debrief screens in the game's own words.                                       |
| `frontend/src/app.js`                | Bootstrap: agent, transport, the default shell, and the wiring to the stage and the sound.   |
| `frontend/play-test.mjs`             | Headless end-to-end test: two fresh players play whole games through the real client.        |
| `.claude/skills/duel-game-core/`     | The framework's skill, which Claude Code sessions on this repository load by themselves.     |

## Build

Needs Node 22, [icp-cli](https://github.com/dfinity/icp-cli),
[mops](https://mops.one) and `ic-wasm`:

```bash
npm install -g @icp-sdk/icp-cli ic-mops
cargo install ic-wasm --locked      # icp-cli's Motoko recipe calls it
```

duel-game-core is not on mops.one yet, so `mops.toml` points at a clone
of the framework next to this repository (built and tested against
commit `37dad15`):

```bash
git clone https://github.com/research-ag/duel-core.git ../duel-core
mops install
(cd frontend && npm install)
icp build backend                    # .icp/cache/artifacts/backend
(cd frontend && npm run build)       # frontend/dist
```

## Test

```bash
mops test                            # rules unit checks + engine lifecycle
icp network start -d                 # a local Internet Computer
icp deploy                           # both canisters, locally; prints the page's URL
(cd frontend && node play-test.mjs)  # whole games, a rematch and a leave, via the real client
```

`play-test.mjs` plays a full game with two fresh identities, every move
taken from the plugin's own column buttons, tries one illegal move, then
a rematch, a leave and both debriefs. Against a deployed backend:
`node play-test.mjs <backend-id> --ic`.

`browser-test.mjs` checks the page itself in two headless Chromium tabs:
a protected table, a game played with every input (keys, a click on the
3D board, arrow-key aiming, the column buttons) to Red's win, both 3D
boards settled on the real position, then a rematch and a forfeit. It
needs Playwright (`npm i -D playwright && npx playwright install
chromium`):

```bash
cd frontend
node browser-test.mjs https://<frontend-id>.icp0.io/   # the live page
node browser-test.mjs --serve <backend-id>             # dist/, served locally, against a mainnet backend
```

Without a GPU, Chromium renders the board in software at a frame or two
a second, so the 3D board needs a few minutes to catch up; the test
waits for it. Screenshots land in `frontend/browser-test-shots/`.

## Update the live game

Every change: run the three tests above first, then upgrade the same two
canisters through [hosty.live](https://hosty.live) — from a Claude Code
session with hosty.live's MCP server (`.mcp.json`), or by hand in the
hosty.live web app. Each install is approved once in a hosty.live deploy
session.

Backend — upgrade in place, keeping its tables, with a snapshot to roll
back to:

```bash
icp build backend
```

then `hosty_prepare_wasm_upload { canisterId: <backend-id>, wasmPath:
".icp/cache/artifacts/backend", snapshotBeforeUpgrade: true }`, run the
`curl` it returns from the project root, and `hosty_wait_for_deployment`.
`hosty_restore_snapshot` undoes a bad upgrade.

Frontend — rebuild and upload; the page keeps its
`PUBLIC_CANISTER_ID:backend` variable between uploads:

```bash
cd frontend && npm run build && zip -r dist.zip dist -x "*.map"
```

then `hosty_prepare_zip_upload { canisterId: <frontend-id>, pureAssets:
true, outputDir: "dist" }`, run its `curl` from `frontend/`, and
`hosty_wait_for_deployment`. By hand: the canister's page → **Deploy** →
**ZIP Upload**, already built, output directory `dist`.

Finally `(cd frontend && node play-test.mjs <backend-id> --ic)` against
the live backend.
