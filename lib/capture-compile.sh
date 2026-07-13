#!/usr/bin/env bash
# capture-compile.sh — bundle a compile-time failure (cln compile ...) into
# a deterministic tarball for the closed-loop bug workflow.
#
# Unlike the HTTP capture, this doesn't need a DB fixture or node-server.
# Everything the fixer needs is a .cln source file + the expected outcome
# of `cln compile` on it. The tarball's run.sh shells out to `cln compile`
# and asserts on exit code + stderr/stdout substring matches.
#
# The `--component` flag routes to the fixer repo (compiler for codegen /
# semantic / plugin bugs; framework for framework-plugin issues).
set -euo pipefail

usage() {
  cat <<EOF
Usage: cln-repro capture-compile [OPTIONS]

Required:
  --source-file <path.cln>       .cln source that reproduces the compile bug
  --component <target>           target fixer component (compiler | framework | ...)
  --expected-exit-code <int>     expected 'cln compile' exit code (0 = success expected;
                                 non-zero = compile error expected — MUST match this int)

At least one match required:
  --expected-stderr-match <str>  substring MUST appear in cln's stderr (repeatable)
  --expected-stdout-match <str>  substring MUST appear in cln's stdout (repeatable)

Optional:
  --plugins <list>               plugins to pass to 'cln compile --plugins' (comma-separated)
  --repo <owner/name>            GitHub repo to file issue against
  --actor <name>                 captured_by field in manifest (default: \$USER)
  --no-file                      build tarball but do NOT file GitHub issue
  --out <path>                   output directory (default: /tmp)
  --title <str>                  short human title for the issue (default: derived from filename)
EOF
  exit 1
}

# ---- component → default GitHub repo (same map as capture.sh) ------------
COMPONENT_REPO_compiler="Ivan-Pasco/clean-language-compiler"
COMPONENT_REPO_node_server="ivan-pasco/clean-node-server"
COMPONENT_REPO_server="Ivan-Pasco/clean-server"
COMPONENT_REPO_framework="Ivan-Pasco/clean-framework"

# ---- parse args -----------------------------------------------------------
SOURCE_FILE=""; COMPONENT=""; EXPECTED_EXIT=""
PLUGINS=""; REPO=""; ACTOR="${USER:-unknown}"; OUT_DIR="/tmp"; FILE_ISSUE=1
TITLE=""
STDERR_MATCHES=(); STDOUT_MATCHES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-file)           SOURCE_FILE="$2"; shift 2 ;;
    --component)             COMPONENT="$2"; shift 2 ;;
    --expected-exit-code)    EXPECTED_EXIT="$2"; shift 2 ;;
    --expected-stderr-match) STDERR_MATCHES+=("$2"); shift 2 ;;
    --expected-stdout-match) STDOUT_MATCHES+=("$2"); shift 2 ;;
    --plugins)               PLUGINS="$2"; shift 2 ;;
    --repo)                  REPO="$2"; shift 2 ;;
    --actor)                 ACTOR="$2"; shift 2 ;;
    --no-file)               FILE_ISSUE=0; shift ;;
    --out)                   OUT_DIR="$2"; shift 2 ;;
    --title)                 TITLE="$2"; shift 2 ;;
    -h|--help)               usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$SOURCE_FILE" ]] && { echo "missing --source-file"; usage; }
