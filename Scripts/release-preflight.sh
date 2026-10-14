#!/usr/bin/env bash
# release-preflight.sh — asserts the repo is in a releasable state for a tag.
#
# Usage:
#   ./Scripts/release-preflight.sh VERSION [INTENDED_LATTICECORE_VERSION]
#   ./Scripts/release-preflight.sh 1.0.0
#
# Runs every check and reports all failures (exit 1 if any):
#   1. VERSION is semver: X.Y.Z or X.Y.Z-rc.N
#   2. Working tree is clean
#   3. HEAD == origin/main (fetched fresh)
#   4. NOT in the LatticeCore edit-mode dev loop. The edit-mode signature is
#      PIN ABSENCE: `swift package edit LatticeCore --path ../latticecore`
#      makes the next resolve DROP the latticecore pin from Package.resolved.
#      So we assert the pin is PRESENT, == the intended LatticeCore version
#      (second arg or $LATTICECORE_PIN_INTENDED; defaults to the manifest
#      floor), and >= the manifest floor (`from:` in Package.swift).
#      Package.resolved is format v3: top-level originHash + pins[].
#   5. `## [VERSION]` section exists in CHANGELOG.md
#   6. Tag VERSION is unused (or already exists pointing at HEAD — the
#      in-flight release run itself, since the tag push is what triggers
#      release.yml)
#   7. Monotonicity, SEMVER-aware: VERSION > every existing tag. Pre-release
#      is compared per semver (1.0.0 > 1.0.0-rc.2 > 1.0.0-rc.1). Plain
#      `sort -V` orders 1.0.0 BEFORE 1.0.0-rc.1 and would block the final
#      tag — hence the -rc.* handling.
#   8. CI green for HEAD: push-event runs of the CI workflow for this exact
#      commit, EXCLUDING the current Actions run id (no self-deadlock when
#      called from release.yml) and requiring at least one completed
#      successful run (a just-pushed commit with no CI runs yet must FAIL,
#      not vacuously pass).
#
# EXPECTED LOCAL BEHAVIOR in the two-repo dev loop: this script FAILS on a
# dev machine with the LatticeCore edit override active — check 4 sees the
# stripped pin (and check 2 sees the mutated Package.resolved). That is the
# point: releases only preflight clean from a pristine origin/main checkout,
# i.e. from CI. Never commit the pin-stripped Package.resolved to "fix" it.
set -u

VERSION="${1:-}"
INTENDED="${2:-${LATTICECORE_PIN_INTENDED:-}}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

FAILURES=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'

# --- semver helpers ---------------------------------------------------------
# base "1.2.3-rc.4" -> "1.2.3"; pre "1.2.3-rc.4" -> "rc.4" ("" when release)
base_of() { printf '%s' "${1%%-*}"; }
pre_of()  { case "$1" in *-*) printf '%s' "${1#*-}" ;; *) printf '' ;; esac; }

# semver_gt A B — true iff A > B. Bases are plain X.Y.Z (sort -V is safe on
# those); for equal bases, release > rc, and rc.N > rc.M iff N > M.
semver_gt() {
    local a="$1" b="$2"
    local ab bb ap bp
    ab="$(base_of "$a")"; bb="$(base_of "$b")"
    if [ "$ab" != "$bb" ]; then
        [ "$(printf '%s\n%s\n' "$ab" "$bb" | sort -V | tail -1)" = "$ab" ]
        return
    fi
    ap="$(pre_of "$a")"; bp="$(pre_of "$b")"
    if [ -z "$ap" ] && [ -n "$bp" ]; then return 0; fi   # release > rc
    if [ -n "$ap" ] && [ -z "$bp" ]; then return 1; fi   # rc < release
    if [ -z "$ap" ] && [ -z "$bp" ]; then return 1; fi   # equal
    [ "${ap#rc.}" -gt "${bp#rc.}" ]                       # rc.N vs rc.M
}

# semver_ge for plain X.Y.Z (pin/floor comparisons)
vge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# --- 1. argument ------------------------------------------------------------
if [ -z "$VERSION" ]; then
    echo "usage: $0 VERSION [INTENDED_LATTICECORE_VERSION]" >&2
    exit 2
fi
if printf '%s' "$VERSION" | grep -Eq "$SEMVER_RE"; then
    pass "version '$VERSION' is well-formed semver"
else
    fail "version '$VERSION' is not X.Y.Z or X.Y.Z-rc.N"
    exit 1
fi

# --- 2. clean tree ----------------------------------------------------------
if [ -z "$(git status --porcelain)" ]; then
    pass "working tree is clean"
else
    fail "working tree is dirty:
$(git status --porcelain | sed 's/^/        /')"
fi

# --- 3. HEAD == origin/main -------------------------------------------------
if git fetch --quiet origin main 2>/dev/null; then
    HEAD_SHA="$(git rev-parse HEAD)"
    MAIN_SHA="$(git rev-parse FETCH_HEAD)"
    if [ "$HEAD_SHA" = "$MAIN_SHA" ]; then
        pass "HEAD ($HEAD_SHA) == origin/main"
    else
        fail "HEAD ($HEAD_SHA) != origin/main ($MAIN_SHA)"
    fi
else
    HEAD_SHA="$(git rev-parse HEAD)"
    fail "could not fetch origin/main to compare against HEAD"
fi

