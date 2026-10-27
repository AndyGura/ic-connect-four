"""A match between two players of tools/arena.mo, each game in its own
wasm instance (Motoko collects no garbage in a WASI program, and Hard
allocates its tables on every move), four at a time.

    python3 tools/match.py 'hard(360_000)' 'careful(6)' 10

plays 10 pairs of games (both colours, from the openings arena.mo's
`game_` uses) and prints the score and the lost games' moves. With
`--free` only the second player's first two moves are forced (`free_`).
"""
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

here = os.path.dirname(os.path.abspath(__file__))
a, b, pairs = sys.argv[1], sys.argv[2], int(sys.argv[3])
# --free: only b's first two moves are forced (arena.mo's free_), so a
# plays as it would live; otherwise both sides' first moves are (game_).
mode = "free_" if "--free" in sys.argv[4:] else "game_"

def run(job):
    i, red = job
    out = subprocess.run([sys.executable, os.path.join(here, "arena.py"), f"{mode}({a}, {b}, {i}, {'true' if red else 'false'})"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("GAMERESULT"):
            _, r, colour, moves = line.split()
            return int(r), colour, moves
    raise RuntimeError(f"game {job} produced no result: {out[-500:]}")

with ThreadPoolExecutor(4) as ex:
    results = list(ex.map(run, [(i, red) for i in range(pairs) for red in (True, False)]))
won = sum(r == 1 for r, _, _ in results)
lost = [f"{c}:{m}" for r, c, m in results if r == -1]
print(f"{a} vs {b}: {won} won, {len(results) - won - len(lost)} drawn, {len(lost)} lost" + (f" | lost: {' '.join(lost)}" if lost else ""))
