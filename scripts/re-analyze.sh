#!/usr/bin/env bash
#
# re-analyze.sh — programmable reverse-engineering pipeline for ANY target.
#
#   ./re-analyze.sh [options] <target>
#
# What it does
#   1. Classifies the target from magic bytes (no execution).
#   2. Picks the REA inspection operations that apply to that artifact kind.
#   3. Runs them, capturing every command's JSON evidence, log and status.
#   4. Adds local-tool triage (strings, objdump, readelf, nm, entropy).
#   5. Emits summary.json + report.md.
#
# Safety
#   The target is NEVER executed unless you pass --allow-exec. Dynamic
#   debugging (gdb) is opt-in for that reason.
#
# Exit codes
#   0  pipeline completed (individual steps may have failed; see summary.json)
#   2  usage error
#   3  target not found
#   4  no analysis engine available (neither REA nor local binutils)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ---------------------------------------------------------------- defaults
PROFILE="standard"
OUT_DIR=""
TARGET=""
KIND="auto"            # auto | force a kind
CONFIG=""
ALLOW_EXEC=0
DECOMPILE_ALL=0
KEEP_GOING=1
TIMEOUT_SECS=900
EXTRA_COMMANDS=""
STEP_FILTER=""
GREP_PATTERNS=""

usage() {
  cat <<'EOF'
re-analyze.sh — programmable RE pipeline for any target

USAGE
  re-analyze.sh [options] <target>

OPTIONS
  --profile <quick|standard|deep>  Step depth (default: standard)
      quick    detection + overview + 3 kind-specific inspections
      standard detection + overview + all kind-specific inspections
      deep     standard + decompile-all + string triage + optional gdb
  --out <dir>        Output directory (default: ./<target>_analysis)
  --config <file>    JSON config file (see docs/RE-Cookbook.md)
  --kind <kind>      Force target kind instead of auto-detection
  --step <regex>     Only run steps whose name matches this regex
  --extra <cmd,cmd>  Extra REA commands to run (comma separated)
  --grep <pat,pat>   String triage patterns (case-insensitive substring)
  --timeout <secs>   Per-command timeout (default: 900)
  --decompile-all    Force decompile-all step
  --allow-exec       Permit dynamic steps that execute the target (gdb)
  --strict           Stop at the first failing step
  --doctor           Print the capability report and exit
  -h, --help         This help

EXAMPLES
  ./re-analyze.sh ./app.exe
  ./re-analyze.sh --profile deep --grep 'api_key,password' ./app.exe
  ./re-analyze.sh --config ./my-profile.json ./lib.so
EOF
}

# ---------------------------------------------------------------- cli
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-}"; shift 2 ;;
    --step) STEP_FILTER="${2:-}"; shift 2 ;;
    --extra) EXTRA_COMMANDS="${2:-}"; shift 2 ;;
    --grep) GREP_PATTERNS="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECS="${2:-}"; shift 2 ;;
    --decompile-all) DECOMPILE_ALL=1; shift ;;
    --allow-exec) ALLOW_EXEC=1; shift ;;
    --strict) KEEP_GOING=0; shift ;;
    --doctor) DOCTOR_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "node is required (REA needs Node 20+)" >&2; exit 4; }

# ---------------------------------------------------------------- config
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }
  cfg="$(node -e '
    const fs = require("fs");
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const pick = (k, d) => (c[k] === undefined ? d : c[k]);
    const out = {
      profile: pick("profile", ""),
      kind: pick("kind", ""),
      step: pick("step", ""),
      extra: pick("extra", []),
      grep: pick("grep", []),
      timeoutSeconds: pick("timeoutSeconds", 0),
      decompileAll: pick("decompileAll", false),
      allowExec: pick("allowExec", false),
    };
    process.stdout.write(JSON.stringify(out));
  ' "$CONFIG")" || { echo "invalid config JSON: $CONFIG" >&2; exit 2; }

  get() { node -e 'const c=JSON.parse(process.argv[1]);const v=c[process.argv[2]];process.stdout.write(v===undefined||v===null?"":(Array.isArray(v)?v.join(","):String(v)))' "$cfg" "$1"; }

  [ -n "$(get profile)" ] && PROFILE="$(get profile)"
  [ -n "$(get kind)" ] && KIND="$(get kind)"
  [ -n "$(get step)" ] && STEP_FILTER="$(get step)"
  [ -n "$(get extra)" ] && EXTRA_COMMANDS="$EXTRA_COMMANDS,$(get extra)"
  [ -n "$(get grep)" ] && GREP_PATTERNS="${GREP_PATTERNS:+$GREP_PATTERNS,}$(get grep)"
  [ -n "$(get timeoutSeconds)" ] && TIMEOUT_SECS="$(get timeoutSeconds)"
  [ "$(get decompileAll)" = "true" ] && DECOMPILE_ALL=1
  [ "$(get allowExec)" = "true" ] && ALLOW_EXEC=1
