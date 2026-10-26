// Browser check for Connect Four, beside play-test.mjs: two Chromium tabs
// play through the real page — app.js, the default shell, the 3D stage —
// against a live backend. Red creates a protected table, Yellow joins with
// its code; Red plays by keyboard, a click on the 3D board and arrow-key
// aiming, Yellow by keys and the panel's column buttons, until Red's
// vertical four. Both 3D boards must settle on the real position (the
// stage publishes it as `#stage[data-board]`), then a rematch and a leave.
// Run from frontend/ after `npm run build`:
//
//   node browser-test.mjs https://<frontend-id>.icp0.io/   # a deployed page
//   node browser-test.mjs --serve <backend-id>             # dist/, served here,
//                                                           # against a mainnet backend
//
// Needs Playwright and a Chromium (npm i -D playwright && npx playwright
// install chromium). Screenshots land in browser-test-shots/. Software
// WebGL (no GPU) renders a frame or two a second, so the 3D board catches
// up slowly: allow several minutes.

import { createServer } from "node:http";
import { createRequire } from "node:module";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { extname, join, resolve } from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require(require.resolve("playwright", { paths: [process.cwd(), "/opt/node-tools/node_modules"] }));

// The Internet Computer's public root key, as a frontend canister serves
// it in its ic_env cookie.
const IC_ROOT_KEY =
  "308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100814c0e6ec71fab583b08bd81373c255c3c371b2e84863c98a4f1e08b74235d14fb5d9c0cd546d9685f913a0c0b2cc5341583bf4b4392e467db96d65b9bb4cb717112f8472e0d5a4d14505ffd7484b01291091c5f87b98883463f98091a0baaae";

const args = process.argv.slice(2);
const shots = resolve("browser-test-shots");
mkdirSync(shots, { recursive: true });

// --serve: dist/ the way its asset canister serves it — the ic_env cookie
// and the headers from _headers.
function serve(backend) {
  const dist = resolve("dist");
  const env = encodeURIComponent(`ic_root_key=${IC_ROOT_KEY}&PUBLIC_CANISTER_ID:backend=${backend}`);
  const headers = {};
  for (const line of readFileSync(join(dist, "_headers"), "utf8").split("\n")) {
    const m = line.match(/^\s+([A-Za-z-]+):\s*(.+)$/);
    if (m) headers[m[1]] = m[2];
  }
  const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };
  return new Promise((ok) => {
    const server = createServer((req, res) => {
      let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      if (p === "/") p = "/index.html";
      const f = join(dist, p);
      if (!f.startsWith(dist) || !existsSync(f)) {
        res.writeHead(404);
        return res.end();
      }
      res.writeHead(200, {
        ...headers,
        "Content-Type": types[extname(f)] ?? "application/octet-stream",
        "Set-Cookie": `ic_env=${env}; Path=/; SameSite=Lax`,
      });
      res.end(readFileSync(f));
    }).listen(0, "127.0.0.1", () => ok({ url: `http://127.0.0.1:${server.address().port}/`, server }));
  });
}

const served = args[0] === "--serve" ? await serve(args[1]) : null;
const pageUrl = served?.url ?? args[0];
if (!pageUrl) {
  console.error("usage: node browser-test.mjs <page-url> | --serve <backend-id>");
  process.exit(2);
}

const browser = await chromium.launch({
  args: [
    // Behind an egress proxy, Chromium's own flag keeps loopback direct.
    ...(process.env.HTTPS_PROXY ? [`--proxy-server=${process.env.HTTPS_PROXY}`] : []),
    "--use-gl=angle",
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
    "--ignore-gpu-blocklist",
  ],
});
const errors = [];

async function open(name, viewport) {
  const page = await (await browser.newContext({ viewport })).newPage();
  page.on("pageerror", (e) => errors.push(`${name}: ${e}`));
  page.on("console", (m) => m.type() === "error" && errors.push(`${name}: ${m.text()}`));
  await page.goto(pageUrl, { waitUntil: "domcontentloaded", timeout: 120_000 });
  return page;
}

const shot = (page, name) => page.screenshot({ path: join(shots, `${name}.png`) });
const lastMove = (page) => page.locator(".c4-last").innerText();
const myTurn = (page) =>
  page.waitForFunction(
    () => document.querySelector("#screen .c4-cols") && !document.body.classList.contains("working"),
    null,
    { timeout: 120_000 },
  );
