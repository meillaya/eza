// Build a load-unpacked extension directory.
//
//   node build.mjs                  copy the no-dependency extension to dist/
//   node build.mjs --with-defuddle  also bundle Defuddle into dist/vendor/
//   node build.mjs --out DIR        write somewhere other than extension/dist/
//
// The copy build works with plain Node: Defuddle is optional, and the popup
// falls back to the built-in DOM extractor when vendor/defuddle-page.js is
// absent. The Defuddle build writes vendor/THIRD-PARTY-NOTICES.txt with the
// license texts of every npm package that contributed an input file to the
// extractor bundle.

import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const withDefuddle = args.includes('--with-defuddle');
const outIndex = args.indexOf('--out');
const outDir = outIndex >= 0 && args[outIndex + 1] ? resolve(root, args[outIndex + 1]) : join(root, 'dist');

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
    const result = await esbuild.build({
      entryPoints: [join(root, 'src', 'defuddle-page.js')],
      outfile: join(outDir, 'vendor', 'defuddle-page.js'),
      absWorkingDir: root,
      bundle: true,
      format: 'iife',
      platform: 'browser',
      target: ['chrome116'],
      minify: true,
      legalComments: 'none',
      banner: { js: '/*! Defuddle bundle — third-party license texts: THIRD-PARTY-NOTICES.txt */' },
      logLevel: 'warning',
      metafile: true,
    });
    const packages = bundledPackages(result.metafile);
    const notices = await bundledNotices(packages);
    await writeFile(join(outDir, 'vendor', 'THIRD-PARTY-NOTICES.txt'), notices);
    console.log('bundled Defuddle ' + pinned + ' into vendor/defuddle-page.js');
    console.log('wrote vendor/THIRD-PARTY-NOTICES.txt (' + packages.length + ' bundled package' + (packages.length === 1 ? '' : 's') + ')');
  }

  await validateOutput(manifest);
  if (withDefuddle) await validateLicenseNotices();
  const shown = relative(process.cwd(), outDir);
  console.log('built ' + (shown.startsWith('..') ? outDir : shown) + ' — load it with chrome://extensions → Load unpacked');
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

/** Every package that contributed an input file to the bundle. @param {object} metafile */
function bundledPackages(metafile) {
  const inputs = (metafile && metafile.inputs) || {};
  const packages = new Set();
  for (const input of Object.keys(inputs)) {
    const parts = input.split(/[\\/]+/);
    const index = parts.lastIndexOf('node_modules');
    if (index < 0 || index + 1 >= parts.length) continue;
    let end = index + 2;
    if (parts[index + 1].startsWith('@')) {
      if (index + 2 >= parts.length) continue;
      end = index + 3;
    }
    packages.add(join(root, ...parts.slice(0, end)));
  }
  return [...packages].sort();
}

/** @param {string[]} packageDirs */
async function bundledNotices(packageDirs) {
  const header = [
    'eza clipper — third-party notices',
    '',
    'Generated by `node build.mjs --with-defuddle`. The optional Defuddle',
    'bundle (vendor/defuddle-page.js) includes the packages listed below. Each',
    'entry records the installed package metadata and the license text shipped',
    'with that package; packages that ship no license file are marked.',
    '',
  ].join('\n');
  const sections = [];
  for (const dir of packageDirs) {
    const pkg = await readJsonMaybe(join(dir, 'package.json'));
    if (!pkg || typeof pkg.name !== 'string') continue;
    const version = typeof pkg.version === 'string' ? pkg.version : '';
    const heading = '## ' + pkg.name + (version ? ' ' + version : '');
    const meta = 'License: ' + (licenseField(pkg) || 'not declared in package.json');
    const files = await licenseFiles(dir);
    let text = '';
    for (const file of files) {
      const body = (await readFile(file, 'utf8')).trim();
      if (!body) continue;
      text += (text ? '\n\n' : '') + '----- ' + relative(dir, file) + ' -----\n\n' + body;
    }
    if (!text) text = 'The installed package ships no license file.';
    sections.push([heading, meta, text].join('\n\n'));
  }
  assert(sections.length > 0, 'no bundled package license notices were found');
  return header + '\n' + sections.join('\n\n---\n\n') + '\n';
}

/** @param {object} pkg */
function licenseField(pkg) {
  if (typeof pkg.license === 'string') return pkg.license;
  if (pkg.license && typeof pkg.license.type === 'string') return pkg.license.type;
  if (Array.isArray(pkg.licenses)) {
    return pkg.licenses
      .map((entry) => (entry && typeof entry.type === 'string' ? entry.type : ''))
      .filter(Boolean)
      .join(', ');
  }
  return '';
}

/** @param {string} dir */
async function licenseFiles(dir) {
  const files = [];
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    const name = entry.name;
    if (entry.isFile() && /^(licen[cs]e|copying|notice)([-._].*)?$/i.test(name)) {
      files.push(join(dir, name));
    } else if (entry.isDirectory() && /^licen[cs]es?$/i.test(name)) {
      const nested = await readdir(join(dir, name), { withFileTypes: true }).catch(() => []);
      for (const child of nested) {
        if (child.isFile()) files.push(join(dir, name, child.name));
      }
    }
  }
  return files.sort();
}

async function validateLicenseNotices() {
  const notices = join(outDir, 'vendor', 'THIRD-PARTY-NOTICES.txt');
  const text = await readFile(notices, 'utf8').catch(() => {
    throw new Error('bundled license notices are missing: ' + relative(process.cwd(), notices));
  });
  assert(/defuddle/i.test(text), 'bundled license notices do not name Defuddle');
  assert(/MIT/i.test(text), 'bundled license notices do not include the Defuddle MIT license');
}

/** @param {string} file */
async function readJson(file) {
  return JSON.parse(await readFile(join(root, file), 'utf8'));
}

/** @param {string} file */
async function readJsonMaybe(file) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return null;
  }
}

/** @param {unknown} condition @param {string} message */
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

main().catch((error) => {
  console.error('build failed: ' + (error instanceof Error ? error.message : error));
  process.exit(1);
});