fi

case "$PROFILE" in
  quick|standard|deep) ;;
  *) echo "invalid profile: $PROFILE (quick|standard|deep)" >&2; exit 2 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
REA=""; have rea && REA="rea"

if [ "${DOCTOR_ONLY:-0}" = "1" ]; then
  exec "$SCRIPT_DIR/env-report.sh"
fi

[ -n "$TARGET" ] || { usage >&2; exit 2; }
[ -e "$TARGET" ] || { echo "target not found: $TARGET" >&2; exit 3; }

TARGET_ABS="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
BASE="$(basename "$TARGET")"
[ -n "$OUT_DIR" ] || OUT_DIR="${PWD}/${BASE}_analysis"
mkdir -p "$OUT_DIR/steps"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

START_TS="$(date +%s)"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_DIR/pipeline.log"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_DIR/pipeline.log" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_DIR/pipeline.log" >&2; exit "${2:-1}"; }

have_binutils=0
for t in strings objdump readelf nm; do have "$t" && have_binutils=1; done

if [ -z "$REA" ] && [ "$have_binutils" = "0" ]; then
  die "no analysis engine available: install REA (npm i -g rea-agents) or binutils" 4
fi

# ---------------------------------------------------------------- step runner
STEP_NAMES=()
STEP_RESULTS=()

# Steps whose non-zero exit can still mean "nothing to report". A stripped
# binary genuinely has no symbols; recording that as an error would make every
# stripped target look broken. TOOL_TOLERATED_RC holds the exit codes that are
# acceptable, and TOOL_TOLERATED_PAT matches acceptable stderr.
TOOL_TOLERATED_RC=""
TOOL_TOLERATED_PAT=""

run_step() {
  local name="$1"; shift

  if [ -n "$STEP_FILTER" ] && ! printf '%s' "$name" | grep -Eq "$STEP_FILTER"; then
    printf 'skipped' > "$OUT_DIR/steps/$name.status"
    return 0
  fi

  log "run: $name"
  local out="$OUT_DIR/steps/$name.json"
  local err="$OUT_DIR/steps/$name.log"
  local rc=0

  if [ "$ALLOW_EXEC" = "0" ] && printf '%s' "$name" | grep -q '^dynamic-'; then
    printf 'skipped' > "$OUT_DIR/steps/$name.status"
    warn "$name skipped (needs --allow-exec)"
    return 0
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" "$@" > "$out" 2> "$err" || rc=$?
  else
    "$@" > "$out" 2> "$err" || rc=$?
  fi

  local tolerated=0
  if [ "$rc" -ne 0 ] && [[ ":$TOOL_TOLERATED_RC:" == *":$rc:"* ]]; then
    if [ -z "$TOOL_TOLERATED_PAT" ] || grep -qiE "$TOOL_TOLERATED_PAT" "$err" 2>/dev/null; then
      tolerated=1
    fi
  fi

  # A tolerated non-zero exit, or a zero exit with nothing on stdout, both mean
  # "the tool ran and had nothing to report" — nm on a stripped image is the
  # usual case. Record the finding so it reaches the report instead of looking
  # like an empty failure.
  if [ ! -s "$out" ] && { [ "$rc" -eq 0 ] || [ "$tolerated" -eq 1 ]; }; then
    {
      printf '{"operation":"local-tool","tool":"%s","finding":"nothing to report","exit_code":%s,"stderr":"' "$name" "$rc"
      head -n 3 "$err" 2>/dev/null | tr '\n' ' ' | sed 's/["\\]/ /g' | tr -s ' '
      printf '"}\n'
    } > "$out"
  fi

  if { [ "$rc" -eq 0 ] || [ "$tolerated" -eq 1 ]; } && [ -s "$out" ]; then
    printf 'ok' > "$OUT_DIR/steps/$name.status"
    STEP_NAMES+=("$name"); STEP_RESULTS+=("ok")
    if [ "$tolerated" -eq 1 ]; then
      log "  ok: $name (nothing to report; rc=$rc)"
    else
      log "  ok: $name"
    fi
  elif [ "$rc" -eq 124 ]; then
    printf 'error' > "$OUT_DIR/steps/$name.status"
    warn "$name timed out after ${TIMEOUT_SECS}s"
    [ "$KEEP_GOING" = "1" ] || die "$name timed out" 1
  else
    printf 'error' > "$OUT_DIR/steps/$name.status"
    warn "$name failed (rc=$rc): $(head -n 1 "$err" 2>/dev/null)"
    [ "$KEEP_GOING" = "1" ] || die "$name failed" 1
  fi
}

