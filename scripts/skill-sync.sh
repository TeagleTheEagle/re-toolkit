#!/usr/bin/env bash
#
# skill-sync.sh — manage the canonical REA skill copy.
#
#   ./skill-sync.sh --list      show every copy, its version, and its status
#   ./skill-sync.sh --verify    compare every copy against the canonical one
#   ./skill-sync.sh --sync      copy canonical -> user-owned installs
#   ./skill-sync.sh --prune     remove stale copies (disabled/backup only)
#
# Why this exists
#   The `reverse-engineer-anything` skill is installed by several different
#   harnesses (pi, Claude Code, Hermes, dsh) and is also published to npm.
#   Those copies are NOT duplicates to be deleted — each harness needs its own
#   install, and npm regenerates its copy on install. The one real risk is
#   drift: a copy edited by hand diverges from the canonical source and the
#   agent then runs against stale instructions.
#
#   Canonical source of truth:
#     $REA_SKILL_SOURCE (default: the git checkout of morluto/rea)
#
#   Install copies (may be written to):
#     ~/.agents/skills/reverse-engineer-anything       (pi)
#     ~/.claude/skills/reverse-engineer-anything       (Claude Code)
#
#   Never written (vendor-managed, regenerated on install):
#     ~/AppData/Roaming/npm/node_modules/rea-agents/...
#     ~/AppData/Local/hermes/skills/...                (hermes marketplace copy)

set -uo pipefail

ACTION="${1:---list}"
SKILL_NAME="reverse-engineer-anything"

have() { command -v "$1" >/dev/null 2>&1; }

# canonical source: prefer an explicit override, then the git checkout
if [ -n "${REA_SKILL_SOURCE:-}" ]; then
  CANONICAL="$REA_SKILL_SOURCE"
else
  CANONICAL=""
  for cand in "$HOME/Pi-GitHub-Stack/rea/.agents/skills/$SKILL_NAME" \
               "$HOME/projects/rea/.agents/skills/$SKILL_NAME" \
               "$HOME/.agents/skills/$SKILL_NAME"; do
    if [ -d "$cand" ]; then CANONICAL="$cand"; break; fi
  done
fi

# install copies we may write to
INSTALL_TARGETS=(
  "$HOME/.agents/skills/$SKILL_NAME"
  "$HOME/.claude/skills/$SKILL_NAME"
)

# copies we report but never modify
VENDOR_TARGETS=(
  "$HOME/AppData/Roaming/npm/node_modules/rea-agents/skills/$SKILL_NAME"
  "$HOME/AppData/Local/hermes/skills/$SKILL_NAME"
  "$HOME/AppData/Local/hermes/skills/claude-code-imports/$SKILL_NAME"
  "$HOME/.agents/skills.disabled-dsh-test/$SKILL_NAME"
)

# ---------------------------------------------------------------- helpers
skill_meta() {
  # skill_meta <SKILL.md> <key>   -> value of a metadata key
  sed -n "s/^  $2: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$1" 2>/dev/null | head -n1
}

checksum() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# Body checksum: the file minus its YAML frontmatter, with the REA package
# version pin normalised. Two copies can differ in generated metadata
# (tool_count) or in a pinned package tag (`rea-agents@6.9.0` vs `@latest`)
# while carrying identical instructions. Normalising the pin separates
# "cosmetic drift" from real instruction drift.
body_checksum() {
  awk 'BEGIN{infm=0;seen=0} /^---[[:space:]]*$/{ if(seen==0){infm=1;seen=1;next} else {infm=0;next} } infm==0{print}' "$1" \
    | sed -E 's/rea-agents@[0-9][^ )`"]*/rea-agents@VER/g' \
    | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null) | awk '{print $1}'
}

strip_fm() {
  awk 'BEGIN{infm=0;seen=0} /^---[[:space:]]*$/{ if(seen==0){infm=1;seen=1;next} else {infm=0;next} } infm==0{print}' "$1"
}

