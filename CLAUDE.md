# Connect Four

A 2-player game on duel-game-core
(https://github.com/research-ag/duel-core): `src/ConnectFourRules.mo`
holds the rules, `src/Host.mo` the host actor, `frontend/` the page.
Read `.claude/skills/duel-game-core/SKILL.md` before changing anything;
for a change to the live game, its `references/changing-a-live-game.md`.

## Live

| Canister | Id                            | Runs                                         |
| -------- | ----------------------------- | -------------------------------------------- |
| backend  | `co6yk-kyaaa-aaaau-ahgea-cai` | the game; the module store has it            |
| frontend | `cj766-haaaa-aaaau-ahgeq-cai` | https://cj766-haaaa-aaaau-ahgeq-cai.icp0.io/ |
| bot      | `n5zoo-cqaaa-aaaau-ahhbq-cai` | `bot/`, registered as "Connect Four Bot"     |

Deployed through hosty.live (`going-live.md`). The live backend runs
module `1bd622e9…130a` since 2026-11-18, which this tree builds byte for
byte (with duel-core at `cd3f163`); hosty snapshot
`000000000000000200000000028039880101` was taken before that upgrade. The
live page carries invite links since 2026-11-18.
The backend's freezing threshold is 30 days since 2026-10-28; at 365
days a 128 MiB heap grow needed ~2.9 TC frozen and failed with IC0532
despite ~2 TC on the canister. Keep it at 30 days.
Keep the backend at 1 TC or more: on 2026-11-18 it had sunk to 0.32 TC,
its sweep timer had stalled (~0.48 TC with 256 MiB) and it refused every
update (IC0207); it was topped up to 1.12 TC. The 269 MB snapshot raises
its idle burn from ~8.6 to ~14.6 B cycles a day.

## What the game runs

- Mode: `#turnBased`.
- Sweep timer: lazy (`sweeper = Transport.sweeper()` in the Host's
  `env`, duel-core #56/#57): it runs only while there is a table or a
  waiting player, so `canister_version` in `/metrics` stays flat while
  nobody plays.
- Invite links: on in this tree and live. A private table is an invite
  (`#t=<table>&c=<code>`, shared from the waiting screen); the bot
  dialog's Share links (`#new&b=…`) are followed by `bots.js`. The
  player is kept per browser (duel-game-core 0.5.x).
- Bot support (the Host's and the page's BOTS lines): on in this tree
  and live, backend and page. The page's bot dialog is the game's own
  `frontend/src/bots.js`.
- Leaderboard: off.
- Search and link previews: the page's title, description, canonical,
  Open Graph/Twitter tags and JSON-LD point at the cj766 URL, with
  `robots.txt`, `sitemap.xml`, a manifest and icons beside it. The PNGs
  and `favicon.ico` come from `frontend/make-images.mjs`. Live since
  2026-10-27.
- A bot canister: `bot/` (Easy, Medium, Hard; its own `README.md`),
  live at `n5zoo-cqaaa-aaaau-ahhbq-cai` since 2026-10-27 and registered
  with the game. Any bot that calls `register_bot` is listed.
- duel-game-core: `../duel-core/backend` (mops, a sibling clone of
  research-ag/duel-core, at `cd3f163`) and `@research-ag/duel-game-core`
  0.5.1 (npm). Built with the Motoko recipe v5.1.0 (entry point in
  `mops.toml`).

## Working here

- The default branch is the game: merge finished work there, and
  update this file whenever a canister or a feature changes.
- `mops test`; `cd frontend && npm run build && node play-test.mjs`.
- Before upgrading the backend: `cd frontend && node check-upgrade.mjs
  co6yk-kyaaa-aaaau-ahgea-cai` must exit 0.
- A change to `View`, `Action`, `Options` or the rules updates
  `SEMANTICS` in the same change.
