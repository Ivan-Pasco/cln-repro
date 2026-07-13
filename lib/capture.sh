#!/usr/bin/env bash
# capture.sh — bundle a failing HTTP request into a deterministic tarball
# and file it as a GitHub issue on the target fixer repo.
#
# The failing request is executed once against the reporter's live app, its
# response captured, the DB rows the query touched are dumped as a minimal
# fixture, the WASM + source tree are copied, an entry point script is
# generated, and everything is tar+gzipped keyed by a behavioral-gap
# fingerprint.
set -euo pipefail

usage() {
  cat <<EOF
Usage: cln-repro capture [OPTIONS]

Required:
  --url <path>              URL path relative to the app (e.g. /tasks?origin=error)
  --db  <mysql-url>         mysql://user:pass@host:port/dbname
  --wasm <path>             path to the compiled errors.wasm
  --source <path>           path to the source tree (copied verbatim into tarball)
  --component <target>      target fixer component (compiler | node-server | ...)
  --expected-match <str>    substring the response body MUST contain (repeatable, at least 1)

Optional:
  --host <base-url>         base URL for the request (default: http://127.0.0.1:3002)
  --repo <owner/name>       GitHub repo to file the issue against
                            (default: derived from --component, see COMPONENT_REPO map)
  --actor <name>            captured_by field in manifest (default: \$USER)
  --no-file                 build tarball but DO NOT file GitHub issue
  --out <path>              output directory for the tarball (default: /tmp)

Environment:
  MYSQL_CMD                 override mysql client (default: mysql)
  MYSQLDUMP_CMD             override mysqldump (default: mysqldump)
EOF
  exit 1
}

# ---- component → default GitHub repo -------------------------------------
COMPONENT_REPO_compiler="Ivan-Pasco/clean-language-compiler"
COMPONENT_REPO_node_server="ivan-pasco/clean-node-server"
COMPONENT_REPO_server="Ivan-Pasco/clean-server"
COMPONENT_REPO_framework="Ivan-Pasco/cleen-framework"

# ---- parse args -----------------------------------------------------------
URL="" ; DB_URL="" ; WASM_PATH="" ; SOURCE_PATH="" ; COMPONENT=""
HOST="http://127.0.0.1:3002" ; REPO="" ; ACTOR="${USER:-unknown}" ; OUT_DIR="/tmp"
FILE_ISSUE=1
EXPECTED_MATCHES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)              URL="$2"; shift 2 ;;
    --db)               DB_URL="$2"; shift 2 ;;
    --wasm)             WASM_PATH="$2"; shift 2 ;;
    --source)           SOURCE_PATH="$2"; shift 2 ;;
    --component)        COMPONENT="$2"; shift 2 ;;
    --expected-match)   EXPECTED_MATCHES+=("$2"); shift 2 ;;
    --host)             HOST="$2"; shift 2 ;;
    --repo)             REPO="$2"; shift 2 ;;
    --actor)            ACTOR="$2"; shift 2 ;;
    --no-file)          FILE_ISSUE=0; shift ;;
    --out)              OUT_DIR="$2"; shift 2 ;;
    -h|--help)          usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$URL" ]] && { echo "missing --url"; usage; }
