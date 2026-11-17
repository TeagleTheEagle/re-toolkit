#!/usr/bin/env bash
#
# lab-runner.sh — run the toolkit over a batch of targets for a workshop lab.
#
#   ./lab-runner.sh targets/                 every file in a directory
#   ./lab-runner.sh --profile quick targets/  fast pass
#   ./lab-runner.sh --grep 'password,token' targets/
#
# Writes one analysis directory per target plus an index, so a facilitator can
# see the whole room's progress at a glance.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE="$ROOT/scripts/re-analyze.sh"

PROFILE="standard"
GREP=""
OUTBASE="./lab-results"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-standard}"; shift 2 ;;
    --grep) GREP="${2:-}"; shift 2 ;;
    --out) OUTBASE="${2:-./lab-results}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done

TARGET_DIR="${1:-}"
[ -n "$TARGET_DIR" ] || { echo "usage: lab-runner.sh [options] <target-dir-or-file>" >&2; exit 2; }
[ -f "$PIPELINE" ] || { echo "pipeline not found: $PIPELINE" >&2; exit 4; }

mkdir -p "$OUTBASE"
INDEX="$OUTBASE/INDEX.md"

{
  echo "# Lab Results"
  echo
  echo "_Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') — profile: $PROFILE"
  echo
  echo "| Target | Kind | Steps ok | Steps error | Report |"
  echo "| --- | --- | --- | --- | --- |"
} > "$INDEX"

run_one() {
  local target="$1"
  local name
  name="$(basename "$target")"
  local out="$OUTBASE/$name"
  local args=(--profile "$PROFILE" --out "$out")
  [ -n "$GREP" ] && args+=(--grep "$GREP")

  printf '  %-40s ' "$name"
  if bash "$PIPELINE" "${args[@]}" "$target" > "$OUTBASE/$name.run.log" 2>&1; then
    local kind ok err
    kind="$(node -e 'try{process.stdout.write(require(process.argv[1]).target.kind||"?")}catch(e){process.stdout.write("?")}' "$out/summary.json" 2>/dev/null)"
    ok="$(node -e 'try{process.stdout.write(String(require(process.argv[1]).counts.steps_ok))}catch(e){process.stdout.write("?")}' "$out/summary.json" 2>/dev/null)"
    err="$(node -e 'try{process.stdout.write(String(require(process.argv[1]).counts.steps_error))}catch(e){process.stdout.write("?")}' "$out/summary.json" 2>/dev/null)"
    printf 'ok  (kind=%s, %s ok / %s error)\n' "${kind:-?}" "${ok:-?}" "${err:-?}"
    printf '| `%s` | %s | %s | %s | [report](%s/report.md) |\n' \
      "$name" "${kind:-?}" "${ok:-?}" "${err:-?}" "$name" >> "$INDEX"
  else
    printf 'FAILED (see %s.run.log)\n' "$name"
    printf '| `%s` | — | — | — | failed |\n' "$name" >> "$INDEX"
  fi
}

echo "lab: $TARGET_DIR -> $OUTBASE (profile: $PROFILE)"
echo

if [ -f "$TARGET_DIR" ]; then
  run_one "$TARGET_DIR"
else
  count=0
  for f in "$TARGET_DIR"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in README*|*.md|*.txt) continue ;; esac
    run_one "$f"
    count=$((count+1))
  done
  echo
  echo "$count target(s) processed"
fi

echo
echo "index: $INDEX"
