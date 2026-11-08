// eza Defuddle worker.
//
// Runs inside a worker_threads Worker managed by main.mjs. The parent owns the
// JSON-lines protocol, the payload cap, and the 15 s timeout; this module owns
// one extraction. It never opens a socket: Defuddle runs with useAsync:false
// and a fetch override that rejects, so an extractor that tries to fetch a
// remote API fails instead of reaching the network.
//
// Result schema version 1:
//   { id, ok:true, extractor:"defuddle", version, sidecar_version, schema:1,
//     title, author, published, site, description, language, image, favicon,
//     content_markdown, content_text, word_count, parse_time_ms }
//   { id, ok:false, error:{code,message} }

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { parentPort } from 'node:worker_threads';
import { Defuddle } from 'defuddle/node';
import TurndownService from 'turndown';

import {
  absoluteUrl,
  clampText,
  classifyContentType,
  countWords,
  faviconUrl,
  htmlToText,
  looksLikeHtml,
  normalizeContentType,
  wrapPlainText,
} from './html-text.mjs';

/** Version of the JSON result schema. Bump only for a breaking change. */
const RESULT_SCHEMA = 1;

/** Hard caps so a hostile page cannot fill a database column. */
const MAX_MARKDOWN_CHARS = 500000;
const MAX_TEXT_CHARS = 500000;

const SIDECAR_VERSION = readSidecarVersion();
const DEFUDDLE_VERSION = resolveDefuddleVersion();

const turndown = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced',
  bulletListMarker: '-',
  emDelimiter: '_',
});

/** Defuddle options shared by every extraction. */
function defuddleOptions(language) {
  return {
    // Never let an extractor call a third-party API. The fetch override is a
    // second line of defence if a future extractor ignores useAsync.
    useAsync: false,
    fetch: () => Promise.reject(new Error('network access is disabled in the eza sidecar')),
    // Keep content as HTML and put Markdown in contentMarkdown, so the worker
    // can return both shapes from one parse.
    separateMarkdown: true,
    // Boilerplate removal requested by the eza enrichment contract.
    removeHiddenElements: true,
    removeLowScoring: true,
    removeSmallImages: true,
    removeExactSelectors: true,
    removePartialSelectors: true,
    standardize: true,
    removeContentPatterns: true,
    ...(language ? { language } : {}),
  };
}

/**
 * Extract one page. Everything is synchronous inside Defuddle; the parent
 * enforces the timeout by terminating the worker.
 * @param {{id: unknown, html: string, url: string, contentType?: string, charset?: string}} job
 */
async function extract(job) {
  const started = Date.now();
  const contentType = normalizeContentType(job.contentType);
  const kind = classifyContentType(contentType);

  if (kind === 'unsupported') {
    return {
      id: job.id,
      ok: false,
      error: {
        code: 'unsupported_content_type',
        message: 'cannot extract from content type ' + contentType + '; expected text/html, application/xhtml+xml, or text/plain',
      },
    };
  }

  const url = typeof job.url === 'string' ? job.url : '';
  const html = kind === 'text' ? wrapPlainText(job.html) : job.html;

  let result;
  try {
    result = await Defuddle(html, url, defuddleOptions(detectLanguage(job)));
  } catch (error) {
    return {
      id: job.id,
      ok: false,
      error: { code: 'extract_failed', message: `defuddle failed: ${messageOf(error)}` },
    };
  }

  const rawContent = typeof result.content === 'string' ? result.content : '';
  const contentIsHtml = looksLikeHtml(rawContent);

  let markdown = '';
  if (typeof result.contentMarkdown === 'string' && result.contentMarkdown.trim()) {
    markdown = result.contentMarkdown;
  } else if (rawContent) {
    markdown = contentIsHtml ? safeTurndown(rawContent) : rawContent;
  }

  let text = '';
  try {
    text = contentIsHtml ? htmlToText(rawContent) : normalizePlain(rawContent);
  } catch {
    text = normalizePlain(markdown);
  }
  // Some pages produce Markdown but an empty serialized body; always give the
  // server something to index.
  if (!text && markdown) text = normalizePlain(markdown);

  const title = stringOf(result.title);
  const site = stringOf(result.site) || stringOf(result.domain);
  const image = absoluteUrl(result.image, url);

  return {
    id: job.id,
    ok: true,
    extractor: 'defuddle',
    version: DEFUDDLE_VERSION,
    sidecar_version: SIDECAR_VERSION,
    schema: RESULT_SCHEMA,
    title,
    author: stringOf(result.author),
    published: publishedOf(result.published),
    site,
    description: stringOf(result.description),
    language: stringOf(result.language),
    image,
    favicon: faviconUrl(result.favicon, url),
    content_markdown: clampText(markdown.trim(), MAX_MARKDOWN_CHARS),
    content_text: clampText(text, MAX_TEXT_CHARS),
    word_count: wordCountOf(result.wordCount, text),
    parse_time_ms: Math.max(0, Date.now() - started),
  };
}