[[ -z "$DB_URL" ]] && { echo "missing --db"; usage; }
[[ -z "$WASM_PATH" ]] && { echo "missing --wasm"; usage; }
[[ -z "$SOURCE_PATH" ]] && { echo "missing --source"; usage; }
[[ -z "$COMPONENT" ]] && { echo "missing --component"; usage; }
[[ ${#EXPECTED_MATCHES[@]} -eq 0 ]] && { echo "at least one --expected-match required"; usage; }
[[ ! -f "$WASM_PATH" ]] && { echo "wasm not found: $WASM_PATH" >&2; exit 2; }
[[ ! -d "$SOURCE_PATH" ]] && { echo "source dir not found: $SOURCE_PATH" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
  KEY=$(echo "$COMPONENT" | tr '-' '_')
  var="COMPONENT_REPO_${KEY}"
  REPO="${!var:-}"
  if [[ -z "$REPO" ]]; then
    echo "no default repo for component '$COMPONENT' — pass --repo <owner/name>" >&2
    exit 2
  fi
fi

MYSQL_CMD="${MYSQL_CMD:-mysql}"
MYSQLDUMP_CMD="${MYSQLDUMP_CMD:-mysqldump}"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 3; }
command -v tar >/dev/null || { echo "tar required" >&2; exit 3; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 3; }
command -v "$MYSQL_CMD" >/dev/null || { echo "$MYSQL_CMD required" >&2; exit 3; }
command -v "$MYSQLDUMP_CMD" >/dev/null || { echo "$MYSQLDUMP_CMD required" >&2; exit 3; }
if [[ $FILE_ISSUE -eq 1 ]]; then
  command -v gh >/dev/null || { echo "gh required (or use --no-file)" >&2; exit 3; }
fi

# ---- parse mysql URL ------------------------------------------------------
# format: mysql://user:pass@host:port/dbname
DB_USER=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.username or '')" "$DB_URL")
DB_PASS=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.password or '')" "$DB_URL")
DB_HOST=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.hostname or '')" "$DB_URL")
DB_PORT=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.port or 3306)" "$DB_URL")
DB_NAME=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print((p.path or '').lstrip('/'))" "$DB_URL")

[[ -z "$DB_HOST" || -z "$DB_NAME" ]] && { echo "unparseable --db (need mysql://user:pass@host:port/dbname)"; exit 2; }

