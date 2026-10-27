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
module `c9ed010f…da2c` since 2026-10-26, which this tree builds byte for
byte (with duel-core at `49e1503`); a snapshot was taken before that
upgrade. The live page carries the bot dialog since 2026-10-27.

## What the game runs

- Mode: `#turnBased`.
- Bot support (the Host's and the page's BOTS lines): on in this tree
  and live, backend and page. The page's bot dialog is the game's own
  `frontend/src/bots.js`.
- Leaderboard: off.
- Search and link previews: the page's title, description, canonical,
  Open Graph/Twitter tags and JSON-LD point at the cj766 URL, with
  `robots.txt`, `sitemap.xml`, a manifest and icons beside it. The PNGs
  and `favicon.ico` come from `frontend/make-images.mjs`. Not live yet.
- A bot canister: `bot/` (Easy, Medium, Hard; its own `README.md`),
  live at `n5zoo-cqaaa-aaaau-ahhbq-cai` since 2026-10-27 and registered
  with the game. Any bot that calls `register_bot` is listed.
- duel-game-core: `../duel-core/backend` (mops, a sibling clone of
  research-ag/duel-core) and `@research-ag/duel-game-core` 0.4.0 (npm).

## Working here

- The default branch is the game: merge finished work there, and
  update this file whenever a canister or a feature changes.
- `mops test`; `cd frontend && npm run build && node play-test.mjs`.
- Before upgrading the backend: `cd frontend && node check-upgrade.mjs
  co6yk-kyaaa-aaaau-ahgea-cai` must exit 0.
- A change to `View`, `Action`, `Options` or the rules updates
  `SEMANTICS` in the same change.
