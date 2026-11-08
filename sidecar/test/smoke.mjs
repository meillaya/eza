// End-to-end smoke test for the extraction sidecar.
//
// Spawns `node src/main.mjs`, feeds JSON lines on stdin, and asserts the
// response contract. It is deliberately dependency-free so it can run right
// after `npm ci` (or even before, once Defuddle is installed) and needs no
// network. Exits non-zero on the first failed assertion.
//
//   cd sidecar && npm test

import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const fixture = await readFile(join(here, 'fixtures', 'article.html'), 'utf8');
const MAX_HTML_BYTES = 5 * 1024 * 1024;

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

/** @param {string} name @param {unknown} condition */
function checkTruthy(name, condition) {
  const pass = Boolean(condition);
  if (!pass) {
    failures += 1;
    console.error(`not ok - ${name}`);
  } else {
    console.log(`ok - ${name}`);
  }
}

const child = spawn(process.execPath, [join(here, '..', 'src', 'main.mjs')], {
  cwd: join(here, '..'),
  stdio: ['pipe', 'pipe', 'pipe'],
});

let stdoutBuffer = '';
const responses = [];
const waiters = [];

child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  stdoutBuffer += chunk;
  let newline = stdoutBuffer.indexOf('\n');
  while (newline >= 0) {
    const line = stdoutBuffer.slice(0, newline);
    stdoutBuffer = stdoutBuffer.slice(newline + 1);
    newline = stdoutBuffer.indexOf('\n');
    if (!line.trim()) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      failures += 1;
      console.error(`not ok - sidecar wrote non-JSON to stdout: ${line.slice(0, 200)} (${error})`);
      continue;
    }
    const waiter = waiters.shift();
    if (waiter) waiter(parsed);
    else responses.push(parsed);
  }
});

let stderrText = '';
child.stderr.setEncoding('utf8');
child.stderr.on('data', (chunk) => {
  stderrText += chunk;
});

/** @param {object} request @returns {Promise<any>} */
function requestLine(request) {
  return rawLine(JSON.stringify(request));
}

