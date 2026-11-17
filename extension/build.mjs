// Build the cross-browser extension packages.
//
//   node build.mjs                        build both targets (default)
//   node build.mjs --target chrome        build only Chrome
//   node build.mjs --target firefox       build only Firefox
//   node build.mjs --out DIR              write under DIR instead of extension/dist
//   node build.mjs --with-defuddle        also bundle the optional Defuddle extractor
//   node build.mjs --host-permission P    add a static host permission (E2E test build)
//
// Outputs (relative to --out, default extension/dist):
//
//   chrome/                                 load-unpacked Chrome build
//   firefox/                                Firefox package directory
//   eza-clipper-<version>-chrome.zip        Chrome Web Store upload
//   eza-clipper-<version>-firefox.zip       Firefox Add-ons upload
//
// The plain build needs only Node: no dependencies, no bundler, no remote code
// and no content scripts. The manifest is generated from manifest.json and, for
// Firefox, the manifest.firefox.json overlay: Chrome keeps a service-worker
// background and `minimum_chrome_version`; Firefox gets background.scripts and
// `browser_specific_settings`, and the Chrome-only keys are stripped. The store
// build is the plain build. `--with-defuddle` is a local power-user build and
// is not store-uploadable.
//
// The ZIP writer is deterministic and dependency-free: entries are sorted,
// timestamps are fixed, and the bytes depend only on the input files. The
// tests import buildManifest/validateManifest/makeZip directly.

import { existsSync } from 'node:fs';
import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

import { EXTENSION_VERSION } from './src/version.js';
import { BASE_TITLE } from './src/status.js';

export const ROOT = dirname(fileURLToPath(import.meta.url));
export const TARGETS = ['chrome', 'firefox'];

/** Store-build budgets: the plain package stays a small, auditable download. */
export const MAX_UNPACKED_BYTES = 300 * 1024;
export const MAX_ZIP_BYTES = 150 * 1024;

export const REQUIRED_PERMISSIONS = ['activeTab', 'scripting', 'storage', 'contextMenus', 'tabs'];
export const OPTIONAL_HOST_PERMISSIONS = ['http://*/*', 'https://*/*'];
export const ICON_SIZES = ['16', '32', '48', '128'];
export const COMMAND_IDS = ['add-bookmark', 'add-selection'];

const ROOT_FILES = ['background.js', 'popup.html', 'popup.js', 'options.html', 'options.js', 'ui.css'];
const SKIP_SOURCE_FILES = new Set(['defuddle-page.js']);
const LICENSE_FILE = join(ROOT, '..', 'LICENSE');
const ALLOWED_MANIFEST_KEYS = new Set([
  'manifest_version',
  'name',
  'version',
  'description',
  'short_name',
  'homepage_url',
  'minimum_chrome_version',
  'icons',
  'action',
  'background',
  'options_page',
  'permissions',
  'optional_host_permissions',
  'host_permissions',
  'commands',
  'browser_specific_settings',
]);
const DOS_TIME = 0;
const DOS_DATE = 0x0021; // 1980-01-01, the earliest ZIP date.
const ZIP_FLAG_UTF8 = 0x0800;
const ZIP_METHOD_DEFLATE = 8;
const ZIP_VERSION_NEEDED = 20;
const ZIP_MADE_BY_UNIX = 0x0314;
const ZIP_EXTERNAL_ATTRIBUTES = (0o100644 << 16) >>> 0;

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