# ---- workspace ------------------------------------------------------------
WORK=$(mktemp -d -t cln-repro-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source" "$WORK/wasm" "$WORK/fixture" "$WORK/run" "$WORK/env"

echo "[1/7] Capturing failing response from $HOST$URL..."
ACTUAL_STATUS=$(curl -sk -o "$WORK/run/actual.body" -w "%{http_code}" \
  -D "$WORK/run/actual.headers" "$HOST$URL" || echo "000")
echo "  actual_status=$ACTUAL_STATUS actual_body_size=$(wc -c < "$WORK/run/actual.body")"

# request.http — deterministic form of the request we made
{
  echo "GET $URL HTTP/1.1"
  echo "Host: $(echo "$HOST" | sed 's|https\?://||;s|/.*||')"
} > "$WORK/run/request.http"

# actual.http = headers + body concatenated in canonical form
{
  cat "$WORK/run/actual.headers"
  echo ""
  cat "$WORK/run/actual.body"
} > "$WORK/run/actual.http"

echo "[2/7] Detecting environment versions..."
CLN_VER=$(cln --version 2>/dev/null | awk '{print $NF}' || echo unknown)
NS_VER=$(clean-node-server --version 2>/dev/null | head -1 || echo unknown)
FUI_VER=$(cat ~/.cleen/plugins/frame.ui/.active-version 2>/dev/null || echo unknown)
FSRV_VER=$(cat ~/.cleen/plugins/frame.server/.active-version 2>/dev/null || echo unknown)
FDATA_VER=$(cat ~/.cleen/plugins/frame.data/.active-version 2>/dev/null || echo unknown)
{
  echo "compiler=$CLN_VER"
  echo "node_server=$NS_VER"
  echo "frame_ui=$FUI_VER"
  echo "frame_server=$FSRV_VER"
  echo "frame_data=$FDATA_VER"
} > "$WORK/env/versions.txt"
echo "  compiler=$CLN_VER node_server=$NS_VER frame_ui=$FUI_VER"

echo "[3/7] Copying WASM + source tree..."
cp "$WASM_PATH" "$WORK/wasm/errors.wasm"
# copy source but skip build artifacts / .git / node_modules
rsync -a \
  --exclude '.git' --exclude 'dist' --exclude 'node_modules' \
  --exclude '*.wasm' --exclude 'db_data' --exclude '.env*' \
  "$SOURCE_PATH/" "$WORK/source/"

echo "[4/7] Dumping DB fixture (schema + minimal rows)..."
# schema — structure only, no data
$MYSQLDUMP_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ${DB_PASS:+-p"$DB_PASS"} \
  --no-data --skip-comments --skip-add-drop-table --skip-lock-tables --skip-set-charset \
  "$DB_NAME" 2>/dev/null > "$WORK/fixture/schema.sql"

# data — dump full contents of common small tables. For MVP we take ALL rows;
# a future capture will parse slow-query-log to pick just the rows the URL's
# queries touched.
$MYSQLDUMP_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" ${DB_PASS:+-p"$DB_PASS"} \
  --no-create-info --skip-comments --skip-add-locks --skip-lock-tables --skip-set-charset \
  --skip-triggers --complete-insert --single-transaction \
  "$DB_NAME" 2>/dev/null > "$WORK/fixture/data.sql"

FIXTURE_ROWS=$(grep -c '^INSERT INTO' "$WORK/fixture/data.sql" || echo 0)
echo "  schema=$(wc -c < "$WORK/fixture/schema.sql")b data=$(wc -c < "$WORK/fixture/data.sql")b rows=$FIXTURE_ROWS"

echo "[5/7] Computing hashes + fingerprint..."
if command -v sha256sum >/dev/null; then
  WASM_SHA=$(sha256sum "$WORK/wasm/errors.wasm" | awk '{print $1}')
else
  WASM_SHA=$(shasum -a 256 "$WORK/wasm/errors.wasm" | awk '{print $1}')
fi
WASM_SIZE=$(wc -c < "$WORK/wasm/errors.wasm" | tr -d ' ')

# ---- expected.http: build from the caller-supplied match constraints -----
# The fixer's CI doesn't need the full expected body — only that certain
# substrings appear in the response. Store them as HTTP-response-shaped hints.
{
  echo "HTTP/1.1 200 OK"
  echo "X-Expected-Match-Count: ${#EXPECTED_MATCHES[@]}"
  for m in "${EXPECTED_MATCHES[@]}"; do
    echo "X-Expected-Match: $m"
  done
} > "$WORK/run/expected.http"

# ---- fingerprint (behavioral gap, NOT WASM bytes) -------------------------
# Pass matches array via stdin (newline-delimited) and inputs via env vars
# so we don't inline-expand shell arrays into a heredoc.
export FP_COMPONENT="$COMPONENT" FP_URL="$URL" FP_ACTUAL_STATUS="$ACTUAL_STATUS" FP_VERSIONS_FILE="$WORK/env/versions.txt"
FP=$(printf '%s\n' "${EXPECTED_MATCHES[@]}" | python3 -c '
import hashlib, json, os, sys
matches = sorted(l for l in sys.stdin.read().splitlines() if l)
component = os.environ["FP_COMPONENT"]
url = os.environ["FP_URL"]
method = "GET"
expected_status = 200
actual_status = int(os.environ["FP_ACTUAL_STATUS"])
env = open(os.environ["FP_VERSIONS_FILE"]).read()
blob = "|".join([component, url, method, str(expected_status),
                 str(actual_status), json.dumps(matches), env])
print(hashlib.sha256(blob.encode()).hexdigest())
')
echo "  wasm_sha=$WASM_SHA fingerprint=$FP"

echo "[6/7] Writing manifest + run.sh entry point..."
CAPTURED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# manifest.json — pass array via stdin same trick
export M_FP="$FP" M_COMPONENT="$COMPONENT" M_CAPTURED_AT="$CAPTURED_AT" M_ACTOR="$ACTOR" \
       M_CLN_VER="$CLN_VER" M_NS_VER="$NS_VER" \
       M_FUI_VER="$FUI_VER" M_FSRV_VER="$FSRV_VER" M_FDATA_VER="$FDATA_VER" \
       M_URL="$URL" M_ACTUAL_STATUS="$ACTUAL_STATUS" \
       M_WASM_SHA="$WASM_SHA" M_WASM_SIZE="$WASM_SIZE" M_FIXTURE_ROWS="$FIXTURE_ROWS"
printf '%s\n' "${EXPECTED_MATCHES[@]}" | python3 -c '
import json, os, sys
matches = [l for l in sys.stdin.read().splitlines() if l]
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
    "node_server": os.environ["M_NS_VER"],
    "frame_ui": os.environ["M_FUI_VER"],
    "frame_server": os.environ["M_FSRV_VER"],
    "frame_data": os.environ["M_FDATA_VER"],
  },
  "trigger": {
    "url": os.environ["M_URL"],
    "method": "GET",
    "expected_status": 200,
    "actual_status": int(os.environ["M_ACTUAL_STATUS"]),
    "expected_response_matches": matches,
    "actual_response_matches": [],
  },
  "artifacts": {
    "wasm_sha256": os.environ["M_WASM_SHA"],
    "wasm_size": int(os.environ["M_WASM_SIZE"]),
    "source_root": "source/",
    "fixture_row_count": int(os.environ["M_FIXTURE_ROWS"]),
  },
  "replay": {
    "entry": "./run.sh",
    "expected_exit_code": 0,
    "timeout_seconds": 60,
  },
}
print(json.dumps(manifest, indent=2))
' > "$WORK/manifest.json"

