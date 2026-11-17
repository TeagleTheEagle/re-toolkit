#!/usr/bin/env bash
#
# env-report.sh — report which reverse-engineering capabilities this machine
# actually has, and what each one costs.
#
#   ./env-report.sh
#
# Every line is measured on the local machine at run time. Nothing is assumed.
# Output is markdown so it can be pasted into a report or a wiki page; there is
# deliberately no JSON mode.

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
ver()  { "$1" --version 2>/dev/null | head -n 1; }

printf '# Reverse-Engineering Capability Report\n\n'
printf '_Generated %s on %s_\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(uname -sr 2>/dev/null || echo unknown)"
printf '| Capability | Present | Detail |\n| --- | --- | --- |\n'

row() {
  local cap="$1" present="$2" detail="$3"
  printf '| %s | %s | %s |\n' "$cap" "$present" "$detail"
}

# --- REA engine ---------------------------------------------------------
if have rea; then
  RVER="$(rea --version 2>/dev/null | head -n 1)"
  row "REA engine" "yes" "\`$RVER\`"
  row "REA commands" "yes" "$(rea --help 2>/dev/null | grep -cE '^  [a-z][a-z0-9-]+ ' ) commands"
else
  row "REA engine" "no" "install: npm i -g rea-agents"
fi

# --- Analysis engines (via REA doctor) ----------------------------------
if have rea; then
  DOC="$(rea doctor --json 2>/dev/null)"
  ENGINES="$(printf '%s' "$DOC" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{
        const j=JSON.parse(s);
        const ids=(j.providerInspections||[]).map(p=>`${p.id}:${p.available?"available":"missing"}`).join(", ");
        const skill=(j.identity&&j.identity.skill)||{};
        process.stdout.write(`${ids} — skill v${skill.installed_version} (${skill.installed_tool_count} tools, ${skill.state})`);
      }catch(e){process.stdout.write("doctor output unreadable");}
    });')"
  row "REA providers" "yes" "$ENGINES"
else
  row "REA providers" "no" "run rea doctor after installing REA"
fi

# --- Local toolchain ----------------------------------------------------
for t in strings objdump readelf nm ar file; do
  if have "$t"; then row "binutils:$t" "yes" "\`$t\`"; else row "binutils:$t" "no" "-"; fi
done

if have gdb; then row "gdb" "yes" "\`$(ver gdb)\`"; else row "gdb" "no" "winget install BrechtSanders.WinLibs.POSIX.UCRT"; fi
if have gdb; then
  if gdb -batch -ex quit >/dev/null 2>&1; then row "gdb batch mode" "yes" "usable"; else row "gdb batch mode" "no" "startup error"; fi
fi
if have objdump; then
  if objdump --version >/dev/null 2>&1; then row "objdump target list" "yes" "\`$(objdump --version | head -n1)\`"; fi
fi

for t in r2 radare2 rizin rz-bin cutter; do
  if have "$t"; then row "$t" "yes" "\`$(ver $t)\`"; else row "$t" "no" "-"; fi
done

if have openssl; then
  row "openssl" "yes" "\`$(ver openssl)\`"
else
  row "openssl" "no" "-"
fi

for t in binwalk docker tshark wireshark tcpdump; do
  if have "$t"; then row "$t" "yes" "\`$(ver $t)\`"; else row "$t" "no" "-"; fi
done

for t in java javac; do
  if have "$t"; then row "$t" "yes" "\`$(ver java)\`"; else row "$t" "no" "-"; fi
done

for t in python3 python; do
  if have "$t"; then row "$t" "yes" "\`$(ver $t)\`"; else row "$t" "no" "-"; fi
done

for t in node npm npx; do
  if have "$t"; then row "$t" "yes" "\`$(ver $t)\`"; else row "$t" "no" "-"; fi
done

for t in gcc g++ clang make cmake; do
  if have "$t"; then row "$t" "yes" "\`$(ver $t)\`"; else row "$t" "no" "-"; fi
done

for t in pandoc xelatex pdfunite wkhtmltopdf; do
  if have "$t"; then row "$t" "yes" "\`$(ver $t)\`"; else row "$t" "no" "-"; fi
done

# --- Headless browser (PDF fallback) -----------------------------------
EDGE="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
CHROME="/c/Program Files/Google/Chrome/Application/chrome.exe"
if [ -f "$EDGE" ]; then row "headless browser" "yes" "Edge (PDF export available)"; fi
if [ -f "$CHROME" ]; then row "headless browser" "yes" "Chrome (PDF export available)"; fi

# --- REA's own tool directories ----------------------------------------
if [ -d "$HOME/rea-tools" ]; then
  find "$HOME/rea-tools" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | while read -r d; do
    row "rea-tools" "yes" "$(basename "$d")"
  done
fi

# --- Skill installs -----------------------------------------------------
printf '\n## REA skill installs\n\n'
printf '| Path | Version | Tools |\n| --- | --- | --- |\n'
find "$HOME/.agents" "$HOME/.claude" "$HOME/AppData/Local/hermes/skills" \
     -path '*reverse-engineer-anything/SKILL.md' 2>/dev/null | while read -r f; do
  v="$(sed -n 's/^  version: *"\(.*\)"/\1/p' "$f" 2>/dev/null | head -n1)"
  t="$(sed -n 's/^  tool_count: *\(.*\)/\1/p' "$f" 2>/dev/null | head -n1)"
  printf '| `%s` | %s | %s |\n' "$f" "${v:-?}" "${t:-?}"
done