# --- 4. LatticeCore pin (edit-mode detector) --------------------------------
FLOOR="$(sed -n 's/.*LatticeCore\.git", *from: *"\([0-9][0-9.]*\)").*/\1/p' Package.swift | head -1)"
if [ -z "$FLOOR" ]; then
    fail "could not parse the LatticeCore 'from:' floor out of Package.swift"
else
    pass "manifest floor for LatticeCore is $FLOOR"
fi
[ -n "$INTENDED" ] || INTENDED="$FLOOR"

PIN="$(python3 - <<'PY'
import json, sys
try:
    d = json.load(open("Package.resolved"))
except Exception:
    sys.exit(0)
# Format v3: top-level originHash + pins[]. Refuse to guess on other formats.
if d.get("version") != 3 or "originHash" not in d or "pins" not in d:
    print("FORMAT_DRIFT")
    sys.exit(0)
for p in d["pins"]:
    if p.get("identity") == "latticecore":
        print(p.get("state", {}).get("version", ""))
        break
PY
)"
if [ "$PIN" = "FORMAT_DRIFT" ]; then
    fail "Package.resolved is not format v3 (originHash + pins[]) — update this script's parser deliberately"
elif [ -z "$PIN" ]; then
    fail "latticecore pin ABSENT from Package.resolved — the edit-mode signature. Release preflight must run from a pristine origin/main checkout (CI), not a dev tree with the LatticeCore edit override."
else
    pass "latticecore pin present: $PIN"
    if [ "$PIN" = "$INTENDED" ]; then
        pass "pin == intended LatticeCore version ($INTENDED)"
    else
        fail "pin $PIN != intended LatticeCore version $INTENDED (pass the intended version as arg 2 if a newer pin is deliberate)"
    fi
    if [ -n "$FLOOR" ]; then
        if vge "$PIN" "$FLOOR"; then
            pass "pin $PIN >= manifest floor $FLOOR"
        else
            fail "pin $PIN < manifest floor $FLOOR — Package.resolved and Package.swift disagree"
        fi
    fi
fi

# --- 5. CHANGELOG -----------------------------------------------------------
if grep -q "^## \[$VERSION\]" CHANGELOG.md; then
    pass "CHANGELOG.md has a '## [$VERSION]' section"
else
    fail "CHANGELOG.md has no '## [$VERSION]' section"
fi

# --- 6+7. tags: unused + semver-aware monotonicity --------------------------
EXISTING_AT="$(git rev-parse -q --verify "refs/tags/$VERSION^{commit}" || true)"
if [ -z "$EXISTING_AT" ]; then
    pass "tag $VERSION is unused"
elif [ "$EXISTING_AT" = "$HEAD_SHA" ]; then
    pass "tag $VERSION exists and points at HEAD (the in-flight release)"
else
    fail "tag $VERSION already exists at $EXISTING_AT (not HEAD)"
fi

MONOTONIC_OK=1
HIGHEST=""
while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    [ "$tag" = "$VERSION" ] && continue
    if [ -z "$HIGHEST" ] || semver_gt "$tag" "$HIGHEST"; then HIGHEST="$tag"; fi
    if ! semver_gt "$VERSION" "$tag"; then MONOTONIC_OK=0; fi
done <<EOF
$(git tag -l | grep -E "$SEMVER_RE" || true)
EOF
if [ "$MONOTONIC_OK" = 1 ]; then
    pass "monotonicity: $VERSION > every existing tag (highest: ${HIGHEST:-none})"
else
    fail "monotonicity: $VERSION is not > every existing tag (highest existing: $HIGHEST)"
fi

# --- 8. CI green for HEAD ---------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
    fail "gh CLI not available — cannot verify CI is green for HEAD"
else
    RUNS_JSON="$(gh run list --commit "$HEAD_SHA" --event push --limit 100 \
        --json databaseId,workflowName,status,conclusion 2>/dev/null || printf '')"
    CI_VERDICT="$(RUNS_JSON="$RUNS_JSON" CURRENT_RUN_ID="${GITHUB_RUN_ID:-}" python3 - <<'PY'
import json, os
raw = os.environ.get("RUNS_JSON", "")
try:
    runs = json.loads(raw) if raw else []
except Exception:
    runs = None
if runs is None:
    print("ERROR could not parse gh run list output")
else:
    current = os.environ.get("CURRENT_RUN_ID", "")
    ci = [r for r in runs
          if str(r.get("databaseId")) != current
          and r.get("workflowName") == "CI"]
    if not ci:
        print("FAIL no completed push-event CI runs for HEAD (just pushed? wait for CI)")
    else:
        bad = [r for r in ci if r.get("status") != "completed" or r.get("conclusion") != "success"]
        if bad:
            print("FAIL " + "; ".join(
                f"run {r['databaseId']}: {r.get('status')}/{r.get('conclusion')}" for r in bad))
        else:
            print(f"PASS {len(ci)} push-event CI run(s) for HEAD, all green")
PY
)"
    case "$CI_VERDICT" in
        PASS*) pass "CI green for HEAD: ${CI_VERDICT#PASS }" ;;
        *)     fail "CI for HEAD: ${CI_VERDICT#* }" ;;
    esac
fi

# --- verdict ----------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PREFLIGHT OK — $VERSION is releasable from $HEAD_SHA"
    exit 0
else
    echo "PREFLIGHT FAILED — $FAILURES check(s) failed"
    exit 1
fi