# run.sh — one-command replay. Assumes a scratch MySQL is reachable via
# CLN_REPRO_DB_URL (default mysql://root@127.0.0.1:3306/cln_repro_replay).
cat > "$WORK/run.sh" <<'RUNSH'
#!/usr/bin/env bash
# Deterministic replay of a captured failure.
# Boots a scratch DB, boots node-server against the shipped WASM, curls the
# target URL, greps for the required expected matches. Exit 0 = fix works;
# non-zero = failure still reproduces.
set -euo pipefail
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DB_URL="${CLN_REPRO_DB_URL:-mysql://root@127.0.0.1:3306/cln_repro_replay}"

# parse DB URL
DB_USER=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.username or 'root')" "$DB_URL")
DB_PASS=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.password or '')" "$DB_URL")
DB_HOST=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.hostname or '127.0.0.1')" "$DB_URL")
DB_PORT=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.port or 3306)" "$DB_URL")
DB_NAME=$(python3 -c "import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print((p.path or '').lstrip('/'))" "$DB_URL")

MYSQL_ARGS="-h $DB_HOST -P $DB_PORT -u $DB_USER"
[[ -n "$DB_PASS" ]] && MYSQL_ARGS="$MYSQL_ARGS -p$DB_PASS"

echo "[replay] resetting DB $DB_NAME..."
mysql $MYSQL_ARGS -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4;"
mysql $MYSQL_ARGS "$DB_NAME" < "$ROOT/fixture/schema.sql"
mysql $MYSQL_ARGS "$DB_NAME" < "$ROOT/fixture/data.sql"

echo "[replay] booting clean-node-server on port 31245..."
clean-node-server "$ROOT/wasm/errors.wasm" --port 31245 --host 127.0.0.1 \
  --database "$DB_URL" > "$ROOT/replay.log" 2>&1 &
NS_PID=$!
trap "kill $NS_PID 2>/dev/null || true" EXIT

# wait up to 15s for Worker pool ready
for i in $(seq 1 30); do
  if grep -q "Worker pool ready" "$ROOT/replay.log" 2>/dev/null; then break; fi
  sleep 0.5
done

# extract URL from request.http first line
URL=$(head -1 "$ROOT/run/request.http" | awk '{print $2}')
echo "[replay] curling $URL..."
RESP_BODY=$(mktemp)
STATUS=$(curl -s -o "$RESP_BODY" -w "%{http_code}" "http://127.0.0.1:31245$URL")
echo "[replay] status=$STATUS response_size=$(wc -c < "$RESP_BODY")"

# Consolidated failure dumper — always shows enough context to diagnose
# both content-of-response mismatches and 500s where node-server logs the
# real trap.
dump_failure_context() {
  echo "[replay] --- response body (first 1500 chars) ---"
  head -c 1500 "$RESP_BODY" 2>/dev/null || echo "(empty)"
  echo ""
  echo "[replay] --- node-server log tail (last 40 lines) ---"
  tail -40 "$ROOT/replay.log" 2>/dev/null || echo "(no log)"
  echo ""
}

# Expected status: parsed from expected.http first line
EXPECTED_STATUS=$(head -1 "$ROOT/run/expected.http" | awk '{print $2}')
if [[ "$STATUS" != "$EXPECTED_STATUS" ]]; then
  echo "[replay] FAIL: expected status $EXPECTED_STATUS, got $STATUS"
  dump_failure_context
  exit 1
fi

# All required matches must appear in response body
FAIL=0
while IFS= read -r line; do
  if [[ "$line" =~ ^X-Expected-Match:\ (.*)$ ]]; then
    m="${BASH_REMATCH[1]}"
    if ! grep -qF "$m" "$RESP_BODY"; then
      echo "[replay] FAIL: response missing required match: $m"
      FAIL=1
    fi
  fi
