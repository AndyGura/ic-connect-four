// Bundle src/app.js (which imports connect-four-plugin.js and every
// duel-game-core/@icp-sdk module) into dist/app.js, then copy the static
// assets. icp.yaml deploys dist/ only.
import * as esbuild from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';

const watch = process.argv.includes('--watch');
const outdir = 'dist';

rmSync(outdir, { recursive: true, force: true });
mkdirSync(outdir, { recursive: true });

const buildOptions = {
  entryPoints: ['src/app.js'],
  bundle: true,
  outfile: `${outdir}/app.js`,
  format: 'esm',
  target: 'es2022',
  sourcemap: true,
  minify: true, // three.js is most of the bundle
  logLevel: 'info',
};

if (watch) {
  const ctx = await esbuild.context(buildOptions);
  await ctx.watch();
  console.log('watching for changes...');
} else {
  await esbuild.build(buildOptions);
}

for (const [from, to] of [
  ['src/index.html', `${outdir}/index.html`],
  ['src/style.css', `${outdir}/style.css`],
  ['src/_headers', `${outdir}/_headers`], // CSP and caching, applied by the asset canister
  // Search engines and link previews: see ../make-images.mjs for the images.
  ...['robots.txt', 'sitemap.xml', 'site.webmanifest', 'favicon.ico', 'favicon.svg', 'apple-touch-icon.png',
    'icon-192.png', 'icon-512.png', 'og-image.png'].map((f) => [`src/${f}`, `${outdir}/${f}`]),
  ['node_modules/@research-ag/duel-game-core/style.css', `${outdir}/duel-game-core.css`],
]) {
  cpSync(from, to, { recursive: true });
}
