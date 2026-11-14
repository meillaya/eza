#!/usr/bin/env bash
# Bundle the built client and the static sources into one publishable,
# content-addressed asset tree under static/:
#
#   static/asset-manifest.json     logical name -> served path, build id,
#                                  shell refs, and the service-worker precache
#   static/app/app.<sha8>.wasm     the compiled Miso client
#   static/app/ghc_wasm_jsffi.<sha8>.js
#   static/app/index.<sha8>.js     generated loader with the hashed URLs
#   static/eza.<sha8>.css          CSS with its font URLs rewritten
#   static/{theme,pwa,auth}.<sha8>.js
#   static/favicon{-fallback}.<sha8>.svg, static/icons/*.<sha8>.png
#   static/fonts/*.<sha8>.woff2
#   static/vendor/browser_wasi_shim.<sha8>/  (content-addressed directory tree)
#   static/index.html              generated shell from static/template/index.html
#   static/sw.js                   generated worker from static/template/sw.js
#   static/manifest.webmanifest    generated from static/template/manifest.webmanifest
#
# The manifest is the single asset list: the server, the shell, and the service
# worker all derive their asset names from it. .gz sidecars are written for
# every text asset (the server serves them with Content-Encoding: gzip).
#
# Usage:
#   bash scripts/bundle-web.sh              # compile (scripts/build-web.sh) then bundle
#   bash scripts/bundle-web.sh --no-build   # bundle an existing static/app only
#
# scripts/build-web.sh calls this with --no-build after its size gates, so the
# normal developer path is still `bash scripts/build-web.sh` (or `devenv shell
# -- web`).
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATIC="$ROOT/static"
APP="$STATIC/app"
STAGE="$ROOT/.dsh-cache/bundle-web-stage"

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *)
      echo "bundle-web: unknown argument: $arg" >&2
      echo "usage: bash scripts/bundle-web.sh [--no-build]" >&2
      exit 2
      ;;
  esac
done

if [[ "$BUILD" == "1" ]]; then
  bash "$ROOT/scripts/build-web.sh" --skip-bundle
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "bundle-web: gzip not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi

# ---------------------------------------------------------------- inputs ---
require_file() {
  if [[ ! -f "$1" ]]; then
    echo "bundle-web: missing $1" >&2
    if [[ "$1" == "$APP/app.wasm" || "$1" == "$APP/ghc_wasm_jsffi.js" ]]; then
      echo "bundle-web: build the client first with 'bash scripts/build-web.sh'" >&2
    fi
    exit 1
  fi
}

require_file "$APP/app.wasm"
require_file "$APP/ghc_wasm_jsffi.js"
require_file "$APP/index.js"
for template in index.html sw.js manifest.webmanifest; do
  require_file "$STATIC/template/$template"
done
for source in eza.css theme.js pwa.js auth.js favicon.svg favicon-fallback.svg; do
  require_file "$STATIC/$source"
done

VENDOR_DIR="$STATIC/vendor/browser_wasi_shim"
if [[ ! -d "$VENDOR_DIR" ]]; then
  echo "bundle-web: missing $VENDOR_DIR" >&2
  exit 1
fi

# ----------------------------------------------------------------- helpers ---
# sha8 prints the first eight hex characters of a file's sha256. Eight hex
# characters is the address width in every generated name: short URLs, with a
# collision across one bundle implausible.
sha8() {
  sha256sum "$1" | cut -d' ' -f1 | cut -c1-8
}

# gzip_asset FILE compresses FILE to FILE.gz atomically. A gzip failure must
# fail the bundle instead of leaving a truncated sidecar that the server would
# serve as Content-Encoding: gzip. -n keeps the mtime and name out of the
# header, so the same input bytes always produce the same sidecar.
gzip_asset() {
  local file="$1"
  local tmp="${file}.gz.tmp.$$"
  if ! gzip -9 -n -c "$file" >"$tmp"; then
    rm -f "$tmp"
    echo "bundle-web: gzip failed for $file" >&2
    exit 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "bundle-web: gzip produced an empty sidecar for $file" >&2
    exit 1
  fi
  mv -f "$tmp" "$file.gz"
}

# stage_copy SRC DEST_REL copies SRC into the staging tree and adds the
# precompressed sidecar for text assets. The hashed name is computed from SRC
# before the copy, so the copy itself must not change the content.
stage_copy() {
  local src="$1"
  local rel="$2"
  local dest="$STAGE/$rel"
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$dest"
  case "$rel" in
    *.woff2 | *.png) : ;;
    *) gzip_asset "$dest" ;;
  esac
}

