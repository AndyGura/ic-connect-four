# Connect Four bot

A canister player for the live Connect Four game
(backend `co6yk-kyaaa-aaaau-ahgea-cai`, page
https://cj766-haaaa-aaaau-ahgeq-cai.icp0.io/), built on
[duel-game-core](https://github.com/research-ag/duel-core). The game
calls the bot's `make_move` whenever the bot is due, and the reply is its
drop. Players challenge it from the game's "Challenge a bot" dialog, at
one of three levels:

| Level  | How it plays                                                                                                                                                                                                                                                                                                                       |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Easy   | A random legal drop, every time.                                                                                                                                                                                                                                                                                                   |
| Medium | Looks one move ahead: takes a win, blocks one, never drops right under a cell the opponent wins on, and makes a double threat when it has one. Otherwise it prefers the centre and threats on its own rows, picking at random among moves of about equal value. It does not see a double threat being built against it, so a player who plans two moves ahead beats it. |
| Hard   | Perfect moves from an opening book (as Red, every line through the 14th disc), then an exact solver (win, draw or loss with perfect play) from the 12th disc on, and a deep heuristic search (12–14 plies in the middle game) wherever the solver runs out of budget. Red wins Connect Four with perfect play, and as Red Hard plays it; as Yellow it holds out and takes the first chance a slip gives it. |

**Bot canister: `n5zoo-cqaaa-aaaau-ahhbq-cai`**, registered with the live game as "Connect Four Bot" (2026-10-27).

## How Hard thinks, and what it costs

Hard has 1.2 billion instructions per move (`BotLogic.HARD.maxWork`),
counted with the IC's own instruction counter, well inside a query's
limit: about 0.0005 TC per move at most. A book move costs about 0.06
billion (the search's tables are allocated on every call), so a whole
game costs about 0.01 TC. Easy and Medium cost next to nothing. In that
budget:

1. **Book** (`src/Book.mo`, 35,449 positions). As Red: a winning move for
   every position Red can reach while following it, whatever Yellow
   plays, through the 14th disc. As Yellow: a winning (or drawing) move
   through the 13th disc wherever Red's opening was not the centre,
   which lets Yellow win or draw. Computed offline by an exact solver
   (`tools/book/`); a position and its mirror image share an entry.
2. **Exact search** (`Search.exact`), from the 12th disc on, within 80%
   of the budget: a winning move if there is one; otherwise the drawing
   moves, which the heuristic search then chooses among.
3. **Heuristic search** (`Search.negamax`), with whatever budget is left:
   iterative deepening, principal variation search, a 1M-entry
   transposition table, and a score of threats (cells that would
   complete four), their rows (Red wants odd rows, Yellow even ones,
   Allis' zugzwang rules; a threat right above an opponent's is dead)
   and cell weights. About 3,100 instructions per node: some 360,000
   nodes per move.

`analyse(board, seat, complexity)` (a query) shows what a level would
play in any position, how deep it saw, whether it solved the position
and how many instructions it used.

**Measured** (tools below; Hard at its canister budget, the opponent's
first two moves varied, Hard choosing all of its own):

| Match                                                        | Result                       |
| ------------------------------------------------------------ | ---------------------------- |
| Hard vs a 4-ply searcher (`careful(4)`)                      | 28 won of 28                 |
| Hard vs a 6-ply searcher                                     | 28 won of 28                 |
| Hard vs an 8-ply searcher                                    | 28 won of 28                 |
| Hard vs a 6-ply searcher with an exact endgame (`solver(6)`) | 28 won of 28                 |
| Hard vs Medium                                               | 28 won of 28                 |
| Medium vs Easy                                               | 59 won, 1 lost of 60         |
| Medium vs a 2-ply searcher                                   | 1 won, 1 drawn, 38 lost of 40 |

On 297 positions from varied games, each labelled by the exact solver,
Hard keeps the game-theoretic result with 95.6% of its moves (every one
from the 16th disc on); its misses are in openings off its own book's
lines, which it does not reach when it plays from the start.

## Layout

| Path                         | What it is                                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------------------------- |
| `src/GameTypes.mo`           | `View`, `Action`, `Options`, translated literally from the game's `/semantics`.                 |
| `src/GameRules.mo`           | The rules the bot needs (legal drops, the landing row, four in a row), from `RULES`.            |
| `src/Search.mo`              | Bitboards, the exact and the heuristic search.                                                  |
| `src/Book.mo`                | The opening book (generated).                                                                   |
| `src/BotLogic.mo`            | `chooseMove` per level: Easy, Medium, Hard.                                                     |
| `src/Bot.mo`                 | The canister: `make_move`, `play`, `register`, `unregister`, `analyse`.                         |
| `src/Sparring.mo`            | Local tests only: plays the bot's opponent seat the way a browser does.                        |
| `test/BotLogic.test.mo`      | Unit checks: every level answers legally, takes wins, blocks losses, sees what it claims.       |
| `test/WholeGames.test.mo`    | Whole games through the game's own engine and rules, every level, both seats.                   |
| `tools/arena.py`, `arena.mo` | Strength checks at full depth: games between levels, compiled to WASI.                          |
| `tools/match.py`             | A match, each game in its own wasm instance.                                                    |
| `tools/canister_sim.py`      | Runs the built canister wasm outside a replica and measures what each move costs.              |
| `tools/book/`                | The exact solver, the book generator and `make_book.py`, which writes `src/Book.mo`.            |
| `backend.wasm`, `backend.did`| The live game's module and Candid, for the local copy of the game.                              |

## Build

Needs [icp-cli](https://github.com/dfinity/icp-cli),
[mops](https://mops.one) and `ic-wasm`:

```bash
npm install -g @icp-sdk/icp-cli ic-mops @icp-sdk/ic-wasm
```

duel-game-core is not on mops.one, so `mops.toml` points at a clone of
the framework two levels up (this bot was built against commit
`49e1503`):

```bash
git clone https://github.com/research-ag/duel-core.git ../../duel-core   # from bot/
mops install
icp build bot                        # .icp/cache/artifacts/bot
```

## Test

```bash
mops test                            # unit checks, then whole games through the game's engine
```

`test/WholeGames.test.mo` runs the game's own rules
(`../src/ConnectFourRules.mo` of this repository) and duel-game-core's
engine in the interpreter: this repository's game source, with
duel-core at `49e1503`, builds into the live module byte for byte, so
these are the live game's rules and engine. Every level plays from both
seats against every level; every game must reach its real ending with
the bot answering every ask at the first try.

Then on a local network, against a private copy of the live game:

```bash
icp network start -d
icp deploy                           # backend (the live module), bot, sparring
HOST=$(icp canister status backend -i)
icp canister call sparring open_table "(principal \"$HOST\", variant { p1 }, record {})"
# (variant { ok = record { tableId = <id> : nat; rev = 1 : nat } })
icp canister call bot play "(principal \"$HOST\", <id> : nat, variant { p2 }, null, \"Hard\")"
icp canister call sparring step "(principal \"$HOST\", \"Medium\")"   # repeat until a debrief
icp canister call sparring ack_ended "(principal \"$HOST\")"
icp network stop
```

Play at least one game per level, with the bot in each seat
(`open_table`'s seat is sparring's; give `play` the other one). The game
has no options (`record {}`), so there is one variant.

**Strength.** `tools/arena.py` (needs `pip install wasmtime`) compiles
`tools/arena.mo` to WASI and runs it in wasmtime; `tools/match.py` plays
a match, each game in its own instance:

```bash
python3 tools/match.py 'hard(360_000)' 'careful(6)' 14 --free
```

`hard(n)` is Hard with a budget of `n` search nodes, about what 1.2
billion instructions buy; `careful(d)` searches `d` plies (no book, no
exact search), always playing what it thinks best; `solver(d)` adds an
exact search from the 12th disc with eight million nodes. `--free`
forces only the opponent's first two moves, so each game differs and
Hard plays every move of its own, as it does live. `tools/canister_sim.py` runs the built
canister itself and measures each move's instructions (`icp build bot
&& python3 tools/canister_sim.py`; also needs `pip install ic-py`).

**The book.** `tools/book/book.c` writes, for every position the book's
side reaches up to a number of discs, a move that keeps the position's
value; `tools/book/solve.c` is the same exact solver, answering for
one position at a time (used to label test positions).
`tools/book/make_book.py` writes `src/Book.mo` from the generator's
output. The current book, about five minutes on four cores:

```bash
gcc -O2 -o book tools/book/book.c
for r in 30 31 32 33; do printf '%s\n' $r | ./book 14 > red_$r.txt & done   # Red, after 3 and each reply
for r in 0 1 2; do printf '%s\n' $r | ./book 13 > yellow_$r.txt & done     # Yellow, after Red 0, 1, 2
wait
printf '3 1\n' > red_root.txt       # the empty board: the centre wins
python3 tools/book/make_book.py red_*.txt yellow_*.txt
```

(Mirror images cover Yellow's other first replies and Red's 4, 5, 6.)

## The live game's module

`backend.wasm` is the module the live backend runs, fetched from
hosty.live's module store by its `module_hash` and checked against it:

```bash
HASH=$(icp canister status co6yk-kyaaa-aaaau-ahgea-cai -n ic -p --json | sed -n 's/.*"module_hash":"0x\([0-9a-f]*\)".*/\1/p')
curl -sf https://api.hosty.live/modules/$HASH -o backend.wasm
sha256sum backend.wasm               # must print $HASH
```

`icp.yaml` pins it (`sha256`). If the live game is ever upgraded,
fetch the new module the same way, update the `sha256` and test again.
`icp canister link backend co6yk-kyaaa-aaaau-ahgea-cai -e ic` has been
run once (`.icp/data/mappings/ic.ids.json`), so a mistaken bare
`icp deploy -e ic` fails on `backend` instead of installing a second
copy of the game.

## Going live (hosty.live)

From a Claude Code session with hosty.live's MCP server (`.mcp.json` at
the repository root), in one deploy session approved in the hosty.live
web app:

1. `hosty_create_canister` with `kind: "backend"` (1.5 TC from the
   hosty.live balance).
2. `icp build bot`, then `hosty_prepare_wasm_upload` for that canister
   with `wasmPath: ".icp/cache/artifacts/bot"` (a fresh canister's first
   install: `confirmReinstall: true`), run the `curl` it returns from
   `bot/`, and `hosty_wait_for_deployment`.
3. `hosty_call_canister` on the bot: method `register`, argument
   `(principal "co6yk-kyaaa-aaaau-ahgea-cai", "<bot name>")`, as an
   update call. The reply's caller must be the owner's principal.
4. Check the game lists it:

   ```bash
   icp canister call co6yk-kyaaa-aaaau-ahgea-cai list_bots '()' -n ic --query --identity anonymous
   ```

5. Write the bot's canister id at the top of this file.

## Updating the bot

Every change: `mops test` and the local games above first, then upgrade
the same canister, never a new one: `hosty_prepare_wasm_upload` with the
bot's canister id and `snapshotBeforeUpgrade: true`. If the name or the
levels changed, call `register` again and check `list_bots`.
`unregister` (argument `(principal "co6yk-kyaaa-aaaau-ahgea-cai")`)
takes it off the list.

**On your own computer, with icp-cli** (an identity of yours that
controls the bot, and cycles):

```bash
icp canister link backend co6yk-kyaaa-aaaau-ahgea-cai -e ic --force
icp deploy bot -e ic
icp canister call bot register '(principal "co6yk-kyaaa-aaaau-ahgea-cai", "<bot name>")' -e ic
```

Name `bot` on the deploy line: a bare `icp deploy -e ic` would also try
`backend` (which fails) and `sparring` (which has no use on mainnet).
When the bot went up through hosty.live, `icp canister link bot <bot-id>
-e ic` first, so icp-cli upgrades that canister instead of creating one.