report() {
  local dir="$1" role="$2"
  local skill_md="$dir/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    printf '| %-70s | %-9s | %-5s | %-5s | %-14s |\n' "$dir" "$role" "-" "-" "absent"
    return
  fi
  local ver tools state canon_body
  ver="$(skill_meta "$skill_md" version)"
  tools="$(skill_meta "$skill_md" tool_count)"
  canon_body=""
  if [ -n "$CANONICAL" ] && [ -f "$CANONICAL/SKILL.md" ]; then canon_body="$(body_checksum "$CANONICAL/SKILL.md")"; fi
  if [ -z "$canon_body" ]; then
    state="no-canonical"
  elif [ "$(body_checksum "$skill_md")" = "$canon_body" ]; then
    state="match"
  elif [ "$ver" = "$(skill_meta "$CANONICAL/SKILL.md" version)" ]; then
    state="meta-only"
  else
    state="DRIFT"
  fi
  printf '| %-70s | %-9s | %-5s | %-5s | %-14s |\n' "$dir" "$role" "${ver:-?}" "${tools:-?}" "$state"
}

list_all() {
  printf '| %-70s | %-9s | %-5s | %-5s | %-14s |\n' "PATH" "ROLE" "VER" "TOOLS" "STATE"
  printf '%s\n' "------------------------------------------------------------------------------------------------------------------------------------"
  [ -n "$CANONICAL" ] && report "$CANONICAL" "canonical"
  for t in "${INSTALL_TARGETS[@]}"; do report "$t" "install"; done
  for t in "${VENDOR_TARGETS[@]}"; do report "$t" "vendor"; done
  echo
  echo "States: match = same instructions; meta-only = same version, generated metadata differs;"
  echo "        DRIFT = different instruction body; absent = not installed."
}