# Run a step whose non-zero exit may mean "nothing to report".
tolerant_step() {
  local rc_list="$1" pat="$2"; shift 2
  local saved_rc="$TOOL_TOLERATED_RC" saved_pat="$TOOL_TOLERATED_PAT"
  TOOL_TOLERATED_RC="$rc_list"
  TOOL_TOLERATED_PAT="$pat"
  run_step "$@"
  TOOL_TOLERATED_RC="$saved_rc"
  TOOL_TOLERATED_PAT="$saved_pat"
}

# ---------------------------------------------------------------- 1. detect
log "target: $TARGET_ABS"
if ! node "$LIB_DIR/detect.mjs" "$TARGET_ABS" > "$OUT_DIR/detect.json" 2> "$LOG_DIR/detect.err"; then
  warn "detection failed; falling back to generic kind"
  cat > "$OUT_DIR/detect.json" <<EOF
{"path":"$TARGET_ABS","name":"$BASE","kind":"generic","format":"unknown","architecture":"unknown","reason":"detection failed","commands":[]}
EOF
fi
KIND_DETECTED="$(node -e 'process.stdout.write(require(process.argv[1]).kind||"generic")' "$OUT_DIR/detect.json")"
ARCH="$(node -e 'process.stdout.write(require(process.argv[1]).architecture||"unknown")' "$OUT_DIR/detect.json")"
SHA="$(node -e 'process.stdout.write(require(process.argv[1]).sha256||"")' "$OUT_DIR/detect.json")"
log "detected kind=$KIND_DETECTED arch=$ARCH sha256=${SHA:0:16}…"

EFFECTIVE_KIND="$KIND_DETECTED"
[ "$KIND" != "auto" ] && EFFECTIVE_KIND="$KIND"
[ "$EFFECTIVE_KIND" != "$KIND_DETECTED" ] && warn "forcing kind=$EFFECTIVE_KIND (detected $KIND_DETECTED)"

# ---------------------------------------------------------------- 2. local triage
run_step "local-file"   file "$TARGET_ABS"

# sha256: pick whichever implementation this host provides
if have sha256sum; then
  run_step "local-sha256" sha256sum "$TARGET_ABS"
elif have shasum; then
  run_step "local-sha256" shasum -a 256 "$TARGET_ABS"
elif have openssl; then
  run_step "local-sha256" openssl dgst -sha256 "$TARGET_ABS"
fi

if have strings; then
  run_step "local-strings" strings -a -n 6 "$TARGET_ABS"
fi

# objdump/nm understand both PE and ELF; readelf is ELF-only, so gate it.
case "$EFFECTIVE_KIND" in
  pe|elf|macho|go|rust|managed|dotnet)
    have objdump && run_step "local-objdump" objdump -x "$TARGET_ABS"
    # nm exits 1 when a stripped image has no symbols; that is a finding.
    have nm && tolerant_step "1" 'no symbols|no name list|file format not recognized' \
                    "local-nm" nm -A "$TARGET_ABS"
    ;;