const boardOf = (cells) => {
  const b = Array(42).fill(".");
  for (const [i, c] of cells) b[i] = c;
  return b.join("");
};
async function settled(page, name, cells) {
  const t0 = Date.now();
  await page.waitForFunction(
    (b) => {
      const s = document.getElementById("stage");
      return s.dataset.settled === "true" && s.dataset.board === b;
    },
    boardOf(cells),
    { timeout: 900_000, polling: 1000 },
  );
  console.log(`  ${name}: 3D board settled on the position (${Math.round((Date.now() - t0) / 1000)}s)`);
}
function expect(what, actual, wanted) {
  if (!actual.includes(wanted)) throw new Error(`${what}: expected "${wanted}", got "${actual}"`);
  console.log(`  ${what}: ${actual.trim()}`);
}

try {
  console.log(`browser-test against ${pageUrl}`);
  const red = await open("red", { width: 900, height: 600 });
  await red.waitForSelector("text=Pull up a chair", { timeout: 120_000 });
  const code = `bt${Math.floor(Math.random() * 1e9)}`;
  await red.check('input[name="table-visibility"][value="code"]');
  await red.fill("#create-code", code);
  await red.click('button[data-create-table="p1"]');
  await red.waitForSelector("text=Waiting for an opponent", { timeout: 120_000 });
  const id = (await red.locator(".table-badge").innerText()).match(/#(\d+)/)[1];
  console.log(`  red: created protected table ${id}`);

  const yellow = await open("yellow", { width: 390, height: 760 });
  const seat = `button[data-join-table-id="${id}"][data-join-table="p2"]`;
  await yellow.waitForSelector(seat, { timeout: 120_000 });
  await yellow.click(seat);
  await yellow.fill(".duel-code-input", code);
  await yellow.click("[data-code-join]");

  await myTurn(red);
  await red.keyboard.press("4"); // key: column 4
  await myTurn(yellow);
  expect("yellow sees", await lastMove(yellow), "Red dropped into column 4");
  await yellow.keyboard.press("2"); // key: column 2
  await myTurn(red);
  expect("red sees", await lastMove(red), "Yellow dropped into column 2");
  // A click in the middle of the free area is column 4 of the 3D board.
  const mid = await red.evaluate(() => {
    const p = document.querySelector(".panel").getBoundingClientRect();
    const h = document.querySelector("header").getBoundingClientRect();
    return { x: (p.right + window.innerWidth) / 2, y: (h.bottom + window.innerHeight) / 2 };
  });
  await red.mouse.move(mid.x, mid.y);
  await red.mouse.click(mid.x, mid.y);
  const third = [
    [3, "R"],
    [1, "Y"],
    [10, "R"],
  ];
  await settled(red, "red", third);
  await settled(yellow, "yellow", third);
  await shot(red, "1-red-midgame");
  await shot(yellow, "1-yellow-midgame");

  await myTurn(yellow);
  expect("yellow sees", await lastMove(yellow), "Red dropped into column 4");
  await yellow.click('.c4-col[data-col="1"]'); // panel button: column 2
  await myTurn(red);
  await red.mouse.move(2, 598);
  await red.keyboard.press("ArrowRight"); // shows the ghost over column 4
  await red.keyboard.press("ArrowRight"); // column 5
  await red.keyboard.press("ArrowLeft"); // column 4
  await red.keyboard.press("Enter");
  await myTurn(yellow);
  expect("yellow sees", await lastMove(yellow), "Red dropped into column 4");
  await yellow.keyboard.press("2");
  await myTurn(red);
  await red.keyboard.press("4"); // the fourth Red disc in column 4

  await red.waitForSelector(".verdict", { timeout: 120_000 });
  await yellow.waitForSelector(".verdict", { timeout: 120_000 });
  expect("red's verdict", await red.locator(".verdict").innerText(), "YOU WIN");
  expect("yellow's verdict", await yellow.locator(".verdict").innerText(), "YOU LOSE");
  const final = [
    [3, "R"],
    [10, "R"],
    [17, "R"],
    [24, "R"],
    [1, "Y"],
    [8, "Y"],
    [15, "Y"],
  ];
  await settled(red, "red", final);
  await settled(yellow, "yellow", final);
  await red.waitForTimeout(3000);
  await shot(red, "2-red-win");
  await shot(yellow, "2-yellow-lose");

  await red.click("button[data-rematch]");
  await yellow.click("button[data-rematch]");
  await myTurn(red);
  await settled(red, "red", []); // the old discs fell out through the slider
  await red.click("button[data-leave]");
  await red.click("[data-confirm-yes]");
  await yellow.waitForSelector("text=Your opponent walked away", { timeout: 120_000 });
  console.log("  rematch started; red forfeited; yellow saw the walk-away");
  await yellow.click("button[data-leave]");
  if (errors.length) throw new Error(`page errors:\n${errors.join("\n")}`);
  console.log("BROWSER-TEST PASSED");
} catch (e) {
  console.error(`BROWSER-TEST FAILED: ${e.message}`);
  process.exitCode = 1;
} finally {
  await browser.close();
  served?.server.close();
}
