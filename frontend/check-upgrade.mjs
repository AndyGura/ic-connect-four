// Checks an upgrade of a live backend before you deploy it: compares
// the stable signature of the module the canister runs
// (fetched from hosty.live's module store by its certified module_hash)
// with the one src/Host.mo compiles to now, using moc's own
// --stable-compatible, and checks the new Candid interface against the
// live one with `mops check-candid`.
//
//   cd frontend && node check-upgrade.mjs <backend-id>
//
// Exit 0: the types are compatible with the live stable variables and
// with every client of the live interface; code that runs on the upgrade
// (a migration, postupgrade) still needs reading. Exit 1: they are not
// (moc or mops says which); fix the change or write a migration. Exit 2:
// nothing to compare. Needs `mops` and the network (icp-api.io,
// api.hosty.live).

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fetchGameModule, rawWasm } from "@research-ag/duel-game-core/module-store.js";

const backendId = process.argv[2];
if (!backendId) {
  console.error("usage: node check-upgrade.mjs <backend-id>");
  process.exit(2);
}

const root = resolve(import.meta.dirname, "..");
const work = mkdtempSync(join(tmpdir(), "check-upgrade-"));
const sh = (cmd, args) => execFileSync(cmd, args, { cwd: root, encoding: "utf8" }).trim();

// Reads a custom section by walking the module's sections by hand:
// `new WebAssembly.Module` rejects what moc 2 emits (64-bit tables) on
// some Node versions, and only the custom sections are needed here.
function section(wasm, name) {
  const bytes = new Uint8Array(wasm);
  let p = 8; // magic + version
  const leb = () => {
    let n = 0, shift = 0, b;
    do {
      b = bytes[p++];
      n += (b & 0x7f) * 2 ** shift;
      shift += 7;
    } while (b & 0x80);
    return n;
  };
  const wanted = ["public", "private"].map((vis) => `icp:${vis} ${name}`);
  while (p < bytes.length) {
    const id = bytes[p++];
    const size = leb();
    const end = p + size;
    if (id === 0) {
      const len = leb();
      const sname = new TextDecoder().decode(bytes.subarray(p, p + len));
      if (wanted.includes(sname)) return new TextDecoder().decode(bytes.subarray(p + len, end));
    }
    p = end;
  }
  return null;
}

let live;
try {
  live = await rawWasm(await fetchGameModule(backendId));
} catch (e) {
  console.error(`Could not fetch ${backendId}'s module: ${e.message}`);
  process.exit(2);
}
const liveTypes = section(live, "motoko:stable-types");
if (liveTypes === null) {
  console.error(`${backendId}'s module carries no motoko:stable-types section.`);
  process.exit(2);
}
writeFileSync(join(work, "live.most"), liveTypes);

const moc = sh("mops", ["toolchain", "bin", "moc"]);
const sources = sh("mops", ["sources"]).split(/\s+/).filter(Boolean);
try {
  execFileSync(moc, [...sources, "--stable-types", "--idl", "-o", join(work, "new.wasm"), "src/Host.mo"], {
    cwd: root,
    stdio: "inherit",
  });
} catch {
  console.error("src/Host.mo does not compile.");
  process.exit(2);
}

const liveDidText = section(live, "candid:service");
if (liveDidText === null) {
  console.error(`${backendId}'s module carries no candid:service section.`);
  process.exit(2);
}
writeFileSync(join(work, "live.did"), liveDidText);

// The diff is for reading only; `mops check-candid` decides.
const uncommented = (did) => did.replace(/^\s*\/\/.*\n/gm, "").trim() + "\n";
const liveDid = uncommented(liveDidText);
const newDid = uncommented(readFileSync(join(work, "new.did"), "utf8"));
if (liveDid === newDid) {
  console.log("Candid: unchanged.");
} else {
  writeFileSync(join(work, "live.plain.did"), liveDid);
  writeFileSync(join(work, "new.plain.did"), newDid);
  console.log("Candid changes (live → new):");
  try {
    execFileSync("diff", ["-u", join(work, "live.plain.did"), join(work, "new.plain.did")], { stdio: "inherit" });
  } catch {}
}

let ok = true;
try {
  execFileSync("mops", ["check-candid", join(work, "new.did"), join(work, "live.did")], { cwd: root, stdio: "inherit" });
  console.log("Candid: compatible — existing frontends and bots keep working.");
} catch {
  console.error("Candid: NOT compatible — a removed method or changed type breaks existing frontends and bots.");
  ok = false;
}

try {
  execFileSync(moc, ["--stable-compatible", join(work, "live.most"), join(work, "new.most")], { stdio: "inherit" });
  console.log("Stable signature: compatible with the live stable variables.");
} catch {
  console.error("Stable signature: NOT compatible — this upgrade would fail or drop data.");
  ok = false;
}
if (!ok) process.exit(1);