esac
case "$EFFECTIVE_KIND" in
  elf)
    have readelf && run_step "local-readelf" readelf -a "$TARGET_ABS"
    ;;
esac

# ---------------------------------------------------------------- 3. REA steps
if [ -n "$REA" ]; then
  log "engine: $($REA --version 2>/dev/null || echo unknown)"

  run_step "rea-analyze" rea analyze "$TARGET_ABS" --format json

  # kind-specific inspection commands
  CMDS="$(node -e '
    const d = require(process.argv[1]);
    const kind = process.argv[2] || d.kind;
    const table = {
      pe:["inspect-binary-hardening","inspect-pe-imports","inspect-pe-resources","inspect-pe-certificates","inspect-pe-load-config","inspect-native-exports","inspect-native-load-image","inspect-native-api","inspect-byte-entropy","inspect-with-objdump"],
      elf:["inspect-binary-layout","inspect-binary-hardening","inspect-elf-notes","inspect-elf-unwind-ranges","inspect-native-exports","inspect-native-load-image","inspect-native-api","inspect-byte-entropy","inspect-with-objdump"],
      macho:["inspect-binary-layout","inspect-binary-hardening","inspect-macho","inspect-native-exports","inspect-native-load-image","inspect-native-api","inspect-byte-entropy"],
      go:["inspect-go-binary","inspect-native-exports","inspect-byte-entropy"],
      rust:["inspect-rust-binary","inspect-native-exports","inspect-byte-entropy"],
      managed:["inspect-managed-artifact","inspect-managed-members","inspect-managed-native-boundaries","inspect-byte-entropy"],
      dotnet:["inspect-managed-artifact","inspect-managed-members","inspect-byte-entropy"],
      wasm:["inspect-wasm-artifact","inspect-byte-entropy"],
      python_pyc:["inspect-python-pyc","inspect-byte-entropy"],
      apk:["inspect-android-package","inspect-apk-signature","inspect-android-jni-bindings"],
      android_dex:["inspect-android-class","inspect-android-method"],
      image:["inspect-byte-entropy"],
      firmware:["inspect-firmware-regions","inspect-kernel-build-config","inspect-byte-entropy"],
      archive:["inspect-artifact","inspect-byte-entropy"],
      jsbundle:["inspect-artifact","inspect-byte-entropy"],
      sqlite:["inspect-sqlite-database","inspect-byte-entropy"],
      generic:["inspect-artifact","inspect-byte-entropy"]
    };
    let list = table[kind] || table.generic;
    const profile = process.argv[3];
    if (profile === "quick") list = list.slice(0, 3);
    process.stdout.write(list.join("\n"));
  ' "$OUT_DIR/detect.json" "$EFFECTIVE_KIND" "$PROFILE")"

  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    run_step "rea-$cmd" rea "$cmd" "$TARGET_ABS" --format json
  done <<< "$CMDS"

  # extras from --extra / config
  if [ -n "$EXTRA_COMMANDS" ]; then
    IFS=',' read -ra EXTRAS <<< "$EXTRA_COMMANDS"
    for cmd in "${EXTRAS[@]}"; do
      cmd="$(printf '%s' "$cmd" | tr -d ' ')"
      [ -z "$cmd" ] && continue
      run_step "rea-$cmd" rea "$cmd" "$TARGET_ABS" --format json
    done
  fi

  if [ "$DECOMPILE_ALL" = "1" ] || [ "$PROFILE" = "deep" ]; then
    DEC_DIR="$OUT_DIR/decompiled"
    mkdir -p "$DEC_DIR"
    log "run: rea-decompile-all"
    if rea decompile-all "$TARGET_ABS" --output "$DEC_DIR" --format json > "$OUT_DIR/steps/rea-decompile-all.json" 2> "$OUT_DIR/steps/rea-decompile-all.log"; then
      printf 'ok' > "$OUT_DIR/steps/rea-decompile-all.status"
    else
      printf 'error' > "$OUT_DIR/steps/rea-decompile-all.status"
      warn "decompile-all failed (rc=$?)"
    fi
  fi