[[ ! -f "$SOURCE_FILE" ]] && { echo "not found: $SOURCE_FILE" >&2; exit 2; }
[[ -z "$COMPONENT" ]] && { echo "missing --component"; usage; }
[[ -z "$EXPECTED_EXIT" ]] && { echo "missing --expected-exit-code"; usage; }
if [[ ${#STDERR_MATCHES[@]} -eq 0 && ${#STDOUT_MATCHES[@]} -eq 0 ]]; then
  echo "at least one --expected-stderr-match or --expected-stdout-match required"
  usage
fi

if [[ -z "$REPO" ]]; then
  KEY=$(echo "$COMPONENT" | tr '-' '_')
  var="COMPONENT_REPO_${KEY}"
  REPO="${!var:-}"
  [[ -z "$REPO" ]] && { echo "no default repo for component '$COMPONENT' — pass --repo" >&2; exit 2; }
fi

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 3; }
command -v tar >/dev/null || { echo "tar required" >&2; exit 3; }
command -v cln >/dev/null || { echo "cln required in PATH" >&2; exit 3; }
if [[ $FILE_ISSUE -eq 1 ]]; then
  command -v gh >/dev/null || { echo "gh required (or use --no-file)" >&2; exit 3; }
fi

# ---- workspace ------------------------------------------------------------
WORK=$(mktemp -d -t cln-repro-compile-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source" "$WORK/run" "$WORK/env"

SRC_BASENAME=$(basename "$SOURCE_FILE")

echo "[1/5] Copying source file..."
cp "$SOURCE_FILE" "$WORK/source/$SRC_BASENAME"

echo "[2/5] Running 'cln compile' to capture actual outcome..."
CLN_ARGS=(compile)
if [[ -n "$PLUGINS" ]]; then
  CLN_ARGS+=(--plugins)
fi
CLN_ARGS+=(-o "$WORK/actual.wasm" "$WORK/source/$SRC_BASENAME")
set +e
cln "${CLN_ARGS[@]}" > "$WORK/run/actual.stdout" 2> "$WORK/run/actual.stderr"
ACTUAL_EXIT=$?
set -e
echo "  actual_exit=$ACTUAL_EXIT stdout=$(wc -c < "$WORK/run/actual.stdout")b stderr=$(wc -c < "$WORK/run/actual.stderr")b"

echo "[3/5] Detecting environment versions..."
CLN_VER=$(cln --version 2>/dev/null | awk '{print $NF}' || echo unknown)
FUI_VER=$(cat ~/.cleen/plugins/frame.ui/.active-version 2>/dev/null || echo unknown)
FSRV_VER=$(cat ~/.cleen/plugins/frame.server/.active-version 2>/dev/null || echo unknown)
FDATA_VER=$(cat ~/.cleen/plugins/frame.data/.active-version 2>/dev/null || echo unknown)
FCANVAS_VER=$(cat ~/.cleen/plugins/frame.canvas/.active-version 2>/dev/null || echo unknown)
{
  echo "compiler=$CLN_VER"
  echo "frame_ui=$FUI_VER"
  echo "frame_server=$FSRV_VER"
  echo "frame_data=$FDATA_VER"
  echo "frame_canvas=$FCANVAS_VER"
} > "$WORK/env/versions.txt"
echo "  compiler=$CLN_VER"

echo "[4/5] Computing fingerprint + writing manifest..."
CAPTURED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Fingerprint: behavioral gap = component + source_sha + expected_exit +
# stderr_matches + stdout_matches + versions.
if command -v sha256sum >/dev/null; then
  SRC_SHA=$(sha256sum "$SOURCE_FILE" | awk '{print $1}')
else
  SRC_SHA=$(shasum -a 256 "$SOURCE_FILE" | awk '{print $1}')
fi

export FP_COMPONENT="$COMPONENT" FP_SRC_SHA="$SRC_SHA" FP_EXPECTED_EXIT="$EXPECTED_EXIT" \
       FP_VERSIONS_FILE="$WORK/env/versions.txt" FP_PLUGINS="$PLUGINS"

FP=$( { printf 'STDERR:%s\n' "${STDERR_MATCHES[@]:-}"; printf 'STDOUT:%s\n' "${STDOUT_MATCHES[@]:-}"; } | python3 -c '
import hashlib, json, os, sys
lines = [l for l in sys.stdin.read().splitlines() if l and not l.endswith(":")]
matches = sorted(lines)
component = os.environ["FP_COMPONENT"]
src_sha = os.environ["FP_SRC_SHA"]
expected_exit = os.environ["FP_EXPECTED_EXIT"]
plugins = os.environ["FP_PLUGINS"]
env = open(os.environ["FP_VERSIONS_FILE"]).read()
blob = "|".join([component, "compile", src_sha, expected_exit, plugins, json.dumps(matches), env])
print(hashlib.sha256(blob.encode()).hexdigest())
')
echo "  fingerprint=$FP"

# ---- manifest.json --------------------------------------------------------
export M_FP="$FP" M_COMPONENT="$COMPONENT" M_CAPTURED_AT="$CAPTURED_AT" M_ACTOR="$ACTOR" \
       M_CLN_VER="$CLN_VER" M_FUI_VER="$FUI_VER" M_FSRV_VER="$FSRV_VER" \
       M_FDATA_VER="$FDATA_VER" M_FCANVAS_VER="$FCANVAS_VER" \
       M_SRC_FILE="$SRC_BASENAME" M_SRC_SHA="$SRC_SHA" \
       M_EXPECTED_EXIT="$EXPECTED_EXIT" M_ACTUAL_EXIT="$ACTUAL_EXIT" M_PLUGINS="$PLUGINS"

{ printf 'STDERR\t%s\n' "${STDERR_MATCHES[@]:-}"; printf 'STDOUT\t%s\n' "${STDOUT_MATCHES[@]:-}"; } | python3 -c '
import json, os, sys
stderr_m, stdout_m = [], []
for line in sys.stdin.read().splitlines():
    if not line or line.endswith("\t"): continue
    kind, val = line.split("\t", 1)
    (stderr_m if kind == "STDERR" else stdout_m).append(val)

manifest = {
  "schema_version": 1,
  "fingerprint": os.environ["M_FP"],
  "component": os.environ["M_COMPONENT"],
  "reporter": {
    "project": "clean-errors",
    "captured_at": os.environ["M_CAPTURED_AT"],
    "captured_by": os.environ["M_ACTOR"],
  },
  "environment": {
    "compiler": os.environ["M_CLN_VER"],
    "frame_ui": os.environ["M_FUI_VER"],
    "frame_server": os.environ["M_FSRV_VER"],
    "frame_data": os.environ["M_FDATA_VER"],
    "frame_canvas": os.environ["M_FCANVAS_VER"],
  },
  "trigger": {
    "kind": "compile",
    "source_file": os.environ["M_SRC_FILE"],
    "source_sha256": os.environ["M_SRC_SHA"],
    "plugins": os.environ["M_PLUGINS"] or None,
    "expected_exit_code": int(os.environ["M_EXPECTED_EXIT"]),
    "actual_exit_code": int(os.environ["M_ACTUAL_EXIT"]),
    "expected_stderr_matches": stderr_m,
    "expected_stdout_matches": stdout_m,
  },
  "artifacts": {
    "source_root": "source/",
  },
  "replay": {
    "entry": "./run.sh",
    "expected_exit_code": 0,
    "timeout_seconds": 60,
  },
}
print(json.dumps(manifest, indent=2))
' > "$WORK/manifest.json"

# ---- run.sh: replay = run cln compile, diff outcome ----------------------
cat > "$WORK/run.sh" <<'RUNSH'
#!/usr/bin/env bash
# Deterministic replay of a compile-time failure.
# Runs `cln compile` on the shipped source; passes iff:
#   - actual exit code matches expected
#   - all expected stderr substrings appear in captured stderr
#   - all expected stdout substrings appear in captured stdout
set -euo pipefail
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MANIFEST="$ROOT/manifest.json"
[[ ! -f "$MANIFEST" ]] && { echo "[replay] no manifest.json"; exit 2; }

SRC_FILE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["trigger"]["source_file"])' "$MANIFEST")
EXPECTED_EXIT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["trigger"]["expected_exit_code"])' "$MANIFEST")
PLUGINS=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d["trigger"].get("plugins") or ""; print(p)' "$MANIFEST")

echo "[replay] cln compile $SRC_FILE (expected_exit=$EXPECTED_EXIT)"
CLN_ARGS=(compile)
[[ -n "$PLUGINS" ]] && CLN_ARGS+=(--plugins)
CLN_ARGS+=(-o "$ROOT/replay.wasm" "$ROOT/source/$SRC_FILE")

set +e
cln "${CLN_ARGS[@]}" > "$ROOT/replay.stdout" 2> "$ROOT/replay.stderr"
ACTUAL_EXIT=$?
set -e

echo "[replay] actual_exit=$ACTUAL_EXIT expected_exit=$EXPECTED_EXIT"

FAIL=0
if [[ "$ACTUAL_EXIT" != "$EXPECTED_EXIT" ]]; then
  echo "[replay] FAIL: exit code mismatch"
  FAIL=1
fi

# Extract match arrays from manifest
STDERR_MATCHES=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["trigger"]["expected_stderr_matches"]))' "$MANIFEST")
STDOUT_MATCHES=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["trigger"]["expected_stdout_matches"]))' "$MANIFEST")

