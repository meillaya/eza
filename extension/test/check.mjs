// Static checks for the extension: manifest shape, version pins, syntax, and a
// few security invariants. Runs with plain Node and no dependencies:
//
//   npm test
//
// It does not launch a browser; load the built extension in Chrome/Chromium
// for the end-to-end check in README.md.

import { readFile, readdir, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
let failures = 0;

/** @param {string} name @param {unknown} actual @param {unknown} expected */
function check(name, actual, expected) {
  const pass = JSON.stringify(actual) === JSON.stringify(expected);
  if (!pass) {
    failures += 1;
    console.error(`not ok - ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  } else {
    console.log(`ok - ${name}`);
  }
}

/** @param {string} name @param {boolean} condition */
function checkTruthy(name, condition) {
  if (!condition) {
    failures += 1;
    console.error(`not ok - ${name}`);
  } else {
    console.log(`ok - ${name}`);
  }
}

async function readText(file) {
  return readFile(join(root, file), 'utf8');
}

async function main() {
  const manifest = JSON.parse(await readText('manifest.json'));
  const pkg = JSON.parse(await readText('package.json'));
  const versionSource = await readText('src/version.js');

  check('manifest_version', manifest.manifest_version, 3);
  check('name', manifest.name, 'eza clipper');
  check('version matches package.json', manifest.version, pkg.version);
  check('background is an ES module', manifest.background && manifest.background.type, 'module');
  check('action popup', manifest.action && manifest.action.default_popup, 'popup.html');
  check('options page', manifest.options_page, 'options.html');
  check('permissions', manifest.permissions, ['activeTab', 'scripting', 'storage', 'contextMenus']);
  checkTruthy('optional host permissions cover http(s)', Array.isArray(manifest.optional_host_permissions) && manifest.optional_host_permissions.includes('https://*/*'));
  checkTruthy('no static host permission (origin is granted at runtime)', manifest.host_permissions === undefined);
  checkTruthy('commands define save-page and save-selection', Boolean(manifest.commands && manifest.commands['save-page'] && manifest.commands['save-selection']));
  check('no content_scripts (uses scripting.executeScript)', manifest.content_scripts, undefined);

  const defuddlePin = (pkg.devDependencies || {}).defuddle;
  checkTruthy('defuddle pinned to 0.19.x', typeof defuddlePin === 'string' && /^0\.19\.\d+$/.test(defuddlePin));
  checkTruthy('version.js exposes the same defuddle pin', versionSource.includes("DEFUDDLE_VERSION = '" + defuddlePin + "'"));
  checkTruthy('esbuild is a devDependency', Boolean((pkg.devDependencies || {}).esbuild));

  // Every referenced local file must exist.
  const files = [
    'background.js',
    'popup.js',
    'options.js',
    'popup.html',
    'options.html',
    'ui.css',
    'src/config.js',
    'src/api.js',
    'src/extract.js',
    'src/defuddle-page.js',
    'src/version.js',
  ];
  for (const file of files) {
    try {
      await stat(join(root, file));
      console.log(`ok - ${file} exists`);
    } catch {
      failures += 1;
      console.error(`not ok - ${file} is missing`);
    }
  }

  // Syntax check every JavaScript file.
  const jsFiles = ['background.js', 'popup.js', 'options.js', 'build.mjs', 'test/check.mjs'];
  for (const directory of ['src']) {
    for (const entry of await readdir(join(root, directory))) {
      if (entry.endsWith('.js') || entry.endsWith('.mjs')) jsFiles.push(join(directory, entry));
    }
  }
  for (const file of jsFiles) {
    try {
      execFileSync(process.execPath, ['--check', join(root, file)], { stdio: 'pipe' });
      console.log(`ok - node --check ${file}`);
    } catch (error) {
      failures += 1;
      console.error(`not ok - node --check ${file}\n${error && error.stderr ? String(error.stderr) : error}`);
    }
  }

  // The in-page extractor must be self-contained (no imports/exports beyond
  // the single function) because Chrome serializes the function source.
  const extractSource = await readText('src/extract.js');
  checkTruthy('extractPage is exported for executeScript', /export\s+function\s+extractPage\s*\(/.test(extractSource));
  checkTruthy('extractPage does not import anything', !/^\s*import\s/m.test(extractSource));
  checkTruthy('extract.js starts with a documentation comment', extractSource.trim().startsWith('//'));

  // Security invariants: token only in the Authorization header, never in a
  // URL or a log line.
  const apiSource = await readText('src/api.js');
  checkTruthy('api.js sends the bearer token in a header', /Authorization:\s*'Bearer '\s*\+\s*config\.captureToken/.test(apiSource));
  const allSources = (
    await Promise.all(['background.js', 'popup.js', 'options.js', 'src/config.js', 'src/api.js', 'src/extract.js'].map(readText))
  ).join('\n');
  checkTruthy('no console logging of secrets or requests', !/console\.(log|debug|info)\(/.test(allSources));
  checkTruthy('no token in a URL query', !/[?&](?:token|access_token|key)=/.test(allSources));
  checkTruthy('token never put in localStorage', !/localStorage/.test(allSources));
  checkTruthy('no token in chrome.tabs.create URLs', !/tabs\.create\([^)]*captureToken/.test(allSources));

  // Every getElementById in a page script must exist in its HTML.
  const pagePairs = [
    ['popup.js', 'popup.html'],
    ['options.js', 'options.html'],
  ];
  for (const [script, html] of pagePairs) {
    const js = await readText(script);
    const markup = await readText(html);
    const ids = new Set([...js.matchAll(/getElementById\('([^']+)'\)/g)].map((match) => match[1]));
    for (const id of ids) {
      checkTruthy(script + ' id #' + id + ' exists in ' + html, markup.includes('id="' + id + '"'));
    }
  }

  if (failures > 0) {
    console.error(`\n${failures} extension check(s) failed`);
    process.exit(1);
  }
  console.log('\nall extension checks passed');
  console.log('next: npm run build:defuddle && load ' + relative(process.cwd(), join(root, 'dist')) + ' in chrome://extensions');
}

main().catch((error) => {
  console.error('extension check crashed: ' + (error instanceof Error ? error.stack : error));
  process.exit(1);
});
