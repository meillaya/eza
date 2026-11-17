// Version constants shared by the background worker and the page scripts.
// Keep EXTENSION_VERSION in sync with manifest.json, manifest.firefox.json's
// derived build, and package.json; test/check.mjs asserts the group matches.
// Keep DEFUDDLE_VERSION in sync with devDependencies.defuddle in package.json;
// test/check.mjs asserts that pair too.

export const EXTENSION_VERSION = '0.2.0';
export const CLIENT = 'eza-clipper/' + EXTENSION_VERSION;
export const DEFUDDLE_VERSION = '0.19.6';
export const CLIP_API_VERSION = 'v1';
