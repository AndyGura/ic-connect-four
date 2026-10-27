"""Runs the built bot canister (.icp/cache/artifacts/bot) outside any replica,
to measure what one `make_move` costs and how deep Hard sees in that budget.

    icp build bot
    python3 tools/canister_sim.py            # pip install wasmtime ic-py

The canister's ic0 system calls are answered here; `performance_counter`
returns the wasm instructions executed so far in the message, counted with
wasmtime's fuel (one unit per instruction, close to the IC's own count).
Queries only: nothing here makes inter-canister calls.
"""
import os, sys, time

from ic.candid import Types, decode, encode
from wasmtime import Config, Engine, Linker, Module, Store, Trap, WasmtimeError

here = os.path.dirname(os.path.abspath(__file__))
WASM = os.path.join(here, "..", ".icp", "cache", "artifacts", "bot")

Seat = Types.Variant({"p1": Types.Null, "p2": Types.Null})
LastMove = Types.Record({"col": Types.Nat, "row": Types.Nat, "seat": Seat})
View = Types.Record({"board": Types.Vec(Types.Opt(Seat)), "lastMove": Types.Opt(LastMove), "winLine": Types.Vec(Types.Nat)})
Action = Types.Variant({"drop": Types.Record({"col": Types.Nat})})
MoveRequest = Types.Record({
    "tableId": Types.Nat, "seat": Seat, "game": View,
    "mode": Types.Variant({"simultaneous": Types.Null, "turnBased": Types.Null}),
    "step": Types.Nat, "gen": Types.Nat, "complexity": Types.Text,
    "retryReason": Types.Opt(Types.Text), "opponent": Types.Text,
    "opponentLastMove": Types.Opt(Action), "lastStepDurationNs": Types.Opt(Types.Int),
})


class Canister:
    def __init__(self, path):
        config = Config()
        config.wasm_memory64 = True
        config.consume_fuel = True
        self.engine = Engine(config)
        self.module = Module.from_file(self.engine, path)
        self.stable = bytearray()

    def _instantiate(self):
        # A fresh instance per query: the IC discards a query's changes, and
        # Motoko's runtime refuses a second query on the same memory.
        self.store = Store(self.engine)
        self.store.set_fuel(10**15)
        linker = Linker(self.engine)
        self.arg = b""
        self.reply = bytearray()
        self.replied = None
        self.start_fuel = 0
        for imp in self.module.imports:
            linker.define_func(imp.module, imp.name, imp.type, self._handler(imp.name, imp.type), access_caller=True)
        self.instance = linker.instantiate(self.store, self.module)
        self.exports = self.instance.exports(self.store)
        self.message("canister_init", encode([]))

    def mem(self, caller):
        return caller["mem"]

    def _handler(self, name, ty):
        results = list(ty.results)

        def read(caller, src, size):
            return bytes(self.mem(caller).read(caller, src, src + size))

        def write(caller, dst, data):
            self.mem(caller).write(caller, data, dst)

        def h(caller, *args):
            if name == "msg_arg_data_size":
                return len(self.arg)
            if name == "msg_arg_data_copy":
                dst, off, size = args
                write(caller, dst, self.arg[off:off + size])
                return
            if name == "msg_reply_data_append":
                self.reply += read(caller, *args)
                return
            if name == "msg_reply":
                self.replied = "reply"
                return
            if name == "msg_reject":
                self.replied = "reject: " + read(caller, *args).decode(errors="replace")
                return
            if name == "trap":
                raise RuntimeError("canister trapped: " + read(caller, *args).decode(errors="replace"))
            if name == "debug_print":
                print("[canister]", read(caller, *args).decode(errors="replace"))
                return
            if name == "time":
                return time.time_ns()
            if name == "performance_counter":
                return self.start_fuel - self.store.get_fuel()
            if name in ("canister_self_size", "msg_caller_size"):
                return 1
            if name in ("canister_self_copy", "msg_caller_copy"):
                dst, off, size = args
                write(caller, dst, b"\x04"[off:off + size])
                return
            if name == "is_controller":
                return 1
            if name == "canister_status":
                return 1
            if name == "stable64_size":
                return len(self.stable) // 65536
            if name == "stable64_grow":
                old = len(self.stable) // 65536
                self.stable += bytes(args[0] * 65536)
                return old
            if name == "stable64_write":
                off, src, size = args
                self.stable[off:off + size] = read(caller, src, size)
                return
            if name == "stable64_read":
                dst, off, size = args
                write(caller, dst, bytes(self.stable[off:off + size]))
                return
            # Calls, cycles, timers: not used by queries.
            return 0 if len(results) == 1 else None

        return h

    def message(self, export, arg):
        self.arg = arg
        self.reply = bytearray()
        self.replied = None
        self.start_fuel = self.store.get_fuel()
        try:
            self.exports[export](self.store)
        except (Trap, WasmtimeError) as e:
            raise RuntimeError(f"{export} trapped: {e}")
        used = self.start_fuel - self.store.get_fuel()
        return bytes(self.reply), self.replied, used

    def query(self, method, args):
        self._instantiate()
        reply, how, used = self.message("canister_query " + method, encode(args))
        if how != "reply":
            raise RuntimeError(f"{method}: {how}")
        return decode(reply), used


def board_of(moves):
    """The View board after `moves` (a string of columns, Red first)."""
    board = [None] * 42
    heights = [0] * 7
    for i, ch in enumerate(moves):
        c = int(ch)
        board[heights[c] * 7 + c] = "p1" if i % 2 == 0 else "p2"
        heights[c] += 1
    return board


def opt_seat(cell):
    return [] if cell is None else [{cell: None}]


def analyse(can, moves, complexity="Hard"):
    board = board_of(moves)
    seat = "p1" if len(moves) % 2 == 0 else "p2"
    out, used = can.query("analyse", [
        {"type": Types.Vec(Types.Opt(Seat)), "value": [opt_seat(c) for c in board]},
        {"type": Seat, "value": {seat: None}},
        {"type": Types.Text, "value": complexity},
    ])
    return out[0]["value"], used


def make_move(can, moves, complexity):
    board = board_of(moves)
    seat = "p1" if len(moves) % 2 == 0 else "p2"
    req = {
        "tableId": 1, "seat": {seat: None},
        "game": {"board": [opt_seat(c) for c in board], "lastMove": [], "winLine": []},
        "mode": {"turnBased": None}, "step": len(moves), "gen": 1, "complexity": complexity,
        "retryReason": [], "opponent": "x", "opponentLastMove": [], "lastStepDurationNs": [],
    }
    out, used = can.query("make_move", [{"type": MoveRequest, "value": req}])
    return out[0]["value"], used


if __name__ == "__main__":
    can = Canister(WASM)
    positions = sys.argv[1:] or ["", "3", "33", "3332", "334411", "3324154", "33333322", "3344225566", "444333555", "4433225511660"]
    for moves in positions:
        r, used = analyse(can, moves)
        fields = {k.lstrip("_"): v for k, v in r.items()}
        print(f"after '{moves}': {fields}  ({used / 1e9:.2f}B instructions)")
    for level in ["Easy", "Medium", "Hard", "Default"]:
        mv, used = make_move(can, "33", level)
        print(f"make_move {level}: {mv}  ({used / 1e9:.3f}B instructions)")