/**
 * @param {string} html
 * @returns {string}
 */
function safeTurndown(html) {
  try {
    return turndown.turndown(html);
  } catch {
    return htmlToText(html);
  }
}

/**
 * @param {string} text
 * @returns {string}
 */
function normalizePlain(text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t]+/g, ' ')
    .split('\n')
    .map((line) => line.replace(/[ ]+$/g, ''))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** @param {unknown} value @returns {string} */
function stringOf(value) {
  if (typeof value !== 'string') return '';
  return value.replace(/\s+/g, ' ').trim();
}

/** @param {unknown} value @returns {string} */
function publishedOf(value) {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return '';
}

/**
 * @param {unknown} reported
 * @param {string} text
 * @returns {number}
 */
function wordCountOf(reported, text) {
  if (typeof reported === 'number' && Number.isFinite(reported) && reported >= 0) {
    return Math.floor(reported);
  }
  return countWords(text);
}

/**
 * Prefer the document language sent by the server, then Defuddle's metadata.
 * Defuddle only uses the language as an Accept-Language hint and for
 * site-specific extractors; with useAsync:false it is inert but harmless.
 * @param {{charset?: string, language?: string}} job
 * @returns {string}
 */
function detectLanguage(job) {
  if (typeof job.language === 'string' && job.language.trim()) return job.language.trim();
  return '';
}

/**
 * Read the installed Defuddle version once. Falls back to the pinned version
 * from package.json, then to "unknown", so a hoisting oddity cannot break the
 * worker.
 * @returns {string}
 */
function resolveDefuddleVersion() {
  try {
    const require = createRequire(import.meta.url);
    const entry = require.resolve('defuddle');
    const pkgPath = join(dirname(entry), '..', 'package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    if (typeof pkg.version === 'string' && pkg.version) return pkg.version;
  } catch {
    // Fall through to the sidecar bundle's declared version.
  }
  const pinned = readSidecarVersion();
  return pinned === 'unknown' ? 'unknown' : pinned;
}

/**
 * @returns {string}
 */
function readSidecarVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    return typeof pkg.version === 'string' ? pkg.version : 'unknown';
  } catch {
    return 'unknown';
  }
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

if (!parentPort) {
  process.stderr.write('eza sidecar worker must be started by main.mjs\n');
  process.exit(1);
}

parentPort.on('message', (job) => {
  if (!job || typeof job !== 'object') {
    parentPort.postMessage({
      id: null,
      ok: false,
      error: { code: 'bad_request', message: 'extraction job must be an object' },
    });
    return;
  }
  extract(job)
    .then((result) => parentPort.postMessage(result))
    .catch((error) => {
      parentPort.postMessage({
        id: job.id ?? null,
        ok: false,
        error: { code: 'extract_failed', message: messageOf(error) },
      });
    });
});