# ---------------------------------------------------------------- actions
case "$ACTION" in
  --list|-l)
    echo "Canonical source: ${CANONICAL:-<not found>}"
    echo
    list_all
    ;;

  --verify|-v)
    echo "Canonical source: ${CANONICAL:-<not found>}"
    if [ -z "$CANONICAL" ] || [ ! -f "$CANONICAL/SKILL.md" ]; then
      echo "FAIL: no canonical copy found. Set REA_SKILL_SOURCE." >&2
      exit 1
    fi
    rc=0
    canon_body="$(body_checksum "$CANONICAL/SKILL.md")"
    canon_ver="$(skill_meta "$CANONICAL/SKILL.md" version)"
    for t in "${INSTALL_TARGETS[@]}"; do
      if [ ! -f "$t/SKILL.md" ]; then
        printf 'MISSING  %s\n' "$t"
        rc=1
        continue
      fi
      if [ "$(body_checksum "$t/SKILL.md")" = "$canon_body" ]; then
        printf 'MATCH    %s (v%s)\n' "$t" "$canon_ver"
        continue
      fi
      inst_ver="$(skill_meta "$t/SKILL.md" version)"
      diff_lines="$(diff <(strip_fm "$CANONICAL/SKILL.md") <(strip_fm "$t/SKILL.md") 2>/dev/null | grep -c '^[<>]')"
      printf 'SOURCE-AHEAD  %s\n' "$t"
      printf '              installed v%s vs git source v%s, %s differing lines\n' "${inst_ver:-?}" "$canon_ver" "$diff_lines"
      printf '              the installed copy is the published release; repair with:\n'
      printf '                rea setup --skill-client <client> --skill --yes\n'
      rc=1
    done
    if have rea; then
      echo
      rea doctor --json 2>/dev/null | node -e '
        let s = "";
        process.stdin.on("data", (d) => (s += d)).on("end", () => {
          try {
            const j = JSON.parse(s);
            const sk = j.identity?.skill ?? {};
            console.log(`REA doctor: skill=${sk.state} version=${sk.installed_version} tools=${sk.installed_tool_count}`);
            for (const issue of sk.issues ?? []) console.log(`  issue: ${issue.client} -> ${issue.detail}`);
          } catch (e) {
            console.log("doctor output unreadable");
          }
        });'
    fi
    exit $rc
    ;;

  --sync|-s)
    # The supported repair path is REA's own installer. It writes the bundled
    # skill AND the generated metadata (tool_count) that `rea doctor` validates.
    # Hand-copying the file works but leaves the copy marked "stale" by doctor.
    if have rea; then
      for client in shared claude_code; do
        printf 'repairing skill copy for client: %s\n' "$client"
        if rea setup --skill-client "$client" --skill --yes >/dev/null 2>&1; then
          echo "  OK: rea setup --skill-client $client --skill"
        else
          echo "  FAILED: rea setup --skill-client $client --skill (try running it interactively)"
        fi
      done
    else
      echo "REA not found on PATH; falling back to a plain file copy."
      echo "NOTE: a hand-copied skill is missing the generated tool_count metadata"
      echo "      and `rea doctor` will report it as stale."
      if [ -z "$CANONICAL" ] || [ ! -f "$CANONICAL/SKILL.md" ]; then
        echo "FAIL: no canonical copy found. Set REA_SKILL_SOURCE." >&2
        exit 1
      fi
      for t in "${INSTALL_TARGETS[@]}"; do
        [ -f "$t/SKILL.md" ] || { echo "SKIP (not installed): $t"; continue; }
        backup="$t/SKILL.md.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$t/SKILL.md" "$backup"
        cp "$CANONICAL/SKILL.md" "$t/SKILL.md"
        echo "SYNCED: $t (backup: $backup)"
      done
    fi
    echo
    echo "--- REA's own view ---"
    if have rea; then
      rea doctor --json 2>/dev/null | node -e '
        let s = "";
        process.stdin.on("data", (d) => (s += d)).on("end", () => {
          try {
            const j = JSON.parse(s);
            const sk = j.identity?.skill ?? {};
            console.log(`skill state : ${sk.state}`);
            console.log(`version     : ${sk.installed_version} (tools: ${sk.installed_tool_count})`);
            for (const issue of sk.issues ?? []) console.log(`issue       : ${issue.client} -> ${issue.detail}`);
          } catch (e) {
            console.log("doctor output unreadable");
          }
        });'
    fi
    ;;

  --prune)
    APPLY=0
    [ "${2:-}" = "--apply" ] && APPLY=1
    echo "=== stale backups inside install directories ==="
    find "$HOME/.agents/skills/$SKILL_NAME" "$HOME/.claude/skills/$SKILL_NAME" \
      -maxdepth 1 \( -name 'SKILL.md.*bak*' -o -name 'SKILL.md.rea.backup' \) 2>/dev/null | while read -r f; do
      if [ "$APPLY" = "1" ]; then
        rm -f "$f" && printf 'REMOVED  %s\n' "$f"
      else
        printf 'WOULD REMOVE  %s (%s bytes)\n' "$f" "$(wc -c < "$f" | tr -d ' ')"
      fi
    done
    echo
    echo "=== stale (pre-canonical) skill copies ==="
    for t in "${VENDOR_TARGETS[@]}"; do
      [ -d "$t" ] || continue
      v="$(skill_meta "$t/SKILL.md" version)"
      if [ -n "$CANONICAL" ] && [ -n "$v" ] && [ "$v" != "$(skill_meta "$CANONICAL/SKILL.md" version)" ]; then
        if [ "$APPLY" = "1" ] && [[ "$t" == *disabled* || "$t" == *claude-code-imports* ]]; then
          rm -rf "$t" && printf 'REMOVED  %s (v%s)\n' "$t" "$v"
        else
          printf 'WOULD REMOVE  %s (v%s, stale vs canonical v%s)\n' "$t" "$v" "$(skill_meta "$CANONICAL/SKILL.md" version)"
        fi
      fi
    done
    if [ "$APPLY" = "0" ]; then
      echo
      echo "Re-run with --apply to perform the removals."
    fi
    exit 0
    ;;

  *)
    echo "usage: skill-sync.sh [--list|--verify|--sync|--prune]" >&2
    exit 2
    ;;
esac
