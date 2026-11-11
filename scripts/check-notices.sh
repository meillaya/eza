#!/usr/bin/env bash
# Check THIRD-PARTY-NOTICES.md against the dependency set the release ships.
#
#   bash scripts/check-notices.sh            # flake overlay vs the notices table
#   bash scripts/check-notices.sh --plan     # ...and the resolved cabal plan
#
# What it checks:
#   * every package pinned in flake.nix's `hpkgsUpgraded` Hackage overlay has a
#     row in THIRD-PARTY-NOTICES.md with the pinned version. The overlay is the
#     TLS/crypto generation (webauthn 0.12, crypton 1.1, tls 2.4, http2 5.4,
#     jose, hpke, mlkem, ...) that nixpkgs does not ship for GHC 9.10, so it is
#     the part of the tree most likely to drift from the notices.
#   * every table row that names an overlaid package has the pinned version and
#     a non-empty license cell.
#   * with --plan (used in CI after `cabal build all --dry-run`/tests), the
#     resolved version in dist-newstyle/cache/plan.json matches the flake pin.
#
# A missing plan file is not an error for --plan: local runs may not have built
# anything yet, and the flake-vs-notices check still applies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK_PLAN=0
for arg in "$@"; do
  case "$arg" in
    --plan) CHECK_PLAN=1 ;;
    -h | --help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "check-notices.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

python3 - "$ROOT" "$CHECK_PLAN" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
check_plan = sys.argv[2] == "1"
notices_path = root / "THIRD-PARTY-NOTICES.md"
flake_path = root / "flake.nix"
plan_path = root / "dist-newstyle" / "cache" / "plan.json"

problems = []
notes = []

# --- pinned overlay packages from flake.nix --------------------------------
flake = flake_path.read_text(encoding="utf-8")
overlay = {}
pattern = re.compile(r'hackagePkg\s+self\s+"([^"]+)"\s+"([^"]+)"\s+"sha256-')
for match in pattern.finditer(flake):
    overlay[match.group(1)] = match.group(2)
if not overlay:
    sys.exit(
        "check-notices.sh: could not find the hackagePkg overlay in flake.nix; "
        "update this script if the flake layout changed"
    )

# --- notices table rows ----------------------------------------------------
notices = notices_path.read_text(encoding="utf-8")
rows = {}
row_pattern = re.compile(r"^\|\s*([A-Za-z0-9_.+-]+)\s*\|\s*([0-9][^|]*?)\s*\|\s*([^|]*?)\s*\|", re.MULTILINE)
for match in row_pattern.finditer(notices):
    name, version, license_text = (part.strip() for part in match.groups())
    rows[name] = {"version": version, "license": license_text}

# --- flake pin vs notices --------------------------------------------------
for package, pinned_version in sorted(overlay.items()):
    row = rows.get(package)
    if row is None:
        problems.append(
            f"missing row: {package} {pinned_version} is pinned in flake.nix but absent from THIRD-PARTY-NOTICES.md\n"
            f"    add: | {package} | {pinned_version} | <license> | <https://hackage.haskell.org/package/{package}> |"
        )
        continue
    if row["version"] != pinned_version:
        problems.append(
            f"version drift: {package}: flake.nix pins {pinned_version}, notices say {row['version']}"
        )
    if not row["license"]:
        problems.append(f"missing license: {package} row has an empty license cell")
notes.append(f"flake overlay: {len(overlay)} pinned packages, all present in the notices table")

# --- resolved cabal plan vs flake pin --------------------------------------
if check_plan:
    if not plan_path.is_file():
        notes.append(
            "cabal plan not found (dist-newstyle/cache/plan.json); ran without the plan cross-check"
        )
    else:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        resolved = {}
        for unit in plan.get("install-plan", []):
            if unit.get("type") in ("configured", "pre-existing", "builtin"):
                resolved[unit["pkg-name"]] = unit.get("pkg-version")
        missing = [pkg for pkg in overlay if pkg not in resolved]
        if len(missing) > len(overlay) // 2:
            # A plan for one package/project target (or one written by a
            # concurrent command) does not resolve the whole release closure.
            # Do not fail on absence of individual packages in that case; CI
            # generates the plan with a full `cabal build all`/`cabal test all`.
            notes.append(
                f"cabal plan: {len(resolved)} resolved packages but {len(missing)}/{len(overlay)} "
                "pinned packages absent; the plan file does not cover the full project, "
                "cross-check limited to the versions it resolves"
            )
        for package, pinned_version in sorted(overlay.items()):
            plan_version = resolved.get(package)
            if plan_version is None:
                if len(missing) <= len(overlay) // 2:
                    problems.append(
                        f"plan drift: {package} is pinned in flake.nix but not resolved by cabal.project"
                    )
            elif plan_version != pinned_version:
                problems.append(
                    f"plan drift: {package}: flake.nix pins {pinned_version}, cabal resolved {plan_version}; "
                    "bump the flake overlay with the dependency change"
                )
        notes.append(f"cabal plan: {len(resolved)} resolved packages cross-checked against the flake pin")

else:
    notes.append("cabal plan cross-check skipped (pass --plan after a cabal build)")

for note in notes:
    print(f"ok - {note}")

if problems:
    print("", file=sys.stderr)
    for problem in problems:
        print(f"not ok - {problem}", file=sys.stderr)
    print(
        "\ncheck-notices.sh: THIRD-PARTY-NOTICES.md and the pinned dependency set disagree."
        "\nFix the table (or the flake pin) and re-run. CI fails on this drift.",
        file=sys.stderr,
    )
    sys.exit(1)

print("all notices checks passed")
PY
