#!/usr/bin/env bash
#
# test-toolkit.sh — prove the toolkit works on this machine.
#
#   ./test-toolkit.sh          run every test
#   ./test-toolkit.sh --fast   skip the slow engine test
#
# Tests are ordered cheapest-first so a broken environment fails immediately
# instead of after a Ghidra cold start.
#
# Each test prints PASS/FAIL and the suite exits non-zero if any test fails.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  SKIP  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; SKIP=$((SKIP+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ fixtures
# A tiny PE built here rather than committed, so the test does not depend on a
# binary in the repo and works on a fresh clone.
make_fixture() {
  local src="$TMP/hello.c" out="$TMP/hello$1"
  printf '%s\n' \
    '#include <stdio.h>' \
    'static const char *SECRET = "PASSWORD=hunter2";' \
    'int main(int c, char **v) { printf("%s %d\n", SECRET, c); return 0; }' \
    > "$src"
  if have gcc; then gcc -g -O0 -o "$out" "$src" 2>/dev/null && { printf '%s' "$out"; return 0; }; fi
  return 1
}

section() { printf '\n%s\n' "$1"; }

# ================================================================== 1. syntax
section "1. script syntax"
for f in "$ROOT"/scripts/*.sh; do
  if bash -n "$f" 2>"$TMP/syn.err"; then pass "$(basename "$f")"; else fail "$(basename "$f")" "$(head -2 "$TMP/syn.err")"; fi
done
for f in "$ROOT"/scripts/lib/*.mjs; do
  if node --check "$f" 2>"$TMP/syn.err"; then pass "$(basename "$f")"; else fail "$(basename "$f")" "$(head -2 "$TMP/syn.err")"; fi
done

# ================================================================== 2. detect
section "2. target classification"
FIXTURE="$(make_fixture .exe)" || FIXTURE=""
if [ -z "$FIXTURE" ]; then
  skip "PE classification" "no gcc to build a fixture"
else
  if node "$ROOT/scripts/lib/detect.mjs" "$FIXTURE" > "$TMP/detect.json" 2>"$TMP/detect.err"; then
    kind="$(node -e 'process.stdout.write(require(process.argv[1]).kind)' "$TMP/detect.json")"
    arch="$(node -e 'process.stdout.write(require(process.argv[1]).architecture)' "$TMP/detect.json")"
    sha="$(node -e 'process.stdout.write(require(process.argv[1]).sha256)' "$TMP/detect.json")"
    [ "$kind" = "pe" ] && pass "kind=pe detected" || fail "kind=pe detected" "got '$kind'"
    [ "$arch" = "x86_64" ] && pass "arch=x86_64 detected" || fail "arch=x86_64 detected" "got '$arch'"
    [ "${#sha}" -eq 64 ] && pass "sha256 is 64 hex chars" || fail "sha256 is 64 hex chars" "got '$sha'"
  else
    fail "detect.mjs ran" "$(head -2 "$TMP/detect.err")"
  fi

  # Non-PE inputs must not be misclassified.
  printf '\x7fELF\x02\x01\x01\x00' > "$TMP/fake.elf"
  if node "$ROOT/scripts/lib/detect.mjs" "$TMP/fake.elf" 2>/dev/null | grep -q '"kind": "elf"'; then
    pass "ELF magic classified as elf"
  else
    fail "ELF magic classified as elf"
  fi
  printf '#!/bin/sh\necho hi\n' > "$TMP/fake.sh"
  if node "$ROOT/scripts/lib/detect.mjs" "$TMP/fake.sh" 2>/dev/null | grep -q '"kind": "script"'; then
    pass "shebang classified as script"
  else
    fail "shebang classified as script"
  fi
  if node "$ROOT/scripts/lib/detect.mjs" "$TMP/nonexistent" >/dev/null 2>&1; then
    fail "missing target exits non-zero"
  else
    pass "missing target exits non-zero"
  fi
fi

# ================================================================== 3. report
section "3. report generation"
mkdir -p "$TMP/rep/steps"
cat > "$TMP/rep/detect.json" <<'JSON'
{"path":"/x/app.exe","name":"app.exe","size":10,"sha256":"ab","kind":"pe","format":"pe","architecture":"x86_64","reason":"test"}
JSON
cat > "$TMP/rep/steps/rea-analyze.json" <<'JSON'
{"evidence_id":"ev_test","predicate_type":"rea.analysis","operation":"binary_overview","confidence":"observed","authority":"shipped-artifact","digest":"deadbeef","normalized_result":{"procedure_count":7,"string_count":3},"limitations":["a limit"]}
JSON
printf 'ok' > "$TMP/rep/steps/rea-analyze.status"
printf '/x/app.exe: PE32+ executable\n' > "$TMP/rep/steps/local-file.json"
printf 'ok' > "$TMP/rep/steps/local-file.status"
if node "$ROOT/scripts/lib/report.mjs" "$TMP/rep" >/dev/null 2>"$TMP/rep.err"; then
  [ -f "$TMP/rep/report.md" ] && pass "report.md written" || fail "report.md written"
  [ -f "$TMP/rep/summary.json" ] && pass "summary.json written" || fail "summary.json written"
  grep -q 'ev_test' "$TMP/rep/report.md" && pass "evidence id appears in report" || fail "evidence id appears in report"
  grep -q 'procedure_count' "$TMP/rep/report.md" && pass "observed facts appear in report" || fail "observed facts appear in report"
  node -e 'const s=require(process.argv[1]);if(s.counts.steps_ok!==2)process.exit(1)' "$TMP/rep/summary.json" \
    && pass "two ok steps counted" || fail "two ok steps counted"
else
  fail "report.mjs ran" "$(head -3 "$TMP/rep.err")"
fi

# ================================================================== 4. md2html
section "4. markdown rendering"
cat > "$TMP/doc.md" <<'MD'
# Title

Intro with `code` and **bold** and a [link](https://example.com).

| A | B |
| --- | --- |
| 1 | 2 |

```bash
echo hi
```

- one
- two
MD
if node "$ROOT/scripts/lib/md2html.mjs" "$TMP/doc.md" "$TMP/doc.html" 2>/dev/null; then
  grep -q '<h1>Title</h1>' "$TMP/doc.html" && pass "heading rendered" || fail "heading rendered"
  grep -q '<table>' "$TMP/doc.html" && pass "table rendered" || fail "table rendered"
  grep -q '<code>code</code>' "$TMP/doc.html" && pass "inline code rendered" || fail "inline code rendered"
  grep -q 'language-bash' "$TMP/doc.html" && pass "fenced code rendered" || fail "fenced code rendered"
  grep -q '<li>one</li>' "$TMP/doc.html" && pass "list rendered" || fail "list rendered"
  grep -q 'href="https://example.com"' "$TMP/doc.html" && pass "link rendered" || fail "link rendered"
else
  fail "md2html.mjs ran"
fi

# ================================================================== 5. env
section "5. capability report"
if bash "$ROOT/scripts/env-report.sh" > "$TMP/env.md" 2>"$TMP/env.err"; then
  grep -q '| Capability | Present | Detail |' "$TMP/env.md" && pass "capability table produced" || fail "capability table produced"
  grep -q 'REA engine' "$TMP/env.md" && pass "REA row present" || fail "REA row present"
else
  fail "env-report.sh ran" "$(head -2 "$TMP/env.err")"
fi

# ================================================================== 6. pipeline
section "6. pipeline end-to-end"
if [ "$FAST" = "1" ]; then
  skip "re-analyze.sh run" "--fast"
elif [ -z "$FIXTURE" ]; then
  skip "re-analyze.sh run" "no gcc to build a fixture"
else
  OUT="$TMP/out"
  # Run the cheap profile: this still exercises detection, local tools,
  # step recording and reporting. It uses REA only if it is installed.
  if bash "$ROOT/scripts/re-analyze.sh" --profile quick --out "$OUT" "$FIXTURE" >"$TMP/run.log" 2>&1; then
    [ -f "$OUT/report.md" ] && pass "report.md produced" || fail "report.md produced"
    [ -f "$OUT/summary.json" ] && pass "summary.json produced" || fail "summary.json produced"
    [ -f "$OUT/detect.json" ] && pass "detect.json produced" || fail "detect.json produced"
    ok="$(node -e 'process.stdout.write(String(require(process.argv[1]).counts.steps_ok))' "$OUT/summary.json" 2>/dev/null)"
    if [ -n "$ok" ] && [ "$ok" -ge 3 ]; then pass "at least 3 steps succeeded ($ok)"; else fail "at least 3 steps succeeded" "got '$ok'"; fi
    if grep -q 'hunter2' "$OUT/steps/local-strings.json" 2>/dev/null || grep -q 'PASSWORD' "$OUT/report.md" 2>/dev/null; then
      pass "fixture string recovered"
    else
      fail "fixture string recovered" "PASSWORD=hunter2 not found in artifacts"
    fi
  else
    fail "re-analyze.sh ran" "$(tail -3 "$TMP/run.log")"
  fi

  # String triage must produce structured output.
  if bash "$ROOT/scripts/re-analyze.sh" --profile quick --grep 'PASSWORD,zzz_no_such_pattern_zzz' --out "$TMP/out2" "$FIXTURE" >/dev/null 2>&1; then
    TRIAGE="$TMP/out2/steps/local-triage.json"
    if [ -s "$TRIAGE" ] && node -e '
      const fs=require("fs");
      const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const hit=j.patterns.find(p=>/password/i.test(p.pattern));
      process.exit(hit && hit.hits>0 ? 0 : 1);
    ' "$TRIAGE" 2>/dev/null; then
      pass "string triage found the pattern"
    else
      fail "string triage found the pattern" "no hit recorded for /password/i"
    fi

    # Regression: a zero-match pattern must yield a single count. grep -c exits
    # 1 on zero matches, and `|| echo 0` used to append a second number, which
    # produced invalid JSON.
    node -e '
      const fs=require("fs");
      const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const miss=j.patterns.find(p=>p.hits===0);
      process.exit(miss ? 0 : 1);
    ' "$TRIAGE" 2>/dev/null       && pass "triage JSON valid with zero-match patterns"       || fail "triage JSON valid with zero-match patterns" "invalid JSON or no zero-hit entry"
  else
    fail "triage run completed"
  fi
fi

# ================================================================== 7. errors
section "7. error handling"
bash "$ROOT/scripts/re-analyze.sh" /nonexistent/target >/dev/null 2>&1
[ $? -eq 3 ] && pass "missing target exits 3" || fail "missing target exits 3"
bash "$ROOT/scripts/re-analyze.sh" --profile bogus . >/dev/null 2>&1
[ $? -eq 2 ] && pass "bad profile exits 2" || fail "bad profile exits 2"
bash "$ROOT/scripts/re-analyze.sh" --no-such-flag . >/dev/null 2>&1
[ $? -eq 2 ] && pass "unknown flag exits 2" || fail "unknown flag exits 2"

# ================================================================== 8. skill
section "8. skill consistency"
if bash "$ROOT/scripts/skill-sync.sh" --list >"$TMP/skill.txt" 2>&1; then
  grep -q 'canonical' "$TMP/skill.txt" && pass "canonical copy located" || skip "canonical copy located" "no rea checkout on this machine"
else
  fail "skill-sync.sh --list ran"
fi
[ -f "$ROOT/.pi/skills/reverse-engineering-suite/SKILL.md" ] \
  && pass "composite skill present" || fail "composite skill present"
grep -q '^name: reverse-engineering-suite' "$ROOT/.pi/skills/reverse-engineering-suite/SKILL.md" 2>/dev/null \
  && pass "skill frontmatter valid" || fail "skill frontmatter valid"

# ================================================================== summary
printf '\n──────────────────────────────────────────────\n'
printf ' %s passed · %s failed · %s skipped\n' "$PASS" "$FAIL" "$SKIP"
printf '──────────────────────────────────────────────\n'
[ "$FAIL" -eq 0 ]
