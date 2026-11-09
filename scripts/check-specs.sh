#!/usr/bin/env bash
# Check the formal specifications under spec/.
#
# What runs here:
#   1. every schema, example, and bad document is valid JSON;
#   2. TLC model-checks spec/MultiUser.tla and spec/Extensions.tla;
#   3. the example documents carry the fields the bounded plan requires;
#   4. the bad documents violate one of those requirements.
#
# TLC discovery order:
#   - $TLA2TOOLS_JAR (path to tla2tools.jar; java must be on PATH),
#   - the `tlc` command (devenv provides it from pkgs.tlaplus),
#   - share/java/tla2tools.jar in a nix profile,
#   - `nix build nixpkgs#tlaplus` as a last resort.
#
# The deeper check between these documents and the Haskell decoders is a
# planned server test; this script only proves JSON shape and the bounded
# model's invariants. See spec/README.md for the scope.
set -euo pipefail
shopt -s nullglob

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
spec_dir="$repo_root/spec"
schema_dir="$spec_dir/schema"
examples_dir="$spec_dir/examples"
bad_dir="$spec_dir/bad"
meta_root="$(mktemp -d "${TMPDIR:-/tmp}/eza-check-specs.XXXXXX")"
trap 'rm -rf "$meta_root"' EXIT

