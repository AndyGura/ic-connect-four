"""Runs tools/arena.mo with the matches given on the command line, e.g.

    python3 tools/arena.py 'match_(hard(150_000), MEDIUM, 10)' 'match_(MEDIUM, EASY, 10)'

Compiles a copy of arena.mo to WASI with the project's moc, then runs it in
wasmtime (pip install wasmtime; Motoko's 64-bit wasm needs memory64).
"""
import os, subprocess, sys, tempfile, time

from wasmtime import Config, Engine, FuncType, Linker, Module, Store, ValType, WasiConfig

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)
with open(os.path.join(here, "arena.mo")) as f:
    src = f.read().replace("// __MATCHES__", "\n".join(m + ";" for m in sys.argv[1:]))
run = os.path.join(here, f"arena.run.{os.getpid()}.mo")
with open(run, "w") as f:
    f.write(src)
moc = subprocess.check_output(["mops", "toolchain", "bin", "moc"], cwd=root, text=True).strip()
sources = subprocess.check_output(["mops", "sources"], cwd=root, text=True).split()
out = os.path.join(tempfile.mkdtemp(prefix="arena-"), "arena.wasm")
built = subprocess.run([moc, *sources, "-wasi-system-api", "-o", out, run], cwd=root, capture_output=True, text=True)
os.remove(run)
if built.returncode != 0:
    sys.exit("\n".join(l for l in built.stderr.splitlines() if "error" in l))

config = Config()
config.wasm_memory64 = True
config.consume_fuel = True
engine = Engine(config)
linker = Linker(engine)
linker.define_wasi()
store = Store(engine)
store.set_fuel(10**18)

# Lines printed as "MARK <label>" show the wasm instructions executed since
# the previous mark (wasmtime fuel: one per instruction), for benchmarks.
last = [10**18]
def fd_write(caller, fd, iovs, n, written):
    mem = caller["memory"]
    out = b""
    for i in range(n):
        base = iovs + 8 * i
        ptr = int.from_bytes(bytes(mem.read(caller, base, base + 4)), "little")
        ln = int.from_bytes(bytes(mem.read(caller, base + 4, base + 8)), "little")
        out += bytes(mem.read(caller, ptr, ptr + ln))
    mem.write(caller, len(out).to_bytes(4, "little"), written)
    text = out.decode(errors="replace")
    if text.startswith("MARK"):
        now = store.get_fuel()
        text = f"{text.rstrip()}: {last[0] - now:,} instructions\n"
        last[0] = now
    sys.stdout.write(text)
    sys.stdout.flush()
    return 0


linker.allow_shadowing = True
linker.define_func("wasi_snapshot_preview1", "fd_write", FuncType([ValType.i32()] * 4, [ValType.i32()]), fd_write, access_caller=True)
wasi = WasiConfig()
wasi.inherit_stderr()
store.set_wasi(wasi)
instance = linker.instantiate(store, Module.from_file(engine, out))
t0 = time.time()
instance.exports(store)["_start"](store)
print(f"({time.time() - t0:.1f} s)")
