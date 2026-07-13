#!/usr/bin/env bash
# run.sh — replay a captured tarball, print pass/fail, exit accordingly.
#
# Input can be:
#   - a local .tar.gz path
#   - a GitHub issue URL (uses `gh` to download the attached tarball)
#   - a GitHub release asset URL
#
# Environment:
#   CLN_REPRO_DB_URL   scratch mysql URL for replay (default:
#                      mysql://root@127.0.0.1:3306/cln_repro_replay)
set -euo pipefail

usage() {
  cat <<EOF
Usage: cln-repro run <input>

Input:
  /path/to/bug-XXXXXX.tar.gz      Local tarball
  https://github.com/OWNER/REPO/issues/N  GitHub issue with attached tarball
  https://github.com/OWNER/REPO/releases/download/TAG/bug-XXX.tar.gz  Direct release asset

Environment:
  CLN_REPRO_DB_URL   scratch mysql URL for replay (default: mysql://root@127.0.0.1:3306/cln_repro_replay)
EOF
  exit 1
}

INPUT="${1:-}"
[[ -z "$INPUT" ]] && usage
[[ "$INPUT" == "-h" || "$INPUT" == "--help" ]] && usage

# ---- workspace ------------------------------------------------------------
WORK=$(mktemp -d -t cln-repro-run-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
TARBALL=""

# ---- source dispatch ------------------------------------------------------
if [[ "$INPUT" == /* || "$INPUT" == ./* || -f "$INPUT" ]]; then
  # Local path
  [[ ! -f "$INPUT" ]] && { echo "not found: $INPUT" >&2; exit 2; }
  TARBALL="$INPUT"
  echo "[run] using local tarball $TARBALL"
elif [[ "$INPUT" =~ ^https://github.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  NUM="${BASH_REMATCH[3]}"
  echo "[run] fetching tarball reference from $OWNER/$REPO issue #$NUM..."
  command -v gh >/dev/null || { echo "gh required for GitHub URLs" >&2; exit 3; }
  BODY=$(gh issue view "$NUM" --repo "$OWNER/$REPO" --json body -q .body)
  # Find a tar.gz URL in the body (release asset link or user-drag-drop attachment)
  ASSET_URL=$(printf '%s' "$BODY" | grep -oE 'https://[^ )]+bug-[a-f0-9]+\.tar\.gz' | head -1)
  if [[ -z "$ASSET_URL" ]]; then
    # Look for github user-content attachments (drag+drop into issue body)
    ASSET_URL=$(printf '%s' "$BODY" | grep -oE 'https://github\.com/user-attachments/files/[^ )]+' | head -1)
  fi
  if [[ -z "$ASSET_URL" ]]; then
    echo "no tarball URL found in issue body" >&2
    echo "body was:" >&2
    printf '%s\n' "$BODY" | head -30 >&2
    exit 3
  fi
  TARBALL="$WORK/downloaded.tar.gz"
  echo "[run] downloading $ASSET_URL..."
  # If the asset URL is a GitHub release download URL, use `gh release download`
  # (authenticated API) — anonymous curl gets 404 on some releases.
  if [[ "$ASSET_URL" =~ ^https://github.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$ ]]; then
    RO="${BASH_REMATCH[1]}"; RR="${BASH_REMATCH[2]}"; RT="${BASH_REMATCH[3]}"; RA="${BASH_REMATCH[4]}"
    gh release download "$RT" --repo "$RO/$RR" --pattern "$RA" --output "$TARBALL" --clobber
  else
    curl -sL "$ASSET_URL" > "$TARBALL"
  fi
elif [[ "$INPUT" =~ ^https://github.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$ ]]; then
  # GitHub release asset URL — `curl -sL` gets 404 on some releases due to
  # GitHub's CDN posture; `gh release download` uses the authenticated API
  # path which works reliably.
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  TAG="${BASH_REMATCH[3]}"
  ASSET="${BASH_REMATCH[4]}"
  TARBALL="$WORK/$ASSET"
  echo "[run] gh release download $TAG/$ASSET from $OWNER/$REPO..."
  command -v gh >/dev/null || { echo "gh required for GitHub release URLs" >&2; exit 3; }
  gh release download "$TAG" --repo "$OWNER/$REPO" --pattern "$ASSET" --output "$TARBALL" --clobber
elif [[ "$INPUT" =~ ^https?:// ]]; then
  # direct URL
  TARBALL="$WORK/downloaded.tar.gz"
  echo "[run] downloading $INPUT..."
  curl -sL "$INPUT" > "$TARBALL"
else
  echo "unrecognized input form: $INPUT" >&2
  usage
fi

# ---- unpack + verify manifest --------------------------------------------
UNPACK="$WORK/unpack"
mkdir -p "$UNPACK"
tar xzf "$TARBALL" -C "$UNPACK"
[[ ! -f "$UNPACK/manifest.json" ]] && { echo "tarball missing manifest.json" >&2; exit 3; }
[[ ! -x "$UNPACK/run.sh" ]] && chmod +x "$UNPACK/run.sh"

FP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$UNPACK/manifest.json")
COMP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["component"])' "$UNPACK/manifest.json")
# trigger.kind is "http" (default, has url) or "compile" (has source_file).
# Print whatever locator makes sense so the operator can see what's being replayed.
TRIGGER_DESC=$(python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["trigger"]
if "url" in t:
    print("url=" + t["url"])
elif "source_file" in t:
    print("compile source_file=" + t["source_file"])
else:
    print("<unknown trigger shape>")
' "$UNPACK/manifest.json")
echo "[run] fingerprint=${FP:0:12}... component=$COMP $TRIGGER_DESC"

# ---- invoke the tarball-supplied run.sh -----------------------------------
export CLN_REPRO_DB_URL="${CLN_REPRO_DB_URL:-mysql://root@127.0.0.1:3306/cln_repro_replay}"
echo "[run] invoking $UNPACK/run.sh (db=$CLN_REPRO_DB_URL)..."
echo ""

set +e
(cd "$UNPACK" && bash run.sh)
RC=$?
set -e

echo ""
if [[ $RC -eq 0 ]]; then
  echo "[run] RESULT: PASS  (fingerprint ${FP:0:12}, component $COMP)"
else
  echo "[run] RESULT: FAIL  (exit=$RC, fingerprint ${FP:0:12}, component $COMP)"
fi
exit $RC