log() { printf 'check-specs: %s\n' "$*"; }
die() {
    printf 'check-specs: error: %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Required files
# ---------------------------------------------------------------------------

required_files=(
    "$spec_dir/MultiUser.tla"
    "$spec_dir/MultiUser.cfg"
    "$spec_dir/Extensions.tla"
    "$spec_dir/Extensions.cfg"
    "$spec_dir/README.md"
    "$schema_dir/view.schema.json"
    "$schema_dir/webhook.schema.json"
    "$examples_dir/graph-view.json"
    "$examples_dir/ledger-view.json"
    "$examples_dir/webhook.json"
    "$bad_dir/unknown-kind.json"
    "$bad_dir/bad-schema.json"
    "$bad_dir/bad-color.json"
    "$bad_dir/too-many-groups.json"
    "$bad_dir/webhook-unknown-event.json"
)
for file in "${required_files[@]}"; do
    [[ -r "$file" ]] || die "missing required file: ${file#"$repo_root"/}"
done

command -v jq >/dev/null 2>&1 || die "jq not found in PATH; run inside 'devenv shell' or install jq"

# ---------------------------------------------------------------------------
# Locate TLC. Prefer $TLA2TOOLS_JAR, then the devenv-provided tlc command, then
# a jar from a nix profile, then a nix build of the pinned package.
# ---------------------------------------------------------------------------

tlc_cmd=()

use_tla_jar() {
    local jar="$1"
    [[ -r "$jar" ]] || die "tla2tools.jar not readable: $jar"
    command -v java >/dev/null 2>&1 || die "found $jar but java is not on PATH"
    TLA2TOOLS_JAR="$jar"
    tlc_cmd=(java -XX:+UseParallelGC -cp "$jar" tlc2.TLC)
    log "TLC jar: $jar"
}

find_tla_jar() {
    local candidate="" jar profile
    if [[ -n "${TLA2TOOLS_HOME:-}" ]]; then
        for jar in "$TLA2TOOLS_HOME/tla2tools.jar" "$TLA2TOOLS_HOME/share/java/tla2tools.jar"; do
            if [[ -r "$jar" ]]; then
                candidate="$jar"
                break
            fi
        done
    fi
    if [[ -z "$candidate" ]]; then
        local profiles=("$HOME/.nix-profile" /nix/var/nix/profiles/default /run/current-system/sw)
        if [[ -n "${NIX_PROFILES:-}" ]]; then
            # NIX_PROFILES is a space-separated list of profile directories.
            read -r -a extra_profiles <<<"${NIX_PROFILES}"
            profiles+=("${extra_profiles[@]}")
        fi
        for profile in "${profiles[@]}"; do
            if [[ -r "$profile/share/java/tla2tools.jar" ]]; then
                candidate="$profile/share/java/tla2tools.jar"
                break
            fi
        done
    fi
    [[ -n "$candidate" ]] && printf '%s' "$candidate"
}

tlc_hint="TLC not found. Run inside 'devenv shell' (pkgs.tlaplus provides tlc), or set TLA2TOOLS_JAR to tla2tools.jar with java on PATH."

if [[ -n "${TLA2TOOLS_JAR:-}" ]]; then
    use_tla_jar "$TLA2TOOLS_JAR"
elif command -v tlc >/dev/null 2>&1; then
    log "TLC command: $(command -v tlc)"
    tlc_cmd=(tlc)
elif jar="$(find_tla_jar)" && [[ -n "$jar" ]]; then
    use_tla_jar "$jar"
elif command -v nix >/dev/null 2>&1; then
    log "TLC not on PATH; trying 'nix build nixpkgs#tlaplus' (this may need network)"
    if out="$(nix build --no-link --print-out-paths 'nixpkgs#tlaplus' 2>/dev/null)" && [[ -r "$out/share/java/tla2tools.jar" ]]; then
        use_tla_jar "$out/share/java/tla2tools.jar"
    else
        die "$tlc_hint"
    fi
else
    die "$tlc_hint"
fi

# ---------------------------------------------------------------------------
# TLA+ model checking
# ---------------------------------------------------------------------------

run_tlc() {
    local module="$1"
    local config="$spec_dir/$module.cfg"
    local source="$spec_dir/$module.tla"
    local meta="$meta_root/$module"
    local output="$meta_root/$module.tlc.log"

    log "TLC: $module"
    if ! (cd "$spec_dir" && "${tlc_cmd[@]}" -cleanup -metadir "$meta" -config "$config" "$source") >"$output" 2>&1; then
        cat "$output" >&2
        die "TLC failed for $module (full output above)"
    fi
    if ! grep -q "No error has been found" "$output"; then
        cat "$output" >&2
        die "TLC did not report a clean run for $module"
    fi
    local states
    states="$(grep -oE '[0-9,]+ distinct states found' "$output" | tail -n 1 || true)"
    log "TLC: $module clean${states:+ ($states)}"
}

run_tlc MultiUser
run_tlc Extensions

# ---------------------------------------------------------------------------
# JSON shape
# ---------------------------------------------------------------------------

check_json() {
    local file="$1"
    if ! jq -e . "$file" >/dev/null 2>"$meta_root/jq.err"; then
        cat "$meta_root/jq.err" >&2
        die "not valid JSON: ${file#"$repo_root"/}"
    fi
}

for file in "$schema_dir"/*.json "$examples_dir"/*.json "$bad_dir"/*.json; do
    check_json "$file"
done

# The files are valid JSON. Now assert the examples match the bounded plan
# constraints and the bad documents violate one of them. A full JSON-Schema
# validation pass runs when python3 with the jsonschema package is available.
json_ok() {
    local file="$1"
    local filter="$2"
    local why="$3"
    if ! jq -e "$filter" "$file" >/dev/null 2>&1; then
        die "${file#"$repo_root"/}: expected $why"
    fi
}

json_bad() {
    local file="$1"
    local filter="$2"
    local why="$3"
    if jq -e "$filter" "$file" >/dev/null 2>&1; then
        die "${file#"$repo_root"/}: expected $why"
    fi
}

graph_view="$examples_dir/graph-view.json"
json_ok "$graph_view" '.schema == 1' 'schema 1'
json_ok "$graph_view" '.kind == "graph"' 'kind graph'
json_ok "$graph_view" '(.slug | type == "string") and (.name | type == "string")' 'string slug and name'
json_ok "$graph_view" '(.definition.query | length) <= 512' 'query of at most 512 characters'
json_ok "$graph_view" '(.definition.tags_shown | type == "boolean")' 'boolean tags_shown'
json_ok "$graph_view" '.definition.label_mode | IN("auto", "tags", "none")' 'label_mode auto, tags, or none'
json_ok "$graph_view" '.definition.layout_preset | IN("compact", "standard", "airy")' 'layout_preset compact, standard, or airy'
json_ok "$graph_view" '(.definition.local_depth >= 1) and (.definition.local_depth <= 3)' 'local_depth 1 to 3'
json_ok "$graph_view" '(.definition.color_groups | length) <= 24' 'at most 24 color groups'
json_ok "$graph_view" 'all(.definition.color_groups[]; (.color | test("^#[0-9a-f]{6}$")))' 'lowercase #rrggbb colors'
json_ok "$graph_view" 'all(.definition.color_groups[]; (.enabled | type == "boolean"))' 'boolean color-group enabled flags'

ledger_view="$examples_dir/ledger-view.json"
json_ok "$ledger_view" '.schema == 1' 'schema 1'
json_ok "$ledger_view" '.kind == "ledger"' 'kind ledger'
json_ok "$ledger_view" '(.definition.query | length) <= 512' 'query of at most 512 characters'
json_ok "$ledger_view" '.definition.sort | IN("created", "added", "opened")' 'sort created, added, or opened'

webhook="$examples_dir/webhook.json"
json_ok "$webhook" '(.name | type == "string") and (.name | length > 0)' 'a nonempty name'
json_ok "$webhook" '.url | test("^https?://")' 'an http or https URL'
json_ok "$webhook" '(.events | length) >= 1' 'at least one event'
json_ok "$webhook" 'all(.events[]; . == "bookmark.created" or . == "bookmark.updated" or . == "bookmark.deleted" or . == "clip.created")' 'only the four v1 event kinds'
json_ok "$webhook" '(.enabled | type == "boolean")' 'boolean enabled'

json_bad "$bad_dir/unknown-kind.json" '(.kind == "graph") or (.kind == "ledger")' 'an unknown kind'
json_bad "$bad_dir/bad-schema.json" '.schema == 1' 'an unknown schema version'
json_bad "$bad_dir/bad-color.json" 'all(.definition.color_groups[]; (.color | test("^#[0-9a-f]{6}$")))' 'an invalid color'
json_bad "$bad_dir/too-many-groups.json" '(.definition.color_groups | length) <= 24' 'more than 24 color groups'
json_bad "$bad_dir/webhook-unknown-event.json" 'all(.events[]; . == "bookmark.created" or . == "bookmark.updated" or . == "bookmark.deleted" or . == "clip.created")' 'an unknown event kind'

# ---------------------------------------------------------------------------
# Full JSON-Schema validation when a validator is available (best effort)
# ---------------------------------------------------------------------------

if command -v python3 >/dev/null 2>&1 && python3 -c 'from jsonschema import Draft202012Validator' >/dev/null 2>&1; then
    log "jsonschema available: full draft 2020-12 validation"
    python3 - "$schema_dir/view.schema.json" "$schema_dir/webhook.schema.json" \
        "$examples_dir/graph-view.json" "$examples_dir/ledger-view.json" \
        "$examples_dir/webhook.json" \
        "$bad_dir/unknown-kind.json" "$bad_dir/bad-schema.json" \
        "$bad_dir/bad-color.json" "$bad_dir/too-many-groups.json" \
        "$bad_dir/webhook-unknown-event.json" <<'PY'
import json
import sys

from jsonschema import Draft202012Validator

view_schema, webhook_schema, *documents = sys.argv[1:]
with open(view_schema, encoding="utf-8") as handle:
    view = Draft202012Validator(json.load(handle))
with open(webhook_schema, encoding="utf-8") as handle:
    webhook = Draft202012Validator(json.load(handle))
Draft202012Validator.check_schema(view.schema)
Draft202012Validator.check_schema(webhook.schema)

valid_documents = documents[:3]
invalid_documents = documents[3:]
for path in valid_documents:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    validator = webhook if document.get("events") is not None else view
    errors = sorted(validator.iter_errors(document), key=lambda error: error.path)
    if errors:
        sys.exit(f"{path}: expected valid: {errors[0].message}")
for path in invalid_documents:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    validator = webhook if path.endswith("webhook-unknown-event.json") else view
    if validator.is_valid(document):
        sys.exit(f"{path}: expected invalid but the schema accepted it")
PY
else
    log "jsonschema not available: skipping full JSON-Schema validation (jq checks ran)"
fi

log "all spec checks passed"
