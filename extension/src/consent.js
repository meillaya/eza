// Firefox data collection consent for page-text capture.
//
// The Firefox manifest declares `websiteContent` as an optional data
// collection permission. Firefox >= 140 exposes the granted categories through
// permissions.getAll().data_collection and asks the user for the optional ones
// from permissions.request({data_collection: [...]}) inside a user gesture.
// Chromium has no data collection permission: getAll() has no such key and
// page text is allowed once the host permission exists.
//
// "Add bookmark" never needs this consent. Only "Add page text" and
// "Add selection" do, because only they read the page and send its content.

import { getApi } from './browser.js';

/** The optional Firefox data collection category used for page text. */
export const WEBSITE_CONTENT = 'websiteContent';

/** Explanation shown after the user denies the optional permission. */
export const PAGE_TEXT_DENIED_REASON =
  'Page text is disabled because Firefox did not grant access to website content. Add bookmark still works; allow the optional permission to capture page text.';

/** Explanation while the optional permission has not been requested yet. */
export const PAGE_TEXT_PENDING_REASON =
  'Page text needs an optional Firefox permission before it can be captured. Add bookmark does not.';

/**
 * @typedef {{supported: boolean, granted: boolean, reason: string}} PageTextCapability
 * - supported: the browser exposes optional data collection permissions
 * - granted: `websiteContent` is currently granted (or not needed)
 * - reason: user-facing explanation when it is not granted
 */

/**
 * Read the current page-text capability without prompting.
 * @returns {Promise<PageTextCapability>}
 */
export async function getPageTextCapability() {
  const api = getApi();
  let all;
  try {
    all = await api.permissions.getAll();
  } catch {
    // A browser without the permissions API cannot gate page text; allow it.
    return { supported: false, granted: true, reason: '' };
  }
  const categories = all && Array.isArray(all.data_collection) ? all.data_collection : null;
  if (!categories) {
    // Chromium (or a Firefox build without data collection permissions).
    return { supported: false, granted: true, reason: '' };
  }
  if (categories.includes(WEBSITE_CONTENT)) {
    return { supported: true, granted: true, reason: '' };
  }
  return { supported: true, granted: false, reason: PAGE_TEXT_PENDING_REASON };
}

/**
 * Ask for the optional page-text permission.
 *
 * Call this only when getPageTextCapability() reported `supported && !granted`,
 * and make it the first await in the user-gesture handler: the permission
 * request must be issued inside the gesture. The text fields in the runtime
 * message already carry whether the request is needed, so no earlier storage
 * or permission read is required.
 * @returns {Promise<PageTextCapability>}
 */
export async function requestPageTextConsent() {
  const api = getApi();
  try {
    const granted = await api.permissions.request({ data_collection: [WEBSITE_CONTENT] });
    if (granted) return { supported: true, granted: true, reason: '' };
    return { supported: true, granted: false, reason: PAGE_TEXT_DENIED_REASON };
  } catch {
    // The request form is Firefox-specific. If the browser does not know it,
    // fall back to the non-prompting capability read (Chromium allows text).
    const capability = await getPageTextCapability();
    if (!capability.supported) return capability;
    return { supported: true, granted: false, reason: PAGE_TEXT_DENIED_REASON };
  }
}

/**
 * True when page text may be read and sent to the server.
 * @param {PageTextCapability} capability
 * @returns {boolean}
 */
export function pageTextAllowed(capability) {
  return Boolean(capability && capability.granted);
}