while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if ! grep -qF "$m" "$ROOT/replay.stderr"; then
    echo "[replay] FAIL: stderr missing '$m'"
    FAIL=1
  fi
done <<< "$STDERR_MATCHES"

while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if ! grep -qF "$m" "$ROOT/replay.stdout"; then
    echo "[replay] FAIL: stdout missing '$m'"
    FAIL=1
  fi
done <<< "$STDOUT_MATCHES"

if [[ $FAIL -eq 0 ]]; then
  echo "[replay] PASS"
  exit 0
else
  echo "[replay] --- stderr (first 500 chars) ---"
  head -c 500 "$ROOT/replay.stderr" 2>/dev/null || echo "(empty)"
  echo ""
  echo "[replay] --- stdout (first 500 chars) ---"
  head -c 500 "$ROOT/replay.stdout" 2>/dev/null || echo "(empty)"
  exit 1
fi
RUNSH
chmod +x "$WORK/run.sh"

echo "[5/5] Tarballing..."
TARBALL="$OUT_DIR/bug-${FP:0:12}.tar.gz"
(cd "$WORK" && tar --exclude 'actual.wasm' --exclude 'replay.wasm' --exclude 'replay.*' -czf "$TARBALL" .)
TARBALL_SIZE=$(wc -c < "$TARBALL" | tr -d ' ')
if command -v sha256sum >/dev/null; then
  TARBALL_SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