/** @param {Uint8Array} data @returns {number} */
export function crc32(data) {
  let c = 0xffffffff;
  for (const byte of data) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** @param {unknown} condition @param {string} message */
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

/** @param {string} file @returns {Promise<any>} */
async function readJson(file) {
  return JSON.parse(await readFile(file, 'utf8'));
}

/** @param {unknown} value @returns {any} */
function deepClone(value) {
  return JSON.parse(JSON.stringify(value));
}

/**
 * Read the PNG IHDR dimensions of an icon.
 * @param {Buffer | Uint8Array} input
 * @returns {{width: number, height: number}}
 */
export function pngSize(input) {
  const data = Buffer.isBuffer(input) ? input : Buffer.from(input);
  assert(data.length >= 24, 'PNG is too short');
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (let i = 0; i < signature.length; i += 1) {
    assert(data[i] === signature[i], 'file is not a PNG');
  }
  assert(data.toString('ascii', 12, 16) === 'IHDR', 'PNG does not start with IHDR');
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
}

/**
 * Build the manifest for one target from the checked-in source manifests.
 * @param {'chrome' | 'firefox'} target
 * @param {{chrome: object, firefox: object, version?: string, hostPermission?: string | null}} source
 * @returns {object}
 */
export function buildManifest(target, source) {
  assert(target === 'chrome' || target === 'firefox', 'target must be chrome or firefox');
  assert(source && source.chrome && source.firefox, 'buildManifest needs the chrome and firefox source manifests');
  const manifest = deepClone(source.chrome);
  delete manifest.license;
  delete manifest.author;
  if (source.version) manifest.version = source.version;
  if (target === 'firefox') {
    // Replace the Chrome background object wholesale: Firefox runs an MV3
    // event page from background.scripts instead of a service worker.
    manifest.background = deepClone(source.firefox.background);
    // Chrome-only keys never reach the Firefox package.
    delete manifest.minimum_chrome_version;
    for (const key of Object.keys(source.firefox)) {
      if (key === 'background') continue;
      manifest[key] = deepClone(source.firefox[key]);
    }
  }
  if (source.hostPermission) manifest.host_permissions = [source.hostPermission];
  else delete manifest.host_permissions;
  return manifest;
}

/**
 * Validate one generated manifest. Throws on the first problem; the build and
 * the static checks both call it, so a store-breaking manifest cannot ship.
 * @param {object} manifest
 * @param {{target?: 'chrome' | 'firefox', version?: string, hostPermission?: string | null}} [options]
 * @returns {true}
 */
export function validateManifest(manifest, options = {}) {
  assert(manifest && typeof manifest === 'object' && !Array.isArray(manifest), 'manifest is not an object');
  const target = options.target || (manifest.browser_specific_settings ? 'firefox' : 'chrome');
  assert(target === 'chrome' || target === 'firefox', 'target must be chrome or firefox');
  for (const key of Object.keys(manifest)) {
    assert(ALLOWED_MANIFEST_KEYS.has(key), 'manifest has an unexpected key: ' + key);
  }
  assert(manifest.manifest_version === 3, 'manifest_version must be 3');
  assert(manifest.name === 'eza clipper', 'name must be "eza clipper"');
  assert(typeof manifest.version === 'string' && /^\d+\.\d+\.\d+$/.test(manifest.version), 'version must be x.y.z');
  if (options.version) assert(manifest.version === options.version, 'version must match src/version.js');
  assert(typeof manifest.description === 'string' && manifest.description.trim().length > 0, 'description is required');
  assert(
    typeof manifest.short_name === 'string' && manifest.short_name.trim().length > 0 && manifest.short_name.length <= 12,
    'short_name (store metadata, at most 12 characters) is required',
  );
  assert(
    typeof manifest.homepage_url === 'string' && /^https?:\/\//.test(manifest.homepage_url),
    'homepage_url (store metadata) must be an http(s) URL',
  );
  assert(manifest.license === undefined, 'the manifest must not carry a license key');

  // Permissions: exactly the documented set, no static host permission unless
  // the E2E build asks for one, and the optional hosts that Options requests.
  assert(Array.isArray(manifest.permissions), 'permissions must be an array');
  assert(
    manifest.permissions.length === REQUIRED_PERMISSIONS.length &&
      REQUIRED_PERMISSIONS.every((permission) => manifest.permissions.includes(permission)),
    'permissions must be exactly ' + REQUIRED_PERMISSIONS.join(', '),
  );
  assert(
    Array.isArray(manifest.optional_host_permissions) &&
      manifest.optional_host_permissions.length === OPTIONAL_HOST_PERMISSIONS.length &&
      OPTIONAL_HOST_PERMISSIONS.every((pattern) => manifest.optional_host_permissions.includes(pattern)),
    'optional_host_permissions must be ' + OPTIONAL_HOST_PERMISSIONS.join(', '),
  );
  if (options.hostPermission) {
    assert(
      Array.isArray(manifest.host_permissions) &&
        manifest.host_permissions.length === 1 &&
        manifest.host_permissions[0] === options.hostPermission,
      'the E2E build must add exactly the requested host permission',
    );
  } else {
    assert(manifest.host_permissions === undefined, 'the store build must not have a static host permission');
  }

  // Icons and action.
  assert(manifest.icons && typeof manifest.icons === 'object', 'icons are required');
  assert(
    ICON_SIZES.every((size) => manifest.icons[size] === 'icons/icon-' + size + '.png'),
    'icons must map 16/32/48/128 to icons/icon-<size>.png',
  );
  assert(manifest.action && manifest.action.default_popup === 'popup.html', 'action.default_popup must be popup.html');
  assert(manifest.action.default_title === BASE_TITLE, 'action.default_title must be "' + BASE_TITLE + '"');
  assert(manifest.options_page === 'options.html', 'options_page must be options.html');
  assert(manifest.content_scripts === undefined, 'the extension must not use content scripts');
  assert(manifest.web_accessible_resources === undefined, 'the extension must not expose web resources');

  // Commands.
  assert(manifest.commands && typeof manifest.commands === 'object', 'commands are required');
  for (const id of COMMAND_IDS) {
    const command = manifest.commands[id];
    assert(command && typeof command === 'object', 'command is missing: ' + id);
    assert(typeof command.description === 'string' && command.description.trim(), 'command ' + id + ' needs a description');
    assert(
      command.suggested_key && typeof command.suggested_key.default === 'string',
      'command ' + id + ' needs a suggested key',
    );
  }

  assert(manifest.background && typeof manifest.background === 'object', 'background is required');
  if (target === 'chrome') {
    assert(manifest.minimum_chrome_version === '116', 'Chrome build must set minimum_chrome_version 116');
    assert(manifest.background.service_worker === 'background.js', 'Chrome background must be the background.js service worker');
    assert(manifest.background.type === 'module', 'Chrome background must be an ES module');
    assert(manifest.background.scripts === undefined, 'Chrome background must not use background.scripts');
    assert(manifest.browser_specific_settings === undefined, 'Chrome manifest must not carry browser_specific_settings');
    assert(JSON.stringify(manifest).includes('"gecko"') === false, 'Chrome manifest must not carry gecko keys');
  } else {
    assert(manifest.minimum_chrome_version === undefined, 'Firefox manifest must not carry minimum_chrome_version');
    assert(manifest.background.service_worker === undefined, 'Firefox background must not use a service worker');
    assert(
      Array.isArray(manifest.background.scripts) &&
        manifest.background.scripts.length === 1 &&
        manifest.background.scripts[0] === 'background.js',
      'Firefox background.scripts must be ["background.js"]',
    );
    assert(manifest.background.type === 'module', 'Firefox background must be an ES module');
    const gecko = manifest.browser_specific_settings && manifest.browser_specific_settings.gecko;
    assert(gecko && typeof gecko === 'object', 'Firefox manifest needs browser_specific_settings.gecko');
    assert(gecko.id === 'eza-clipper@eza.dev', 'gecko.id must be eza-clipper@eza.dev');
    assert(gecko.strict_min_version === '140.0', 'gecko.strict_min_version must be 140.0');
    const collection = gecko.data_collection_permissions;
    assert(collection && typeof collection === 'object', 'gecko.data_collection_permissions is required');
    assert(
      Array.isArray(collection.required) &&
        collection.required.length === 2 &&
        collection.required.includes('browsingActivity') &&
        collection.required.includes('bookmarksInfo'),
      'required data collection must be browsingActivity and bookmarksInfo',
    );
    assert(
      Array.isArray(collection.optional) &&
        collection.optional.length === 1 &&
        collection.optional[0] === 'websiteContent',
      'optional data collection must be websiteContent',
    );
  }
  return true;
}

/**
 * Deterministic, dependency-free ZIP writer.
 *
 * @param {Array<{name: string, data: Buffer | Uint8Array | string}> | Map<string, Buffer | Uint8Array | string>} input
 * @returns {Buffer}
 */
export function makeZip(input) {
  const entries = normalizeZipEntries(input);
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, 'utf8');
    const data = entry.data;
    const compressed = deflateRawSync(data, { level: 9 });
    const checksum = crc32(data);
    assert(data.length <= 0xffffffff, 'ZIP entry is too large: ' + entry.name);
    assert(compressed.length <= 0xffffffff, 'compressed ZIP entry is too large: ' + entry.name);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(ZIP_VERSION_NEEDED, 4);
    local.writeUInt16LE(ZIP_FLAG_UTF8, 6);
    local.writeUInt16LE(ZIP_METHOD_DEFLATE, 8);
    local.writeUInt16LE(DOS_TIME, 10);
    local.writeUInt16LE(DOS_DATE, 12);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, nameBytes, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(ZIP_MADE_BY_UNIX, 4);
    central.writeUInt16LE(ZIP_VERSION_NEEDED, 6);
    central.writeUInt16LE(ZIP_FLAG_UTF8, 8);
    central.writeUInt16LE(ZIP_METHOD_DEFLATE, 10);
    central.writeUInt16LE(DOS_TIME, 12);
    central.writeUInt16LE(DOS_DATE, 14);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(ZIP_EXTERNAL_ATTRIBUTES, 38);
    central.writeUInt32LE(offset, 42);
    centralParts.push(central, nameBytes);

    offset += local.length + nameBytes.length + compressed.length;
  }
  const centralSize = centralParts.reduce((total, part) => total + part.length, 0);
  assert(entries.length <= 0xffff, 'too many ZIP entries');
  assert(offset + centralSize <= 0xffffffff, 'ZIP file too large');
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...localParts, ...centralParts, end]);
}

