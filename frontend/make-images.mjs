// Render the page's PNG icons, favicon.ico and the social share card
// (og-image.png) into src/, with Playwright's Chromium. The images are
// committed; run this again from frontend/ only after changing the
// logo or the card:
//
//   node make-images.mjs

import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";

// Playwright as browser-test.mjs finds it: here, or the preinstalled copy.
const require = createRequire(import.meta.url);
const { chromium } = require(require.resolve("playwright", { paths: [process.cwd(), "/opt/node-tools/node_modules"] }));

const logo = readFileSync("src/favicon.svg", "utf8");
const P1 = "#e1464c";
const P2 = "#f3bf3a";

// A finished game for the card: 0 empty, 1 red, 2 yellow; red has four
// on the rising diagonal.
const BOARD = [
  [0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 1, 2, 0, 0],
  [0, 0, 1, 2, 1, 0, 0],
  [0, 1, 2, 2, 2, 0, 0],
  [1, 2, 1, 1, 2, 1, 0],
];

const card = `<!doctype html><html><body style="margin:0">
<div style="width:1200px;height:630px;display:flex;align-items:center;gap:72px;padding:0 80px;box-sizing:border-box;
  font-family:'Avenir Next','Segoe UI',system-ui,sans-serif;color:#eef0f8;
  background:radial-gradient(900px 600px at 8% -6%,rgba(255,164,92,.22),transparent 62%),
    radial-gradient(800px 600px at 96% 18%,rgba(106,136,255,.2),transparent 66%),
    linear-gradient(180deg,#151a33 0%,#0d1022 55%,#08091a 100%)">
  <div style="flex:1">
    <div style="font-size:92px;font-weight:800;line-height:1;letter-spacing:-2px">Connect Four</div>
    <div style="margin-top:28px;font-size:36px;line-height:1.3;color:#9aa2c0">
      Play online against a friend or a bot. Free, no sign-up.</div>
    <div style="margin-top:36px;font-size:24px;color:#f3c25a;letter-spacing:1px">ON THE INTERNET COMPUTER</div>
  </div>
  <div style="display:grid;grid-template-columns:repeat(7,52px);gap:10px;padding:22px;border-radius:28px;
    background:#2443b8;box-shadow:0 30px 60px rgba(0,0,0,.45)">
    ${BOARD.flat()
      .map(
        (c) =>
          `<i style="width:52px;height:52px;border-radius:50%;box-shadow:inset 0 -4px 6px rgba(0,0,0,.3);background:${
            c === 1 ? P1 : c === 2 ? P2 : "#0d1022"
          }"></i>`,
      )
      .join("")}
  </div>
</div></body></html>`;

const browser = await chromium.launch();
const page = await browser.newPage();

async function shoot(html, width, height) {
  await page.setViewportSize({ width, height });
  await page.setContent(html);
  return page.screenshot({ omitBackground: true });
}

const icon = (size) =>
  `<body style="margin:0;background:transparent">${logo.replace("<svg ", `<svg width="${size}" height="${size}" `)}</body>`;

for (const [name, size] of [
  ["apple-touch-icon.png", 180],
  ["icon-192.png", 192],
  ["icon-512.png", 512],
]) {
  writeFileSync(`src/${name}`, await shoot(icon(size), size, size));
}

// favicon.ico: a one-image ICO whose entry is a 32×32 PNG.
const png32 = await shoot(icon(32), 32, 32);
const ico = Buffer.alloc(22);
ico.writeUInt16LE(1, 2); // type: icon
ico.writeUInt16LE(1, 4); // one image
ico.writeUInt8(32, 6); // width
ico.writeUInt8(32, 7); // height
ico.writeUInt16LE(1, 10); // planes
ico.writeUInt16LE(32, 12); // bits per pixel
ico.writeUInt32LE(png32.length, 14);
ico.writeUInt32LE(22, 18); // offset of the image
writeFileSync("src/favicon.ico", Buffer.concat([ico, png32]));

writeFileSync("src/og-image.png", await shoot(card, 1200, 630));

await browser.close();