else
  TARBALL_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
fi
echo "  tarball: $TARBALL ($TARBALL_SIZE bytes, sha=$TARBALL_SHA)"

# ---- issue body ----------------------------------------------------------
if [[ -z "$TITLE" ]]; then
  TITLE="cln compile ${SRC_BASENAME} on $CLN_VER"
fi

BODY_FILE=$(mktemp)
{
  echo "**Reporter artifact for closed-loop bug workflow.** See tools/cln-repro/README.md."
  echo ""
  echo "**Trigger**: \`cln compile $SRC_BASENAME\` — expected exit **$EXPECTED_EXIT**, actual **$ACTUAL_EXIT**"
  echo ""
  echo "**Environment**:"
  echo "- compiler \`$CLN_VER\`"
  echo "- frame.ui \`$FUI_VER\`, frame.server \`$FSRV_VER\`, frame.data \`$FDATA_VER\`, frame.canvas \`$FCANVAS_VER\`"
  echo ""
  if [[ ${#STDERR_MATCHES[@]} -gt 0 ]]; then
    echo "**Expected stderr substrings** (all required):"
    for m in "${STDERR_MATCHES[@]}"; do echo "- \`$m\`"; done
    echo ""
  fi
  if [[ ${#STDOUT_MATCHES[@]} -gt 0 ]]; then
    echo "**Expected stdout substrings** (all required):"
    for m in "${STDOUT_MATCHES[@]}"; do echo "- \`$m\`"; done
    echo ""
  fi
  echo "**Fingerprint**: \`$FP\`"
  echo "**Tarball sha256**: \`$TARBALL_SHA\` (\`bug-${FP:0:12}.tar.gz\`, $TARBALL_SIZE bytes)"
  echo ""
  echo "---"
  echo ""
  echo "## Source (from tarball)"
  echo ""
  echo '```clean'
  cat "$SOURCE_FILE"
  echo '```'
  echo ""
  echo "## Manifest"
  echo ""
  echo '```json'
  cat "$WORK/manifest.json"
  echo '```'
  echo ""
  echo "## How to replay"
  echo ""
  echo '```bash'
  echo "# Download tarball, then:"
  echo "tar xf bug-${FP:0:12}.tar.gz -C /tmp/replay-${FP:0:12}"
  echo "cd /tmp/replay-${FP:0:12}"
  echo "bash run.sh    # exit 0 = fix landed; non-zero = bug still reproduces"
  echo '```'
} > "$BODY_FILE"

if [[ $FILE_ISSUE -eq 1 ]]; then
  ISSUE_TITLE="[reporter-artifact] ${FP:0:12}: $TITLE"
  echo "Filing GitHub issue on $REPO..."
  ISSUE_URL=$(gh issue create --repo "$REPO" \
    --title "$ISSUE_TITLE" \
    --label reporter-artifact \
    --body-file "$BODY_FILE" 2>&1 | tail -1)
  echo "  issue: $ISSUE_URL"
  echo ""
  echo "  Now attach $TARBALL to the issue. Options:"
  echo "  1. gh release upload repro-tarballs $TARBALL --repo Ivan-Pasco/cln-repro --clobber"
  echo "     (recommended — public repo, anonymous curl works, cln-repro run <issue-url> resolves it)"
  echo "  2. Drag+drop into the issue via web UI (GitHub user-attachments, less durable)"
else
  echo ""
  echo "  Skipping GitHub issue filing (--no-file)."
  echo "  Body preview (first 40 lines):"
  echo "  ---"
  head -40 "$BODY_FILE" | sed 's/^/  /'
fi

rm -f "$BODY_FILE"
echo ""
echo "Done. fingerprint=$FP"