done < "$ROOT/run/expected.http"

if [[ $FAIL -eq 0 ]]; then
  echo "[replay] PASS"
  exit 0
else
  dump_failure_context
  exit 1
fi
RUNSH
chmod +x "$WORK/run.sh"

# ---- tar it ---------------------------------------------------------------
TARBALL="$OUT_DIR/bug-${FP:0:12}.tar.gz"
(cd "$WORK" && tar --exclude 'replay.log' -czf "$TARBALL" .)
TARBALL_SIZE=$(wc -c < "$TARBALL" | tr -d ' ')
if command -v sha256sum >/dev/null; then
  TARBALL_SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
else
  TARBALL_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
fi
echo "[7/7] Tarball written: $TARBALL ($TARBALL_SIZE bytes, sha=$TARBALL_SHA)"

# ---- issue body ----------------------------------------------------------
BODY_FILE=$(mktemp)
{
  echo "**Reporter artifact for closed-loop bug workflow.** See tools/cln-repro/README.md."
  echo ""
  echo "**Trigger**: \`$URL\` returned HTTP $ACTUAL_STATUS (expected 200 with matching content)"
  echo ""
  echo "**Environment**:"
  echo "- compiler \`$CLN_VER\`"
  echo "- node-server \`$NS_VER\`"
  echo "- frame.ui \`$FUI_VER\`, frame.server \`$FSRV_VER\`, frame.data \`$FDATA_VER\`"
  echo ""
  echo "**Expected response substrings** (all required):"
  for m in "${EXPECTED_MATCHES[@]}"; do
    echo "- \`$m\`"
  done
  echo ""
  echo "**Fingerprint**: \`$FP\`"
  echo "**Tarball sha256**: \`$TARBALL_SHA\` (\`bug-${FP:0:12}.tar.gz\`, $TARBALL_SIZE bytes)"
  echo ""
  echo "---"
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
  echo "# Download the attached tarball from this issue, then:"
  echo "tar xf bug-${FP:0:12}.tar.gz -C /tmp/replay-${FP:0:12}"
  echo "cd /tmp/replay-${FP:0:12}"
  echo "CLN_REPRO_DB_URL='mysql://root@127.0.0.1:3306/cln_repro_replay' bash run.sh"
  echo "# exit 0 = fix landed; non-zero = bug still reproduces"
  echo '```'
} > "$BODY_FILE"

if [[ $FILE_ISSUE -eq 1 ]]; then
  TITLE="[reporter-artifact] ${FP:0:12}: ${URL} on $CLN_VER"
  echo "[8/7] Filing GitHub issue on $REPO..."
  ISSUE_URL=$(gh issue create --repo "$REPO" \
    --title "$TITLE" \
    --label reporter-artifact \
    --body-file "$BODY_FILE" 2>&1 | tail -1)
  echo "  issue: $ISSUE_URL"
  # attach the tarball as a comment (gh issue comment supports file uploads via --body only,
  # so use gh api directly to upload)
  echo "  attaching tarball via edit-body (base64 inline; workaround for MVP)..."
  # NOTE: GitHub's issue-body doesn't accept binary attachments cleanly.
  # For MVP: attach tarball to a GH Release for retention, then edit the issue body
  # to link the release asset.
  #
  # Fallback strategy for this MVP: move tarball to a well-known path locally,
  # print the URL, ask the operator to drag+drop into the issue via the web UI.
  # Public tarball store (anonymous curl works, so any fixer CI can pull).
  echo ""
  echo "  IMPORTANT: attach $TARBALL to the issue. Recommended:"
  echo "     gh release upload repro-tarballs $TARBALL --repo Ivan-Pasco/cln-repro --clobber"
  echo "  Then edit the issue body to include:"
  echo "     https://github.com/Ivan-Pasco/cln-repro/releases/download/repro-tarballs/$(basename $TARBALL)"
else
  echo ""
  echo "  Skipping GitHub issue filing (--no-file). Tarball at $TARBALL"
  echo "  Body preview:"
  echo "  ---"
  sed 's/^/  /' "$BODY_FILE"
fi

rm -f "$BODY_FILE"
echo ""
echo "Done. fingerprint=$FP"
