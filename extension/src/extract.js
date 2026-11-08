// Minimal in-page extractor.
//
// `extractPage` is serialized by chrome.scripting.executeScript and runs in
// the page's main world, so it must be completely self-contained: every helper
// is nested, nothing is imported or captured from this module's scope.
//
// It is the fallback when the optional Defuddle bundle is not built. The
// background worker sets source/client/template fields afterwards; this
// function only reports what the page says.

export function extractPage() {
  const startedAt = Date.now();
  const SKIP_TAGS = new Set([
    'script',
    'style',
    'noscript',
    'template',
    'iframe',
    'svg',
    'canvas',
    'video',
    'audio',
    'form',
    'button',
    'input',
    'select',
    'textarea',
    'nav',
  ]);
  const CONTENT_SELECTORS = [
    'article',
    'main',
    '[role="main"]',
    '.post-content',
    '.article-body',
    '.entry-content',
    '.article-content',
    '#content',
  ];
  const MAX_MARKDOWN = 800000;
  const MAX_HTML = 1500000;
  const MAX_SELECTION = 100000;

  function normalizeSpace(value) {
    return String(value == null ? '' : value)
      .replace(/\s+/g, ' ')
      .trim();
  }

  function absoluteUrl(value) {
    if (!value || typeof value !== 'string') return '';
    const raw = value.trim();
    if (!raw || raw.startsWith('data:')) return '';
    try {
      const url = new URL(raw, document.location.href);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
      return url.toString();
    } catch {
      return '';
    }
  }

  function metaContent(names) {
    for (const name of names) {
      const element = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
      if (!element) continue;
      const value = element.getAttribute('content');
      if (value && value.trim()) return value.trim();
    }
    return '';
  }

  function linkHref(relValues) {
    for (const rel of relValues) {
      const element = document.querySelector('link[rel~="' + rel + '"]');
      if (!element) continue;
      const href = element.getAttribute('href');
      if (href && href.trim()) return absoluteUrl(href);
    }
    return '';
  }

  function jsonLdFields() {
    const fields = {};
    try {
      const scripts = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
      const nodes = [];
      for (const script of scripts) {
        let parsed = null;
        try {
          parsed = JSON.parse(script.textContent || 'null');
        } catch {
          continue;
        }
        const queue = Array.isArray(parsed) ? parsed : [parsed];
        while (queue.length) {
          const node = queue.shift();
          if (!node || typeof node !== 'object') continue;
          nodes.push(node);
          if (Array.isArray(node['@graph'])) queue.push(...node['@graph']);
        }
      }
      const wanted = ['article', 'newsarticle', 'blogposting', 'techarticle', 'report', 'webpage'];
      const isWanted = (node) => {
        const types = String(node['@type'] || '')
          .split(',')
          .map((type) => type.trim().toLowerCase());
        return types.some((type) => wanted.includes(type));
      };
      const node = nodes.find(isWanted) || nodes[0];
      if (!node) return fields;
      const nameOf = (value) => {
        if (typeof value === 'string') return value;
        if (value && typeof value === 'object') return normalizeSpace(value.name || value['@id'] || '');
        return '';
      };
      const imageOf = (value) => {
        if (typeof value === 'string') return value;
        if (Array.isArray(value) && value.length) return nameOf(value[0]);
        if (value && typeof value === 'object') return normalizeSpace(value.url || '');
        return '';
      };
      fields.headline = normalizeSpace(node.headline || node.name || '');
      fields.description = normalizeSpace(node.description || '');
      fields.author = nameOf(node.author);
      fields.site = nameOf(node.publisher);
      fields.published = normalizeSpace(node.datePublished || node.dateCreated || '');
      fields.image = imageOf(node.image);
      fields.language = normalizeSpace(node.inLanguage || '');
    } catch {
      return {};
    }
    return fields;
  }

  function isHidden(element) {
    // Only style-based checks: extracted nodes are clones detached from the
    // page, so every element would report a zero-size bounding box.
    try {
      if (element.hidden || element.getAttribute('aria-hidden') === 'true') return true;
      const style = window.getComputedStyle(element);
      return Boolean(style && (style.display === 'none' || style.visibility === 'hidden'));
    } catch {
      return false;
    }
  }

  function cleanClone(root) {
    const clone = root.cloneNode(true);
    const junkSelector = [
      'script',
      'style',
      'noscript',
      'template',
      'iframe',
      'svg',
      'canvas',
      'form',
      'button',
      'input',
      'select',
      'textarea',
      'nav',
      'footer',
      'aside',
      '[aria-hidden="true"]',
      '[hidden]',
      '.advertisement',
      '.ad',
      '.ads',
      '.promo',
      '.newsletter',
      '.related',
      '.share',
      '.social',
      '.comments',
      '.comment',
      '.sidebar',
      '.cookie',
    ].join(',');
    clone.querySelectorAll(junkSelector).forEach((element) => element.remove());
    return clone;
  }

  function inlineMarkdown(node) {
    let output = '';
    const children = Array.from(node.childNodes || []);
    for (const child of children) {
      if (child.nodeType === 3) {
        output += String(child.nodeValue || '').replace(/[ \t\r\n]+/g, ' ');
        continue;
      }
      if (child.nodeType !== 1) continue;
      const tag = child.tagName.toLowerCase();
      if (SKIP_TAGS.has(tag)) continue;
      if (tag === 'br') {
        output += '\n';
        continue;
      }
      const inner = inlineMarkdown(child);
      if (tag === 'strong' || tag === 'b') {
        output += inner.trim() ? '**' + inner.trim() + '**' : inner;
      } else if (tag === 'em' || tag === 'i') {
        output += inner.trim() ? '_' + inner.trim() + '_' : inner;
      } else if (tag === 'code') {
        output += '`' + normalizeSpace(inner) + '`';
      } else if (tag === 'a') {
        const href = absoluteUrl(child.getAttribute('href'));
        const text = normalizeSpace(inner);
        output += href && text ? '[' + text + '](' + href + ')' : inner;
      } else if (tag === 'img') {
        const src = absoluteUrl(child.getAttribute('src') || child.getAttribute('data-src'));
        const alt = normalizeSpace(child.getAttribute('alt'));
        if (src) output += '![' + alt + '](' + src + ')';
      } else {
        output += inner;
      }
    }
    return output;
  }

  function serializeList(element, ordered) {
    const items = Array.from(element.children || []).filter(
      (child) => child.tagName && child.tagName.toLowerCase() === 'li',
    );
    return items
      .map((item, index) => {
        const marker = ordered ? String(index + 1) + '.' : '-';
        const text = inlineMarkdown(item)
          .replace(/\n+/g, ' ')
          .trim();
        return text ? marker + ' ' + text : '';
      })
      .filter(Boolean)
      .join('\n');
  }

  function serializeElement(element) {
    const tag = element.tagName ? element.tagName.toLowerCase() : '';
    if (!tag || SKIP_TAGS.has(tag)) return '';
    if (isHidden(element)) return '';
    if (/^h[1-6]$/.test(tag)) {
      const text = inlineMarkdown(element).replace(/\n+/g, ' ').trim();
      return text ? '#'.repeat(Number(tag[1])) + ' ' + text : '';
    }
    if (tag === 'p') {
      const text = inlineMarkdown(element).trim();
      return text;
    }
    if (tag === 'blockquote') {
      const text = inlineMarkdown(element).trim();
      if (!text) return '';
      return text
        .split('\n')
        .map((line) => '> ' + line.trim())
        .join('\n');
    }
    if (tag === 'pre') {
      const text = String(element.textContent || '').replace(/\r\n?/g, '\n').trim();
      return text ? '```\n' + text + '\n```' : '';
    }
    if (tag === 'ul' || tag === 'ol') {
      return serializeList(element, tag === 'ol');
    }
    if (tag === 'li') {
      const text = inlineMarkdown(element).replace(/\n+/g, ' ').trim();
      return text ? '- ' + text : '';
    }
    if (tag === 'figure') {
      const image = element.querySelector('img');
      const caption = element.querySelector('figcaption');
      const parts = [];
      if (image) {
        const src = absoluteUrl(image.getAttribute('src') || image.getAttribute('data-src'));
        const alt = normalizeSpace(image.getAttribute('alt'));
        if (src) parts.push('![' + alt + '](' + src + ')');
      }
      if (caption) {
        const captionText = inlineMarkdown(caption).trim();
        if (captionText) parts.push('*' + captionText + '*');
      }
      return parts.join('\n\n');
    }
    if (tag === 'hr') return '---';
    if (tag === 'table') {
      const rows = Array.from(element.querySelectorAll('tr'));
      return rows
        .map((row) => {
          const cells = Array.from(row.querySelectorAll('th,td')).map((cell) =>
            inlineMarkdown(cell).replace(/\n+/g, ' ').trim(),
          );
          return cells.filter(Boolean).join(' | ');
        })
        .filter(Boolean)
        .join('\n');
    }
    return serializeBlocks(element);
  }

  function serializeBlocks(root) {
    const blocks = [];
    const children = Array.from(root.childNodes || []);
    let inlineRun = '';
    const flush = () => {
      const text = inlineRun.trim();
      if (text) blocks.push(text);
      inlineRun = '';
    };
    for (const child of children) {
      if (child.nodeType === 3) {
        inlineRun += String(child.nodeValue || '');
        continue;
      }
      if (child.nodeType !== 1) continue;
      const tag = child.tagName.toLowerCase();
      if (SKIP_TAGS.has(tag)) continue;
      const block = serializeElement(child);
      if (!block) continue;
      // A block that renders inline content (p, heading) is its own block;
      // anything nested already joined its children with blank lines.
      flush();
      blocks.push(block);
    }
    flush();
    return blocks.join('\n\n');
  }

  function markdownToText(markdown) {
    return markdown
      .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/^#{1,6}\s+/gm, '')
      .replace(/^>\s?/gm, '')
      .replace(/^```[^`]*$/gm, '')
      .replace(/[*_`~]/g, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  function pickContentRoot() {
    let best = null;
    let bestLength = 0;
    for (const selector of CONTENT_SELECTORS) {
      const element = document.querySelector(selector);
      if (!element) continue;
      const length = normalizeSpace(element.textContent).length;
      if (length > bestLength) {
        best = element;
        bestLength = length;
      }
    }
    if (best && bestLength > 200) return best;
    if (document.body) return document.body;
    return document.documentElement;
  }

  const jsonLd = jsonLdFields();
  const contentRoot = pickContentRoot();
  const cleanedClone = cleanClone(contentRoot);
  let markdown = normalizeMarkdown(serializeBlocks(cleanedClone));
  if (markdown.length > MAX_MARKDOWN) markdown = markdown.slice(0, MAX_MARKDOWN);
  let text = markdownToText(markdown);
  if (text.length > MAX_MARKDOWN) text = text.slice(0, MAX_MARKDOWN);
  let html = '';
  try {
    html = cleanedClone.innerHTML || '';
    if (html.length > MAX_HTML) html = html.slice(0, MAX_HTML);
  } catch {
    html = '';
  }

  let selection = '';
  try {
    selection = normalizeSpace(window.getSelection() ? window.getSelection().toString() : '');
    if (selection.length > MAX_SELECTION) selection = selection.slice(0, MAX_SELECTION);
  } catch {
    selection = '';
  }

  const pageUrl = document.location.href;
  const title =
    metaContent(['og:title', 'twitter:title']) || jsonLd.headline || normalizeSpace(document.title) || pageUrl;
  const site = metaContent(['og:site_name']) || jsonLd.site || (document.location.hostname || '');
  const author = metaContent(['author', 'article:author', 'twitter:creator']) || jsonLd.author;
  const description =
    metaContent(['og:description', 'description', 'twitter:description']) || jsonLd.description;
  const language = normalizeSpace(document.documentElement.lang) || metaContent(['og:locale']) || jsonLd.language;
  const published =
    metaContent(['article:published_time', 'date', 'datePublished', 'og:published_time']) || jsonLd.published;
  const image = absoluteUrl(metaContent(['og:image', 'twitter:image', 'image']) || jsonLd.image);
  const canonical = linkHref(['canonical']) || absoluteUrl(metaContent(['og:url'])) || pageUrl;
  let favicon = linkHref(['icon', 'shortcut', 'apple-touch-icon']);
  if (!favicon) {
    try {
      const fallback = new URL('/favicon.ico', pageUrl);
      favicon = fallback.protocol === 'http:' || fallback.protocol === 'https:' ? fallback.toString() : '';
    } catch {
      favicon = '';
    }
  }

  return {
    url: pageUrl,
    title: normalizeSpace(title),
    content_markdown: markdown,
    content_text: text,
    content_html: html,
    selection,
    tags: [],
    template_id: null,
    source: 'extension',
    client: 'eza-clipper/' + '0.1.0',
    captured_at: Math.floor(Date.now() / 1000),
    metadata: {
      author: normalizeSpace(author),
      site: normalizeSpace(site),
      published: normalizeSpace(published),
      description: normalizeSpace(description),
      language: normalizeSpace(language),
      image,
      favicon,
      canonical_url: canonical,
      extractor: 'minimal-dom',
      extractor_version: '1',
      word_count: text ? text.split(/\s+/).filter(Boolean).length : 0,
      parse_time_ms: Math.max(0, Date.now() - startedAt),
    },
  };

  function normalizeMarkdown(value) {
    return String(value || '')
      .replace(/\r\n?/g, '\n')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }
}
