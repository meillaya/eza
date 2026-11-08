// Build a load-unpacked extension directory.
//
//   node build.mjs                  copy the no-dependency extension to dist/
//   node build.mjs --with-defuddle  also bundle Defuddle into dist/vendor/
//
// The copy build works with plain Node: Defuddle is optional, and the popup
// falls back to the built-in DOM extractor when vendor/defuddle-page.js is
// absent.

import { cp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const withDefuddle = args.includes('--with-defuddle');
const outIndex = args.indexOf('--out');
const outDir = outIndex >= 0 && args[outIndex + 1] ? join(root, args[outIndex + 1]) : join(root, 'dist');

const ROOT_FILES = [
  'manifest.json',
  'background.js',
  'popup.html',
  'popup.js',
  'options.html',
  'options.js',
  'ui.css',
];
const ROOT_DIRS = ['src'];

async function main() {
  const manifest = await readJson('manifest.json');
  const pkg = await readJson('package.json');
  assert(manifest.manifest_version === 3, 'manifest_version must be 3');
  assert(manifest.version === pkg.version, 'manifest version must match package.json');
  assert(manifest.background && manifest.background.type === 'module', 'background must be an ES module');

  await rm(outDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });

  for (const file of ROOT_FILES) {
    await cp(join(root, file), join(outDir, file));
  }
  for (const directory of ROOT_DIRS) {
    await cp(join(root, directory), join(outDir, directory), { recursive: true });
  }

  if (withDefuddle) {
    let esbuild;
    try {
      esbuild = await import('esbuild');
    } catch {
      throw new Error('Defuddle bundling needs esbuild. Run `npm install` in extension/ first, or build without --with-defuddle.');
    }
    const pinned = (pkg.devDependencies || {}).defuddle;
    assert(typeof pinned === 'string' && /^0\.19\./.test(pinned), 'package.json must pin defuddle 0.19.x');
    const setup = await readJson(join('node_modules', 'defuddle', 'package.json')).catch(() => null);
    assert(setup, 'node_modules/defuddle is missing; run npm install');
    assert(setup.version === pinned, `installed defuddle ${setup.version} does not match the pinned ${pinned}`);
    await mkdir(join(outDir, 'vendor'), { recursive: true });
    await esbuild.build({
      entryPoints: [join(root, 'src', 'defuddle-page.js')],
      outfile: join(outDir, 'vendor', 'defuddle-page.js'),
      bundle: true,
      format: 'iife',
      platform: 'browser',
      target: ['chrome116'],
      minify: true,
      legalComments: 'none',
      logLevel: 'warning',
    });
    console.log('bundled Defuddle ' + pinned + ' into vendor/defuddle-page.js');
  }

  await validateOutput(manifest);
  console.log('built ' + relative(process.cwd(), outDir) + ' — load it with chrome://extensions → Load unpacked');
  if (!existsSync(join(outDir, 'vendor', 'defuddle-page.js'))) {
    console.log('note: no Defuddle bundle; the built-in DOM extractor is used (rebuild with --with-defuddle for Defuddle)');
  }
}

/** @param {object} manifest */
async function validateOutput(manifest) {
  const referenced = new Set();
  for (const file of [manifest.background && manifest.background.service_worker, manifest.action && manifest.action.default_popup, manifest.options_page]) {
    if (file) referenced.add(file);
  }
  for (const file of referenced) {
    if (!file) continue;
    try {
      await stat(join(outDir, file));
    } catch {
      throw new Error('manifest references a missing file: ' + file);
    }
  }
  const htmlFiles = ['popup.html', 'options.html'].filter((file) => existsSync(join(outDir, file)));
  for (const file of htmlFiles) {
    const html = await readFile(join(outDir, file), 'utf8');
    const matches = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((match) => match[1]);
    for (const href of matches) {
      if (/^(https?:|#|data:)/.test(href)) continue;
      const target = join(outDir, href);
      if (!existsSync(target)) throw new Error(file + ' references a missing file: ' + href);
    }
  }
  assert(manifest.permissions.includes('activeTab'), 'activeTab permission is required');
  assert(manifest.optional_host_permissions, 'optional_host_permissions is required for the configured server');
}

/** @param {string} file */
async function readJson(file) {
  return JSON.parse(await readFile(join(root, file), 'utf8'));
}

/** @param {unknown} condition @param {string} message */
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

main().catch((error) => {
  console.error('build failed: ' + (error instanceof Error ? error.message : error));
  process.exit(1);
});