/**
 * @param {Array<{name: string, data: Buffer | Uint8Array | string}> | Map<string, Buffer | Uint8Array | string>} input
 * @returns {Array<{name: string, data: Buffer}>}
 */
function normalizeZipEntries(input) {
  const raw = input instanceof Map ? [...input.entries()].map(([name, data]) => ({ name, data })) : input;
  assert(Array.isArray(raw) && raw.length > 0, 'makeZip needs at least one file');
  const byName = new Map();
  for (const entry of raw) {
    assert(entry && typeof entry.name === 'string' && entry.name, 'ZIP entry needs a name');
    const name = entry.name.replace(/\\/g, '/');
    assert(!name.startsWith('/'), 'ZIP entry name must be relative: ' + name);
    assert(!name.split('/').includes('..'), 'ZIP entry name must not escape the archive: ' + name);
    assert(!byName.has(name), 'duplicate ZIP entry: ' + name);
    const data = Buffer.isBuffer(entry.data)
      ? entry.data
      : entry.data instanceof Uint8Array
        ? Buffer.from(entry.data)
        : Buffer.from(String(entry.data), 'utf8');
    byName.set(name, data);
  }
  return [...byName.entries()]
    .map(([name, data]) => ({ name, data }))
    .sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
}

/**
 * @param {string} directory
 * @param {string} [prefix]
 * @returns {Promise<string[]>} sorted relative file names
 */
