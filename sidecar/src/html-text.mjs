// Pure text/URL helpers for the eza extraction sidecar.
//
// These helpers turn Defuddle's HTML output into plain text and resolve
// relative metadata URLs. They use linkedom so the same code runs in the
// worker without a browser. No helper here performs I/O or a network call.

import { parseHTML } from 'linkedom';

/** Element names that should start a new paragraph in extracted text. */
const BLOCK_TAGS = new Set([
  'address',
  'article',
  'aside',
  'blockquote',
  'dd',
  'details',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
]);

/** Elements whose whole text content is dropped from plain text. */
const DROP_TAGS = new Set(['script', 'style', 'template', 'noscript', 'svg', 'iframe']);

/**
 * Convert an HTML fragment to readable plain text.
 * Block boundaries become blank lines, list items keep a marker, and
 * whitespace collapses only inside a paragraph.
 * @param {string} html
 * @returns {string}
 */
export function htmlToText(html) {
  if (typeof html !== 'string' || html.length === 0) return '';
  let body;
  try {
    const parsed = parseHTML('<!doctype html><html><body>' + html + '</body></html>');
    body = parsed.document.body;
  } catch {
    return '';
  }
  if (!body) return '';
  const out = [];
  walk(body, out);
  return normalizeText(out.join(''));
}

/**
 * @param {any} node
 * @param {string[]} out
 */
function walk(node, out) {
  if (!node) return;
  const nodeType = node.nodeType;
  if (nodeType === 3) {
    // Text node.
    out.push(node.nodeValue || '');
    return;
  }
  if (nodeType !== 1) {
    // Comments, document nodes: visit children only.
    const children = node.childNodes ? Array.from(node.childNodes) : [];
    for (const child of children) walk(child, out);
    return;
  }
  const tag = String(node.tagName || '').toLowerCase();
  if (DROP_TAGS.has(tag)) return;
  if (tag === 'br') {
    out.push('\n');
    return;
  }
  if (tag === 'pre') {
    const text = node.textContent || '';
    if (text.trim()) {
      out.push('\n\n' + text.replace(/\r\n?/g, '\n').trimEnd() + '\n\n');
    }
    return;
  }
  const block = BLOCK_TAGS.has(tag);
  if (block) out.push('\n\n');
  if (tag === 'li') out.push('- ');
  const children = node.childNodes ? Array.from(node.childNodes) : [];
  for (const child of children) walk(child, out);
  if (block) out.push('\n\n');
}

/**
 * Collapse intra-paragraph whitespace while keeping paragraph breaks.
 * @param {string} text
 * @returns {string}
 */
export function normalizeText(text) {
  return text
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')
    .replace(/[ \t\f\v\u00a0]+/g, ' ')
    .split('\n')
    .map((line) => line.replace(/[ ]+$/g, ''))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * Absolute URL for a possibly-relative metadata value. Data URLs are dropped.
 * @param {unknown} value
 * @param {string} base
 * @returns {string}
 */
export function absoluteUrl(value, base) {
  if (typeof value !== 'string') return '';
  const trimmed = value.trim();
  if (!trimmed || trimmed.startsWith('data:')) return '';
  try {
    const resolved = new URL(trimmed, base || undefined);
    if (resolved.protocol !== 'http:' && resolved.protocol !== 'https:') return '';
    return resolved.toString();
  } catch {
    return '';
  }
}

/**
 * Fall back to the page's /favicon.ico when the page declares no icon.
 * @param {unknown} value
 * @param {string} pageUrl
 * @returns {string}
 */
export function faviconUrl(value, pageUrl) {
  const declared = absoluteUrl(value, pageUrl);
  if (declared) return declared;
  try {
    const page = new URL(pageUrl);
    if (page.protocol !== 'http:' && page.protocol !== 'https:') return '';
    return page.origin + '/favicon.ico';
  } catch {
    return '';
  }
}

/**
 * Hard cap for a stored content field. The server caps again before a write.
 * @param {string} text
 * @param {number} max
 * @returns {string}
 */
export function clampText(text, max) {
  if (typeof text !== 'string') return '';
  if (text.length <= max) return text;
  return text.slice(0, max) + '\n\n[truncated by eza extractor]';
}

/**
 * @param {string} text
 * @returns {number}
 */
export function countWords(text) {
  if (typeof text !== 'string') return 0;
  let count = 0;
  for (const word of text.split(/\s+/)) {
    if (word) count += 1;
  }
  return count;
}

/**
 * True when a content string looks like an HTML fragment rather than
 * Markdown or plain text (Defuddle returns either depending on options).
 * @param {string} value
 * @returns {boolean}
 */
export function looksLikeHtml(value) {
  if (typeof value !== 'string') return false;
  return /<\/?[a-z][a-z0-9-]*(\s[^<>]*)?>/i.test(value);
}

/**
 * HTML-escape a plain-text document so it can be passed to Defuddle.
 * @param {string} text
 * @returns {string}
 */
export function wrapPlainText(text) {
  const escaped = String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
  return '<!doctype html><html><body><article><pre>' + escaped + '</pre></article></body></html>';
}

/** Content types this sidecar can extract from. */
const HTML_TYPES = new Set(['text/html', 'application/xhtml+xml']);

/**
 * Normalize the content type header to lower case without parameters.
 * @param {unknown} value
 * @returns {string}
 */
export function normalizeContentType(value) {
  if (typeof value !== 'string') return 'text/html';
  const base = value.split(';')[0].trim().toLowerCase();
  return base || 'text/html';
}

/**
 * @param {unknown} contentType
 * @returns {'html' | 'text' | 'unsupported'}
 */
export function classifyContentType(contentType) {
  const type = normalizeContentType(contentType);
  if (HTML_TYPES.has(type)) return 'html';
  if (type === 'text/plain') return 'text';
  return 'unsupported';
}