else
  warn "REA not on PATH — static REA steps skipped"
fi

# ---------------------------------------------------------------- 4. string triage
if [ -n "$GREP_PATTERNS" ]; then
  log "string triage for: $GREP_PATTERNS"
  printf 'ok' > "$OUT_DIR/steps/local-triage.status"
  : > "$OUT_DIR/steps/local-triage.log"
  TRIAGE_JSON="$OUT_DIR/steps/local-triage.json"
  printf '{"operation":"string_triage","patterns":[' > "$TRIAGE_JSON"
  first=1
  IFS=',' read -ra PATS <<< "$GREP_PATTERNS"
  STRINGS_FILE="$OUT_DIR/steps/local-strings.json"
  for p in "${PATS[@]}"; do
    p="$(printf '%s' "$p" | tr -d ' ')"
    [ -z "$p" ] && continue
    hits=0
    samples=""
    if [ -s "$STRINGS_FILE" ]; then
      # grep -c exits 1 when it counts zero matches, so read the count from
      # stdout alone instead of using `|| echo 0`, which would append a second
      # number and produce invalid JSON.
      hits="$(grep -ic -- "$p" "$STRINGS_FILE" 2>/dev/null | head -n 1)"
      case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
      samples="$(grep -i -- "$p" "$STRINGS_FILE" 2>/dev/null | head -n 10 | sed 's/"/\\"/g' | cut -c1-120 | paste -sd'|' -)"
    fi
    [ $first -eq 1 ] || printf ',' >> "$TRIAGE_JSON"
    first=0
    printf '{"pattern":"%s","hits":%s,"samples":"%s"}' "$p" "$hits" "$samples" >> "$TRIAGE_JSON"
    printf '%-24s %s hits\n' "$p" "$hits" | tee -a "$OUT_DIR/steps/local-triage.log"
    if [ -n "$samples" ]; then
      printf '%s' "$samples" | tr '|' '\n' | sed 's/^/    /' >> "$OUT_DIR/steps/local-triage.log"
    fi
  done
  printf ']}\n' >> "$TRIAGE_JSON"
fi

# ---------------------------------------------------------------- 5. dynamic (opt-in)
if [ "$ALLOW_EXEC" = "1" ] && have gdb; then
  run_step "dynamic-gdb-backtrace" gdb -batch -ex "file $TARGET_ABS" -ex "break main" -ex run -ex bt -ex quit
elif [ "$ALLOW_EXEC" = "1" ]; then
  warn "--allow-exec given but gdb is not installed; dynamic steps skipped"
fi

# ---------------------------------------------------------------- 6. report
log "building report"
node "$LIB_DIR/report.mjs" "$OUT_DIR" --out "$OUT_DIR" >> "$LOG_DIR/pipeline.log" 2>&1

END_TS="$(date +%s)"
printf 'duration_seconds: %s\n' "$((END_TS-START_TS))" > "$OUT_DIR/timing.txt"

OK_COUNT=$(grep -l '^ok$' "$OUT_DIR"/steps/*.status 2>/dev/null | wc -l | tr -d ' ')
ERR_COUNT=$(grep -l '^error$' "$OUT_DIR"/steps/*.status 2>/dev/null | wc -l | tr -d ' ')
SKIP_COUNT=$(grep -l '^skipped$' "$OUT_DIR"/steps/*.status 2>/dev/null | wc -l | tr -d ' ')

echo
echo "──────────────────────────────────────────────────────────────"
echo " Target    : $BASE ($EFFECTIVE_KIND / $ARCH)"
echo " SHA-256   : $SHA"
echo " Output    : $OUT_DIR"
echo " Steps     : $OK_COUNT ok · $ERR_COUNT error · $SKIP_COUNT skipped"
echo " Report    : $OUT_DIR/report.md"
echo " Summary   : $OUT_DIR/summary.json"
echo " Duration  : $((END_TS-START_TS))s"
echo "──────────────────────────────────────────────────────────────"
exit 0