async function walkFiles(directory, prefix = '') {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries.sort((left, right) => (left.name < right.name ? -1 : 1))) {
    const relativeName = prefix ? prefix + '/' + entry.name : entry.name;
    if (entry.isDirectory()) files.push(...(await walkFiles(join(directory, entry.name), relativeName)));
    else files.push(relativeName);
  }
  return files;
}

/**
 * @param {string} target
 * @param {{outBase?: string, withDefuddle?: boolean, hostPermission?: string | null, quiet?: boolean}} [options]
 * @returns {Promise<object>}
 */
export async function buildTarget(target, options = {}) {
  assert(TARGETS.includes(target), 'unknown target: ' + target);
  const outBase = options.outBase ? resolve(options.outBase) : join(ROOT, 'dist');
  const withDefuddle = Boolean(options.withDefuddle);
  const hostPermission = options.hostPermission || null;
  const chrome = await readJson(join(ROOT, 'manifest.json'));
  const firefox = await readJson(join(ROOT, 'manifest.firefox.json'));
  const pkg = await readJson(join(ROOT, 'package.json'));
  assert(pkg.version === EXTENSION_VERSION, 'package.json version must match src/version.js');
  const manifest = buildManifest(target, { chrome, firefox, version: EXTENSION_VERSION, hostPermission });
  validateManifest(manifest, { target, version: EXTENSION_VERSION, hostPermission });

  const defuddle = withDefuddle ? await bundleDefuddle(pkg) : null;
  const targetDir = join(outBase, target);
  await rm(targetDir, { recursive: true, force: true });
  await mkdir(targetDir, { recursive: true });
  await writeOutputFile(targetDir, 'manifest.json', Buffer.from(JSON.stringify(manifest, null, 2) + '\n'));
  for (const file of ROOT_FILES) {
    await writeOutputFile(targetDir, file, await readFile(join(ROOT, file)));
  }
  for (const entry of await readdir(join(ROOT, 'src'), { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.js') || SKIP_SOURCE_FILES.has(entry.name)) continue;
    await writeOutputFile(targetDir, 'src/' + entry.name, await readFile(join(ROOT, 'src', entry.name)));
  }
  for (const size of ICON_SIZES) {
    await writeOutputFile(targetDir, 'icons/icon-' + size + '.png', await readFile(join(ROOT, 'icons', 'icon-' + size + '.png')));
  }
  assert(existsSync(LICENSE_FILE), 'the repository LICENSE file is missing: ' + LICENSE_FILE);
  await writeOutputFile(targetDir, 'LICENSE', await readFile(LICENSE_FILE));
  if (defuddle) {
    await writeOutputFile(targetDir, 'vendor/defuddle-page.js', defuddle.code);
    await writeOutputFile(targetDir, 'vendor/THIRD-PARTY-NOTICES.txt', defuddle.notices);
  }

  const files = await walkFiles(targetDir);
  await validateOutputDirectory(targetDir, manifest, { target, withDefuddle, files });
  const unpackedBytes = await totalBytes(targetDir, files);
  const zipBytes = makeZip(
    await Promise.all(files.map(async (name) => ({ name, data: await readFile(join(targetDir, name)) }))),
  );
  if (!withDefuddle) {
    assert(
      unpackedBytes < MAX_UNPACKED_BYTES,
      'unpacked build is ' + unpackedBytes + ' bytes; the store budget is ' + MAX_UNPACKED_BYTES,
    );
    assert(zipBytes.length < MAX_ZIP_BYTES, 'ZIP is ' + zipBytes.length + ' bytes; the store budget is ' + MAX_ZIP_BYTES);
  }
  const version = manifest.version;
  const zipPath = join(outBase, 'eza-clipper-' + version + '-' + target + '.zip');
  // Drop a stale package from an earlier version for this target.
  for (const entry of await readdir(outBase, { withFileTypes: true })) {
    if (entry.isFile() && /^eza-clipper-.*-chrome\.zip$/.test(entry.name) && target === 'chrome') {
      await rm(join(outBase, entry.name), { force: true });
    }
    if (entry.isFile() && /^eza-clipper-.*-firefox\.zip$/.test(entry.name) && target === 'firefox') {
      await rm(join(outBase, entry.name), { force: true });
    }
  }
  await writeFile(zipPath, zipBytes);
  const summary = {
    target,
    version,
    directory: targetDir,
    zipPath,
    files,
    manifest,
    unpackedBytes,
    zipBytes: zipBytes.length,
    defuddle: withDefuddle,
  };
  if (!options.quiet) {
    console.log(
      'built ' +
        displayPath(targetDir) +
        ' (' +
        files.length +
        ' files, ' +
        formatBytes(unpackedBytes) +
        (withDefuddle ? ', optional Defuddle bundle' : '') +
        ')',
    );
    console.log('zipped ' + displayPath(zipPath) + ' (' + formatBytes(zipBytes.length) + ')');
  }
  return summary;
}

/**
 * @param {string} directory
 * @param {object} manifest
 * @param {{target: string, withDefuddle: boolean, files: string[]}} options
 */
async function validateOutputDirectory(directory, manifest, options) {
  const referenced = new Set();
  if (manifest.background) {
    if (manifest.background.service_worker) referenced.add(manifest.background.service_worker);
    for (const script of manifest.background.scripts || []) referenced.add(script);
  }
  if (manifest.action && manifest.action.default_popup) referenced.add(manifest.action.default_popup);
  if (manifest.options_page) referenced.add(manifest.options_page);
  for (const icon of Object.values(manifest.icons || {})) referenced.add(icon);
  for (const file of referenced) {
    assert(options.files.includes(file), 'manifest references a missing file: ' + file);
  }
  for (const html of ['popup.html', 'options.html']) {
    const source = await readFile(join(directory, html), 'utf8');
    for (const match of source.matchAll(/(?:src|href)="([^"]+)"/g)) {
      const href = match[1];
      if (/^(?:https?:|data:|mailto:|#)/.test(href)) continue;
      const target = href.replace(/^\.\//, '');
      assert(options.files.includes(target), html + ' references a missing file: ' + href);
    }
  }
  for (const size of ICON_SIZES) {
    const data = await readFile(join(directory, 'icons/icon-' + size + '.png'));
    const dimensions = pngSize(data);
    assert(
      dimensions.width === Number(size) && dimensions.height === Number(size),
      'icon-' + size + '.png is ' + dimensions.width + 'x' + dimensions.height,
    );
  }
  assert(options.files.includes('LICENSE'), 'the package must ship the repository LICENSE');
  for (const file of options.files) {
    assert(!file.startsWith('test/'), 'the package must not include tests: ' + file);
    assert(!file.startsWith('node_modules/'), 'the package must not include node_modules: ' + file);
    assert(!file.endsWith('.map'), 'the package must not include source maps: ' + file);
  }
  assert(!options.files.includes('src/defuddle-page.js'), 'the package must not ship the Defuddle entry source');
  if (!options.withDefuddle) {
    assert(!options.files.includes('vendor/defuddle-page.js'), 'the plain build must not include Defuddle');
  } else {
    assert(options.files.includes('vendor/defuddle-page.js'), 'the Defuddle build is missing vendor/defuddle-page.js');
    assert(
      options.files.includes('vendor/THIRD-PARTY-NOTICES.txt'),
      'the Defuddle build is missing vendor/THIRD-PARTY-NOTICES.txt',
    );
  }
}

/**
 * Bundle the optional Defuddle extractor for local use. Store builds skip it.
 * @param {object} pkg
 * @returns {Promise<{code: Buffer, notices: Buffer}>}
 */
async function bundleDefuddle(pkg) {
  let esbuild;
  try {
    esbuild = await import('esbuild');
  } catch {
    throw new Error('Defuddle bundling needs esbuild. Run `npm ci` in extension/ first, or build without --with-defuddle.');
  }
  const pinned = (pkg.devDependencies || {}).defuddle;
  assert(typeof pinned === 'string' && /^0\.19\./.test(pinned), 'package.json must pin defuddle 0.19.x');
  let installed = null;
  try {
    installed = await readJson(join(ROOT, 'node_modules', 'defuddle', 'package.json'));
  } catch {
    installed = null;
  }
  assert(installed, 'node_modules/defuddle is missing; run npm ci');
  assert(installed.version === pinned, 'installed defuddle ' + installed.version + ' does not match the pinned ' + pinned);
  const result = await esbuild.build({
    entryPoints: [join(ROOT, 'src', 'defuddle-page.js')],
    absWorkingDir: ROOT,
    bundle: true,
    write: false,
    format: 'iife',
    platform: 'browser',
    target: ['chrome116'],
    minify: true,
    legalComments: 'none',
    banner: { js: '/*! Defuddle bundle — third-party license texts: THIRD-PARTY-NOTICES.txt */' },
    logLevel: 'warning',
    metafile: true,
  });
  assert(result.outputFiles && result.outputFiles.length === 1, 'esbuild returned no bundle');
  const packages = bundledPackages(result.metafile);
  const notices = await bundledNotices(packages);
  return {
    code: Buffer.from(result.outputFiles[0].contents),
    notices: Buffer.from(notices, 'utf8'),
  };
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
    packages.add(join(ROOT, ...parts.slice(0, end)));
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
    const pkg = await readJsonOrNull(join(dir, 'package.json'));
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

/** @param {string} directory */
async function licenseFiles(directory) {
  const files = [];
  const entries = await readdir(directory, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    const name = entry.name;
    if (entry.isFile() && /^(licen[cs]e|copying|notice)([-._].*)?$/i.test(name)) {
      files.push(join(directory, name));
    } else if (entry.isDirectory() && /^licen[cs]es?$/i.test(name)) {
      const nested = await readdir(join(directory, name), { withFileTypes: true }).catch(() => []);
      for (const child of nested) {
        if (child.isFile()) files.push(join(directory, name, child.name));
      }
    }
  }
  return files.sort();
}

/** @param {string} file */
async function readJsonOrNull(file) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Write one file below the target directory, creating parents as needed.
 * @param {string} directory
 * @param {string} name
 * @param {Buffer} data
 */
async function writeOutputFile(directory, name, data) {
  const file = join(directory, name);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, data);
}

/**
 * @param {string} directory
 * @param {string[]} files
 * @returns {Promise<number>}
 */
async function totalBytes(directory, files) {
  let total = 0;
  for (const file of files) total += (await stat(join(directory, file))).size;
  return total;
}

/** @param {number} bytes @returns {string} */
function formatBytes(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KiB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MiB';
}

/** @param {string} file @returns {string} */
function displayPath(file) {
  const shown = relative(process.cwd(), file);
  return shown.startsWith('..') ? file : shown;
}

/**
 * Parse build arguments. Exported so the tests can cover the E2E build flags
 * without spawning a process.
 * @param {string[]} argv
 * @returns {{target: string, out: string | null, withDefuddle: boolean, hostPermission: string | null}}
 */
export function parseArgs(argv) {
  const options = { target: 'all', out: null, withDefuddle: false, hostPermission: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--with-defuddle') {
      options.withDefuddle = true;
    } else if (arg === '--target' || arg.startsWith('--target=')) {
      options.target = arg.includes('=') ? arg.slice('--target='.length) : requireValue(argv, ++index, '--target');
    } else if (arg === '--out' || arg.startsWith('--out=')) {
      options.out = arg.includes('=') ? arg.slice('--out='.length) : requireValue(argv, ++index, '--out');
    } else if (arg === '--host-permission' || arg.startsWith('--host-permission=')) {
      options.hostPermission = arg.includes('=')
        ? arg.slice('--host-permission='.length)
        : requireValue(argv, ++index, '--host-permission');
    } else if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else {
      throw new Error('unknown build argument: ' + arg);
    }
  }
  assert(['chrome', 'firefox', 'all'].includes(options.target), '--target must be chrome, firefox, or all');
  if (options.hostPermission !== null) {
    assert(
      /^https?:\/\/[^/\s]+\/\*$/.test(options.hostPermission),
      '--host-permission must look like https://host/* or http://host:port/*',
    );
  }
  return options;
}

/** @param {string[]} argv @param {number} index @param {string} flag @returns {string} */
function requireValue(argv, index, flag) {
  const value = argv[index];
  assert(typeof value === 'string' && value.length > 0, flag + ' needs a value');
  return value;
}

/**
 * Build the requested targets.
 * @param {string[]} [argv]
 * @returns {Promise<object[]>}
 */
export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    console.log(
      [
        'usage: node build.mjs [--target chrome|firefox|all] [--out DIR]',
        '                     [--with-defuddle] [--host-permission PATTERN]',
        '',
        'plain build: Chrome and Firefox packages, no dependencies, no remote code',
        'store build: the plain build (extension/dist/chrome and extension/dist/firefox)',
      ].join('\n'),
    );
    return [];
  }
  const outBase = options.out ? resolve(process.cwd(), options.out) : join(ROOT, 'dist');
  const targets = options.target === 'all' ? TARGETS : [options.target];
  const summaries = [];
  for (const target of targets) {
    summaries.push(
      await buildTarget(target, {
        outBase,
        withDefuddle: options.withDefuddle,
        hostPermission: options.hostPermission,
      }),
    );
  }
  if (!options.withDefuddle) {
    console.log('note: the store build is the plain build; --with-defuddle is a local power-user build');
  }
  return summaries;
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : '';
if (invokedPath && invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error('build failed: ' + (error instanceof Error ? error.message : String(error)));
    process.exit(1);
  });
}