# replace_in_file FILE PATTERN REPLACEMENT substitutes every PATTERN in FILE.
# The patterns are template tokens and asset paths (no @ or & characters), so @
# is a safe sed delimiter and the replacement needs no escaping.
replace_in_file() {
  local file="$1"
  local pattern="$2"
  local replacement="$3"
  sed -i "s@${pattern}@${replacement}@g" "$file"
}

# url_to_tree_file BASE URL maps a served URL from the manifest to its file in
# a tree that has the static/ layout. /assets/<path> lives at <base>/<path>; a
# fixed route such as /manifest.webmanifest lives at <base>/manifest.webmanifest.
url_to_tree_file() {
  local base="$1"
  local url="$2"
  case "$url" in
    /assets/*) printf '%s/%s' "$base" "${url#/assets/}" ;;
    /*) printf '%s%s' "$base" "$url" ;;
    *)
      echo "bundle-web: invalid manifest path: $url" >&2
      exit 1
      ;;
  esac
}

# ------------------------------------------------------------------ stage ---
rm -rf "$STAGE"
mkdir -p "$STAGE/app" "$STAGE/fonts" "$STAGE/icons" "$STAGE/vendor"

declare -A ASSETS=()
KEYS=()

add_asset() {
  local key="$1"
  local url="$2"
  if [[ -n "${ASSETS[$key]:-}" ]]; then
    echo "bundle-web: duplicate logical asset name: $key" >&2
    exit 1
  fi
  ASSETS["$key"]="$url"
  KEYS+=("$key")
}

# --- the compiled client ----------------------------------------------------
WASM_HASH="$(sha8 "$APP/app.wasm")"
WASM_FILE="app.${WASM_HASH}.wasm"
stage_copy "$APP/app.wasm" "app/$WASM_FILE"
add_asset "app.wasm" "/assets/app/$WASM_FILE"

JSFFI_HASH="$(sha8 "$APP/ghc_wasm_jsffi.js")"
JSFFI_FILE="ghc_wasm_jsffi.${JSFFI_HASH}.js"
stage_copy "$APP/ghc_wasm_jsffi.js" "app/$JSFFI_FILE"
add_asset "app.ghc_wasm_jsffi.js" "/assets/app/$JSFFI_FILE"

# --- vendor WASI shim -------------------------------------------------------
# The shim is a module graph with relative imports, so it is addressed as one
# directory tree: the tree's hash names the directory and the inner file names
# stay as they are. A change to any shim module changes every import URL.
VENDOR_HASH="$(
  cd "$VENDOR_DIR"
  find . -maxdepth 1 -type f -name '*.js' -print0 |
    LC_ALL=C sort -z |
    xargs -0 -r sha256sum |
    sha256sum | cut -d' ' -f1 | cut -c1-8
)"
VENDOR_NAME="browser_wasi_shim.${VENDOR_HASH}"
mkdir -p "$STAGE/vendor/$VENDOR_NAME"
VENDOR_FILES=()
while IFS= read -r vendor_file; do
  vendor_base="$(basename "$vendor_file")"
  cp -f "$vendor_file" "$STAGE/vendor/$VENDOR_NAME/$vendor_base"
  gzip_asset "$STAGE/vendor/$VENDOR_NAME/$vendor_base"
  VENDOR_FILES+=("$vendor_base")
done < <(find "$VENDOR_DIR" -maxdepth 1 -type f -name '*.js' | sort)
add_asset "vendor/browser_wasi_shim" "/assets/vendor/$VENDOR_NAME"

# --- stylesheet and fonts ---------------------------------------------------
HASHED_SUFFIX='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
FONT_NAMES=()
while IFS= read -r font_file; do
  font_base="$(basename "$font_file")"
  font_stem="${font_base%.woff2}"
  font_hash="$(sha8 "$font_file")"
  font_hashed="$font_stem.${font_hash}.woff2"
  stage_copy "$font_file" "fonts/$font_hashed"
  add_asset "fonts/$font_base" "/assets/fonts/$font_hashed"
  FONT_NAMES+=("$font_hashed")
done < <(find "$STATIC/fonts" -maxdepth 1 -type f -name '*.woff2' ! -name "*.$HASHED_SUFFIX.woff2" | sort)

# The published stylesheet must request the addressed font files.
cp -f "$STATIC/eza.css" "$STAGE/eza.css"
for font_file in "$STATIC"/fonts/*.woff2; do
  font_base="$(basename "$font_file")"
  # Skip a hashed font left by an earlier bundle; only the tracked source
  # fonts are inputs, or a second run would hash the hashed copies again.
  if [[ "$font_base" =~ \.[0-9a-f]{8}\.woff2$ ]]; then
    continue
  fi
  replace_in_file "$STAGE/eza.css" "/assets/fonts/$font_base" "${ASSETS["fonts/$font_base"]}"
done
CSS_HASH="$(sha8 "$STAGE/eza.css")"
CSS_FILE="eza.${CSS_HASH}.css"
mv -f "$STAGE/eza.css" "$STAGE/$CSS_FILE"
gzip_asset "$STAGE/$CSS_FILE"
add_asset "eza.css" "/assets/$CSS_FILE"

# --- standalone scripts and icons ------------------------------------------
for script_name in theme pwa auth; do
  script_file="$STATIC/$script_name.js"
  script_hash="$(sha8 "$script_file")"
  script_hashed="$script_name.${script_hash}.js"
  stage_copy "$script_file" "$script_hashed"
  add_asset "$script_name.js" "/assets/$script_hashed"
done

for icon_file in "$STATIC"/favicon.svg "$STATIC"/favicon-fallback.svg; do
  icon_base="$(basename "$icon_file")"
  icon_stem="${icon_base%.svg}"
  icon_hash="$(sha8 "$icon_file")"
  icon_hashed="$icon_stem.${icon_hash}.svg"
  stage_copy "$icon_file" "$icon_hashed"
  add_asset "$icon_base" "/assets/$icon_hashed"
done

ICON_NAMES=()
while IFS= read -r png_file; do
  png_base="$(basename "$png_file")"
  png_stem="${png_base%.png}"
  png_hash="$(sha8 "$png_file")"
  png_hashed="$png_stem.${png_hash}.png"
  stage_copy "$png_file" "icons/$png_hashed"
  add_asset "icons/$png_base" "/assets/icons/$png_hashed"
  ICON_NAMES+=("$png_hashed")
done < <(find "$STATIC/icons" -maxdepth 1 -type f -name '*.png' ! -name "*.$HASHED_SUFFIX.png" | sort)

# The loader template's __EZA_*__ tokens are the only rewritten names; the
# loader keeps the streaming instantiate + arrayBuffer fallback behaviour.
cp -f "$APP/index.js" "$STAGE/loader.js.tmp"
replace_in_file "$STAGE/loader.js.tmp" "__EZA_WASM_FILE__" "$WASM_FILE"
replace_in_file "$STAGE/loader.js.tmp" "__EZA_JSFFI_FILE__" "$JSFFI_FILE"
replace_in_file "$STAGE/loader.js.tmp" "__EZA_VENDOR_DIR__" "$VENDOR_NAME"
if grep -Eq '__EZA_[A-Z_]+__' "$STAGE/loader.js.tmp"; then
  echo "bundle-web: static/app/index.js has an unresolved __EZA_ placeholder" >&2
  exit 1
fi
LOADER_HASH="$(sha8 "$STAGE/loader.js.tmp")"
LOADER_FILE="index.${LOADER_HASH}.js"
mv -f "$STAGE/loader.js.tmp" "$STAGE/app/$LOADER_FILE"
gzip_asset "$STAGE/app/$LOADER_FILE"
add_asset "app.index.js" "/assets/app/$LOADER_FILE"

# The web manifest references the hashed icons but is itself served at the
# fixed /manifest.webmanifest route the browser looks for.
cp -f "$STATIC/template/manifest.webmanifest" "$STAGE/manifest.webmanifest"
replace_in_file "$STAGE/manifest.webmanifest" "{{asset:icons/icon-192.png}}" "${ASSETS["icons/icon-192.png"]}"
replace_in_file "$STAGE/manifest.webmanifest" "{{asset:icons/icon-512.png}}" "${ASSETS["icons/icon-512.png"]}"
if grep -q '{{asset:' "$STAGE/manifest.webmanifest"; then
  echo "bundle-web: static/template/manifest.webmanifest has an unresolved placeholder" >&2
  exit 1
fi
gzip_asset "$STAGE/manifest.webmanifest"
add_asset "manifest.webmanifest" "/manifest.webmanifest"

# render_template TEMPLATE OUTPUT renders {{asset:<logical>}} from ASSETS and
# fails on a placeholder whose logical name the bundle does not define.
render_template() {
  local template="$1"
  local output="$2"
  cp -f "$template" "$output"
  local key
  for key in "${KEYS[@]}"; do
    replace_in_file "$output" "{{asset:${key}}}" "${ASSETS[$key]}"
  done
  if grep -q '{{asset:' "$output"; then
    echo "bundle-web: unresolved {{asset:}} placeholder in $template" >&2
    grep -o '{{asset:[^}]*}}' "$output" | sort -u >&2
    exit 1
  fi
}

render_template "$STATIC/template/index.html" "$STAGE/index.html"
gzip_asset "$STAGE/index.html"

# --- the service worker -----------------------------------------------------
# Generated from its template with the build id and the precache list embedded.
# The server serves this file with no-cache + an ETag of the build id; there is
# no runtime string substitution any more.
SORTED_KEYS=()
while IFS= read -r key; do
  SORTED_KEYS+=("$key")
done < <(printf '%s\n' "${KEYS[@]}" | sort)

INDEX_HASH="$(sha8 "$STAGE/index.html")"
WEBMANIFEST_HASH="$(sha8 "$STAGE/manifest.webmanifest")"
SW_TEMPLATE_HASH="$(sha8 "$STATIC/template/sw.js")"

BUILD_ID="$(
  {
    for key in "${SORTED_KEYS[@]}"; do
      printf '%s\t%s\n' "$key" "${ASSETS[$key]}"
    done
    printf 'index.html\t%s\n' "$INDEX_HASH"
    printf 'manifest.webmanifest\t%s\n' "$WEBMANIFEST_HASH"
    printf 'sw.js-template\t%s\n' "$SW_TEMPLATE_HASH"
  } | sha256sum | cut -d' ' -f1 | cut -c1-16
)"

PRECACHE=(
  "/"
  "${ASSETS["manifest.webmanifest"]}"
  "${ASSETS["eza.css"]}"
  "${ASSETS["theme.js"]}"
  "${ASSETS["pwa.js"]}"
  "${ASSETS["app.index.js"]}"
  "${ASSETS["app.wasm"]}"
  "${ASSETS["app.ghc_wasm_jsffi.js"]}"
  "${ASSETS["favicon.svg"]}"
  "${ASSETS["favicon-fallback.svg"]}"
)
for icon in "${ICON_NAMES[@]}"; do
  PRECACHE+=("/assets/icons/$icon")
done
for vendor in "${VENDOR_FILES[@]}"; do
  PRECACHE+=("/assets/vendor/$VENDOR_NAME/$vendor")
done
for font in "${FONT_NAMES[@]}"; do
  PRECACHE+=("/assets/fonts/$font")
done

precache_json() {
  local first=1
  local item
  printf '['
  for item in "${PRECACHE[@]}"; do
    if [[ "$first" == "1" ]]; then first=0; else printf ', '; fi
    printf '"%s"' "$item"
  done
  printf ']'
}

cp -f "$STATIC/template/sw.js" "$STAGE/sw.js"
replace_in_file "$STAGE/sw.js" "{{build_id}}" "$BUILD_ID"
replace_in_file "$STAGE/sw.js" "{{precache_json}}" "$(precache_json)"
if grep -q '{{' "$STAGE/sw.js"; then
  echo "bundle-web: unresolved placeholder in static/template/sw.js" >&2
  exit 1
fi

# --- write the manifest -----------------------------------------------------
{
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "build_id": "%s",\n' "$BUILD_ID"
  printf '  "assets": {\n'
  first=1
  for key in "${SORTED_KEYS[@]}"; do
    if [[ "$first" == "1" ]]; then first=0; else printf ',\n'; fi
    printf '    "%s": "%s"' "$key" "${ASSETS[$key]}"
  done
  printf '\n  },\n'
  printf '  "shell": {\n'
  first=1
  for shell_key in apple_touch_icon auth_js css favicon favicon_fallback manifest module_js preload_font pwa_js theme_js; do
    case "$shell_key" in
      apple_touch_icon) logical="icons/icon-192.png" ;;
      auth_js) logical="auth.js" ;;
      css) logical="eza.css" ;;
      favicon) logical="favicon.svg" ;;
      favicon_fallback) logical="favicon-fallback.svg" ;;
      manifest) logical="manifest.webmanifest" ;;
      module_js) logical="app.index.js" ;;
      preload_font) logical="fonts/newsreader-300-800.woff2" ;;
      pwa_js) logical="pwa.js" ;;
      theme_js) logical="theme.js" ;;
      *)
        echo "bundle-web: internal error: unknown shell key $shell_key" >&2
        exit 1
        ;;
    esac
    if [[ "$first" == "1" ]]; then first=0; else printf ',\n'; fi
    printf '    "%s": "%s"' "$shell_key" "${ASSETS[$logical]}"
  done
  printf '\n  },\n'
  printf '  "precache": [\n'
  first=1
  for item in "${PRECACHE[@]}"; do
    if [[ "$first" == "1" ]]; then first=0; else printf ',\n'; fi
    printf '    "%s"' "$item"
  done
  printf '\n  ]\n'
  printf '}\n'
} >"$STAGE/asset-manifest.json"

# --- validate before installing --------------------------------------------
for key in "${SORTED_KEYS[@]}"; do
  url="${ASSETS[$key]}"
  file="$(url_to_tree_file "$STAGE" "$url")"
  if [[ ! -f "$file" && ! -d "$file" ]]; then
    echo "bundle-web: manifest path $url has no file at $file" >&2
    exit 1
  fi
done

shell_ref() {
  case "$1" in
    css) printf '%s' "${ASSETS["eza.css"]}" ;;
    theme_js) printf '%s' "${ASSETS["theme.js"]}" ;;
    pwa_js) printf '%s' "${ASSETS["pwa.js"]}" ;;
    module_js) printf '%s' "${ASSETS["app.index.js"]}" ;;
    preload_font) printf '%s' "${ASSETS["fonts/newsreader-300-800.woff2"]}" ;;
    favicon) printf '%s' "${ASSETS["favicon.svg"]}" ;;
    favicon_fallback) printf '%s' "${ASSETS["favicon-fallback.svg"]}" ;;
    apple_touch_icon) printf '%s' "${ASSETS["icons/icon-192.png"]}" ;;
    auth_js) printf '%s' "${ASSETS["auth.js"]}" ;;
    manifest) printf '%s' "${ASSETS["manifest.webmanifest"]}" ;;
    *)
      echo "bundle-web: internal error: unknown shell ref $1" >&2
      exit 1
      ;;
  esac
}

for shell_key in css theme_js pwa_js module_js preload_font favicon favicon_fallback apple_touch_icon; do
  if ! grep -qF "$(shell_ref "$shell_key")" "$STAGE/index.html"; then
    echo "bundle-web: generated index.html does not reference $(shell_ref "$shell_key")" >&2
    exit 1
  fi
done
for shell_key in css theme_js pwa_js module_js; do
  if ! grep -qF "$(shell_ref "$shell_key")" "$STAGE/sw.js"; then
    echo "bundle-web: generated sw.js does not precache $(shell_ref "$shell_key")" >&2
    exit 1
  fi
done
if ! grep -qF "${ASSETS["app.wasm"]}" "$STAGE/sw.js"; then
  echo "bundle-web: generated sw.js does not precache ${ASSETS["app.wasm"]}" >&2
  exit 1
fi
if ! grep -qF "eza-app-shell-$BUILD_ID" "$STAGE/sw.js"; then
  echo "bundle-web: generated sw.js does not carry the build id" >&2
  exit 1
fi

# --- install ----------------------------------------------------------------
# Remove the previous generated tree first so a renamed build id cannot leave
# stale hashed files (or stale gzip sidecars) behind. The tracked sources here
# are static/app/index.js, the plain css/js/svg files, template/ and vendor/.
clean_generated() {
  local hashed='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
  rm -f "$STATIC/index.html" "$STATIC/sw.js" "$STATIC/manifest.webmanifest" "$STATIC/asset-manifest.json"
  rm -f "$STATIC"/*."$hashed".css "$STATIC"/*."$hashed".js "$STATIC"/*."$hashed".svg
  rm -f "$STATIC/fonts"/*."$hashed".woff2 "$STATIC/icons"/*."$hashed".png
  rm -rf "$STATIC/vendor/browser_wasi_shim."*
  rm -f "$APP/build-id"
  find "$STATIC" -type f -name '*.gz' -delete
}
clean_generated
cp -a "$STAGE/." "$STATIC/"
rm -rf "$STAGE"

ASSET_COUNT="${#SORTED_KEYS[@]}"
PRECACHE_COUNT="${#PRECACHE[@]}"
echo "bundle-web: build $BUILD_ID, $ASSET_COUNT assets, $PRECACHE_COUNT precache entries"
echo "bundle-web: manifest static/asset-manifest.json; shell static/index.html; worker static/sw.js"