/** @param {string} line @returns {Promise<any>} */
function rawLine(line) {
  const response = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out waiting for a response to: ${line.slice(0, 120)}`)), 30000);
    waiters.push((value) => {
      clearTimeout(timer);
      resolve(value);
    });
  });
  child.stdin.write(line + '\n');
  return response;
}

const url = 'https://example.press/ledger/the-quiet-ledger';

try {
  // 1. Valid page.
  const first = await requestLine({
    id: 'first',
    html: fixture,
    url,
    contentType: 'text/html; charset=utf-8',
    charset: 'utf-8',
  });
  check('valid page: id echoed', first.id, 'first');
  check('valid page: ok', first.ok, true);
  check('valid page: extractor', first.extractor, 'defuddle');
  check('valid page: schema', first.schema, 1);
  checkTruthy('valid page: version looks pinned', /^0\.19\.\d+$/.test(first.version));
  check('valid page: title', first.title, 'The Quiet Ledger');
  check('valid page: author', first.author, 'Ada Lovelace');
  check('valid page: published', first.published, '2024-03-01T10:00:00Z');
  check('valid page: site', first.site, 'The Example Press');
  check('valid page: language', first.language, 'en');
  checkTruthy('valid page: description', String(first.description).startsWith('A short test article'));
  check('valid page: image absolutized', first.image, 'https://example.press/images/ledger-cover.jpg');
  check('valid page: favicon absolutized', first.favicon, 'https://example.press/favicon-32.png');
  checkTruthy('valid page: markdown has body', String(first.content_markdown).includes('The ledger sat open'));
  checkTruthy('valid page: markdown has heading', String(first.content_markdown).includes('What a ledger is for'));
  checkTruthy('valid page: text has body', String(first.content_text).includes('A cat crossed the sill'));
  checkTruthy('valid page: nav removed', !String(first.content_text).includes('Letters'));
  checkTruthy('valid page: footer removed', !String(first.content_text).includes('All rights reserved'));
  checkTruthy('valid page: hidden promo removed', !String(first.content_text).includes('free tote bag'));
  checkTruthy('valid page: word count positive', first.word_count > 20);
  checkTruthy('valid page: parse_time_ms is a number', typeof first.parse_time_ms === 'number' && first.parse_time_ms >= 0);

  // 2. Malformed JSON must not kill the process.
  const badJson = await rawLine('{this is not json');
  check('bad json: ok', badJson.ok, false);
  check('bad json: code', badJson.error?.code, 'bad_json');

  // 3. Blank lines are ignored; the next request still works.
  const afterBlank = await requestLine({ id: 'second', html: '<html><body><p>Hello sidecar.</p></body></html>', url: 'https://example.press/hello' });
  check('blank line does not desync: id', afterBlank.id, 'second');
  check('blank line does not desync: ok', afterBlank.ok, true);

  // 4. Unsupported content type is a clean error.
  const pdf = await requestLine({ id: 'pdf', html: fixture, url, contentType: 'application/pdf' });
  check('pdf: ok', pdf.ok, false);
  check('pdf: code', pdf.error?.code, 'unsupported_content_type');

  // 5. Non-http URL is rejected.
  const badUrl = await requestLine({ id: 'bad-url', html: fixture, url: 'file:///etc/passwd' });
  check('bad url: ok', badUrl.ok, false);
  check('bad url: code', badUrl.error?.code, 'bad_request');

  // 6. Oversize HTML is rejected without wedging the worker.
  const oversize = await requestLine({
    id: 'oversize',
    html: 'x'.repeat(MAX_HTML_BYTES + 1),
    url,
  });
  check('oversize: ok', oversize.ok, false);
  check('oversize: code', oversize.error?.code, 'payload_too_large');

  // 7. text/plain is wrapped and extracted.
  const plain = await requestLine({
    id: 'plain',
    html: 'A plain text page.\n\nIt has two paragraphs.',
    url: 'https://example.press/plain.txt',
    contentType: 'text/plain',
  });
  check('plain text: ok', plain.ok, true);
  checkTruthy('plain text: body', String(plain.content_markdown).includes('A plain text page'));

  // 8. The worker is still healthy after all of that.
  const final = await requestLine({ id: 'final', html: fixture, url });
  check('recovery: ok', final.ok, true);
} catch (error) {
  failures += 1;
  console.error(`not ok - ${error instanceof Error ? error.message : error}`);
}

child.stdin.end();
await new Promise((resolve) => {
  const timer = setTimeout(() => {
    child.kill('SIGKILL');
    resolve();
  }, 5000);
  child.on('exit', () => {
    clearTimeout(timer);
    resolve();
  });
});

if (child.exitCode !== null && child.exitCode !== 0) {
  failures += 1;
  console.error(`not ok - sidecar exited with code ${child.exitCode}`);
}

// 9. A timeout is reported as an error line and the process survives, proving
// the worker thread is terminated instead of wedging the sidecar.
try {
  const timeoutChild = spawn(process.execPath, [join(here, '..', 'src', 'main.mjs')], {
    cwd: join(here, '..'),
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, EZA_SIDECAR_TIMEOUT_MS: '1000' },
  });
  const timeoutResponse = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('the timeout case never answered')), 30000);
    let buffer = '';
    timeoutChild.stdout.setEncoding('utf8');
    timeoutChild.stdout.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      clearTimeout(timer);
      resolve(JSON.parse(buffer.slice(0, newline)));
    });
    // A deliberately heavy page: Defuddle needs more than the one-second
    // timeout to parse several megabytes of nested markup.
    const heavyHtml =
      '<html><body><article>' +
      '<p>Some words in a paragraph about a quiet ledger and a cat.</p>'.repeat(60000) +
      '</article></body></html>';
    timeoutChild.stdin.write(JSON.stringify({ id: 'timeout', html: heavyHtml, url }) + '\n');
  });
  check('timeout: ok', timeoutResponse.ok, false);
  check('timeout: code', timeoutResponse.error?.code, 'timeout');
  timeoutChild.stdin.end();
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      timeoutChild.kill('SIGKILL');
      resolve();
    }, 5000);
    timeoutChild.on('exit', () => {
      clearTimeout(timer);
      resolve();
    });
  });
} catch (error) {
  failures += 1;
  console.error(`not ok - timeout case: ${error instanceof Error ? error.message : error}`);
}
if (failures > 0) {
  console.error(`\n${failures} smoke check(s) failed`);
  if (stderrText) console.error('sidecar stderr:\n' + stderrText);
  process.exit(1);
}
console.log(`\nall smoke checks passed (sidecar stderr: ${stderrText.trim().split('\n').length} line(s))`);
