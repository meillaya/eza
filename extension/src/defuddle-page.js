// Optional Defuddle extractor, bundled by build.mjs and injected into the
// page's main world as vendor/defuddle-page.js.
//
// The bundle exposes one promise on window.__ezaClipperDefuddle; the
// background worker injects this file, then reads that promise from a second
// executeScript call. Everything stays local: useAsync is false and fetch is
// replaced with a rejecting stub, so no extractor can reach a third-party API.
//
// It clones the document before parsing so the page itself is never mutated.

import Defuddle from 'defuddle/full';
import { CLIENT, DEFUDDLE_VERSION } from './version.js';

const GLOBAL_KEY = '__ezaClipperDefuddle';
const MAX_MARKDOWN = 800000;
const MAX_HTML = 1500000;
const MAX_SELECTION = 100000;

function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

function normalizeSpace(value) {
  return String(value == null ? '' : value)
    .replace(/\s+/g, ' ')
    .trim();
}

function absoluteUrl(value, base) {
  if (!value || typeof value !== 'string') return '';
  const raw = value.trim();
  if (!raw || raw.startsWith('data:')) return '';
  try {
    const url = new URL(raw, base || document.location.href);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
    return url.toString();
  } catch {
    return '';
  }
}

function htmlToText(html) {
  if (!html) return '';
  try {
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    const body = parsed && parsed.body;
    if (!body) return '';
    const withBreaks = (body.innerHTML || '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/(p|div|section|article|li|h[1-6]|blockquote|pre|tr|figcaption)>/gi, '\n');
    const container = document.createElement('div');
    container.innerHTML = withBreaks;
    const text = container.textContent || '';
    return text.replace(/\r\n?/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  } catch {
    return '';
  }
}

function looksLikeHtml(value) {
  return typeof value === 'string' && /<\/?[a-z][a-z0-9-]*(\s[^<>]*)?>/i.test(value);
}

function readCanonical(pageUrl) {
  try {
    const link = document.querySelector('link[rel~="canonical"]');
    if (link) {
      const href = link.getAttribute('href');
      if (href) return absoluteUrl(href, pageUrl) || pageUrl;
    }
  } catch {
    // Fall through to the page URL.
  }
  return pageUrl;
}

function readFavicon(pageUrl) {
  try {
    const link = document.querySelector('link[rel~="icon"]');
    if (link) {
      const href = link.getAttribute('href');
      const resolved = absoluteUrl(href, pageUrl);
      if (resolved) return resolved;
    }
    const fallback = new URL('/favicon.ico', pageUrl);
    return fallback.protocol === 'http:' || fallback.protocol === 'https:' ? fallback.toString() : '';
  } catch {
    return '';
  }
}

(() => {
  const pageUrl = document.location.href;
  const startedAt = Date.now();
  const promise = Promise.resolve()
    .then(() => {
      let selection = '';
      try {
        selection = normalizeSpace(window.getSelection() ? window.getSelection().toString() : '');
      } catch {
        selection = '';
      }
      if (selection.length > MAX_SELECTION) selection = selection.slice(0, MAX_SELECTION);

      const clone = document.cloneNode(true);
      const options = {
        useAsync: false,
        fetch: () => Promise.reject(new Error('network access is disabled in the eza clipper')),
        separateMarkdown: true,
        removeHiddenElements: true,
        removeLowScoring: true,
        removeSmallImages: true,
        removeExactSelectors: true,
        removePartialSelectors: true,
        standardize: true,
        removeContentPatterns: true,
        url: pageUrl,
      };
      const result = new Defuddle(clone, options).parse();

      let html = '';
      if (typeof result.content === 'string' && looksLikeHtml(result.content)) {
        html = result.content;
        if (html.length > MAX_HTML) html = html.slice(0, MAX_HTML);
      }
      let markdown = '';
      if (typeof result.contentMarkdown === 'string' && result.contentMarkdown.trim()) {
        markdown = result.contentMarkdown;
      } else if (typeof Defuddle.createMarkdownContent === 'function' && html) {
        try {
          markdown = Defuddle.createMarkdownContent(html, pageUrl);
        } catch {
          markdown = '';
        }
      }
      if (!markdown && html) markdown = htmlToText(html);
      markdown = markdown.trim();
      if (markdown.length > MAX_MARKDOWN) markdown = markdown.slice(0, MAX_MARKDOWN);

      let text = htmlToText(html);
      if (!text) text = normalizeSpace(markdown).replace(/[#*_`>~]/g, '');
      if (text.length > MAX_MARKDOWN) text = text.slice(0, MAX_MARKDOWN);

      const title = normalizeSpace(result.title) || normalizeSpace(document.title) || pageUrl;
      const site = normalizeSpace(result.site) || document.location.hostname || '';
      return {
        ok: true,
        url: pageUrl,
        title,
        content_markdown: markdown,
        content_text: text,
        content_html: html,
        selection,
        tags: [],
        template_id: null,
        source: 'extension',
        client: CLIENT,
        captured_at: Math.floor(Date.now() / 1000),
        metadata: {
          author: normalizeSpace(result.author),
          site,
          published: normalizeSpace(result.published),
          description: normalizeSpace(result.description),
          language: normalizeSpace(result.language),
          image: absoluteUrl(result.image, pageUrl),
          favicon: absoluteUrl(result.favicon, pageUrl) || readFavicon(pageUrl),
          canonical_url: readCanonical(pageUrl),
          extractor: 'defuddle',
          extractor_version: DEFUDDLE_VERSION,
          word_count:
            typeof result.wordCount === 'number' && result.wordCount >= 0
              ? Math.floor(result.wordCount)
              : text.split(/\s+/).filter(Boolean).length,
          parse_time_ms: Math.max(0, Date.now() - startedAt),
        },
      };
    })
    .catch((error) => ({ ok: false, error: messageOf(error) }));

  window[GLOBAL_KEY] = promise;
})();
