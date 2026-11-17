#!/usr/bin/env bash
#
# build-docs.sh — render the toolkit docs to PDF using whatever this machine has.
#
#   ./build-docs.sh            build every document
#   ./build-docs.sh --list     show which engine would be used
#
# Engines, in order of preference:
#   1. pandoc + a LaTeX engine   best typography, needs texlive
#   2. pandoc + wkhtmltopdf
#   3. headless Chrome/Edge      needs only a browser; always available on Windows
#
# Every document is built independently; one failure does not abort the rest.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS="$ROOT/docs"
DIST="$DOCS/dist"

have() { command -v "$1" >/dev/null 2>&1; }

find_browser() {
  for b in \
    "/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
    "/c/Program Files/Microsoft/Edge/Application/msedge.exe" \
    "$(command -v google-chrome 2>/dev/null)" \
    "$(command -v chromium 2>/dev/null)" \
    "$(command -v chromium-browser 2>/dev/null)" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- engine choice
detect_engine() {
  if have pandoc; then
    for tex in xelatex pdflatex lualatex tectonic; do
      have "$tex" && { echo "pandoc+$tex"; return; }
    done
    have wkhtmltopdf && { echo "pandoc+wkhtmltopdf"; return; }
    echo "pandoc-html"    # pandoc to HTML, then browser to PDF
    return
  fi
  B="$(find_browser)" && { echo "browser:$B"; return; }
  echo "none"
}

ENGINE="$(detect_engine)"

if [ "${1:-}" = "--list" ]; then
  echo "documents:"
  for f in "$DOCS"/*.md; do [ -f "$f" ] && echo "  $(basename "$f")"; done
  echo "engine: $ENGINE"
  if [ "$ENGINE" = "none" ]; then
    echo "no PDF engine available; install pandoc or a Chromium-based browser" >&2
    exit 4
  fi
  exit 0
fi

if [ "$ENGINE" = "none" ]; then
  echo "no PDF engine available." >&2
  echo "  install pandoc + texlive, or a Chromium-based browser for the HTML fallback" >&2
  exit 4
fi

mkdir -p "$DIST"
echo "engine: $ENGINE"
echo

# ---------------------------------------------------------------- html template
# Used by every non-LaTeX path so the output looks the same regardless of engine.
write_html_wrapper() {
  local md="$1" html="$2" title="$3"
  {
    cat <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>${title}</title>
<style>
  :root { --ink:#1a1a1a; --muted:#5b6470; --rule:#d8dde4; --code-bg:#f5f7fa; --accent:#0b5fff; }
  * { box-sizing: border-box; }
  body { font: 15px/1.62 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         color: var(--ink); max-width: 46rem; margin: 0 auto; padding: 2.5rem 1.5rem 4rem; }
  h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 .6rem; letter-spacing: -.02em; }
  h2 { font-size: 1.35rem; margin: 2.4rem 0 .7rem; padding-top: .9rem; border-top: 1px solid var(--rule); }
  h3 { font-size: 1.08rem; margin: 1.7rem 0 .5rem; }
  h4 { font-size: .98rem; margin: 1.3rem 0 .4rem; color: var(--muted); }
  p, ul, ol, blockquote { margin: .7rem 0; }
  a { color: var(--accent); text-decoration: none; }
  code { font: .88em/1.5 "Cascadia Code", "SF Mono", Consolas, monospace;
         background: var(--code-bg); padding: .12em .38em; border-radius: 4px;
         border: 1px solid #e3e8ef; }
  pre { background: var(--code-bg); border: 1px solid var(--rule); border-radius: 8px;
        padding: .85rem 1rem; overflow-x: auto; page-break-inside: avoid; }
  pre code { background: none; border: 0; padding: 0; font-size: .86em; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: .92em;
          page-break-inside: avoid; }
  th, td { border: 1px solid var(--rule); padding: .45rem .6rem; text-align: left;
           vertical-align: top; }
  th { background: #eef2f7; font-weight: 600; }
  blockquote { border-left: 3px solid var(--accent); margin-left: 0; padding: .2rem 0 .2rem 1rem;
               color: var(--muted); background: #fafbfd; }
  hr { border: 0; border-top: 1px solid var(--rule); margin: 2rem 0; }
  @page { margin: 16mm 14mm; }
  @media print { body { padding: 0; max-width: none; font-size: 11pt; }
                 h2 { page-break-after: avoid; } pre, table { page-break-inside: avoid; } }
</style></head><body>
HTML
    cat "$html"
    printf '</body></html>\n'
  } > "$html.wrapped"
}

# Markdown -> HTML. Uses pandoc when present, else a small self-contained
# renderer that covers the constructs these documents actually use.
md_to_html() {
  local md="$1" out="$2"
  if have pandoc; then
    pandoc "$md" -f gfm -t html5 --standalone --metadata title="$(basename "$md" .md)" -o "$out" 2>/dev/null && return 0
  fi
  node "$SCRIPT_DIR/lib/md2html.mjs" "$md" "$out"
}

build_with_browser() {
  local browser="$1" md="$2" pdf="$3"
  local workdir html_file
  workdir="$(mktemp -d)" || { echo "cannot create temp dir"; return 1; }
  html_file="$workdir/page.html"

  # 1. markdown -> html body
  if ! md_to_html "$md" "$html_file.body"; then
    echo "markdown render failed"
    rm -rf "$workdir"
    return 1
  fi
  # 2. wrap the body in the print stylesheet
  write_html_wrapper "$md" "$html_file.body" "$(basename "$md" .md)"
  mv "$html_file.body.wrapped" "$html_file" || { rm -rf "$workdir"; return 1; }

  # 3. absolute file:// URL.
  #    cygpath is authoritative; a naive /c/ -> c:/ guess is wrong for paths
  #    under a bash mount such as /tmp, which maps to the Windows Temp dir.
  local win_url pdf_arg
  if command -v cygpath >/dev/null 2>&1; then
    win_url="file:///$(cygpath -m "$html_file")"
    pdf_arg="$(cygpath -m "$pdf")"
  else
    case "$html_file" in
      /[a-zA-Z]/*) win_url="file:///$(printf '%s' "$html_file" | sed 's|^/\([a-zA-Z]\)/|\1:/|')" ;;
      *)           win_url="file://$html_file" ;;
    esac
    case "$pdf" in
      /[a-zA-Z]/*) pdf_arg="$(printf '%s' "$pdf" | sed 's|^/\([a-zA-Z]\)/|\1:/|')" ;;
      *)           pdf_arg="$pdf" ;;
    esac
  fi

  # 4. print; try the modern headless flag first, then the legacy one.
  local ok=1 flag
  for flag in --headless=new --headless; do
    rm -f "$pdf"
    "$browser" "$flag" --disable-gpu --no-pdf-header-footer        --run-all-compositor-stages-before-draw --virtual-time-budget=10000        --print-to-pdf="$pdf_arg" "$win_url" >"$workdir/chrome.log" 2>&1
    if [ -s "$pdf" ]; then ok=0; break; fi
  done

  if [ "$ok" -ne 0 ]; then
    echo "chrome print failed:"
    sed -n '1,4p' "$workdir/chrome.log" | sed 's/^/      /'
    rm -rf "$workdir"
    return 1
  fi

  rm -rf "$workdir"
  return 0
}

build_one() {
  local md="$1"
  local name
  name="$(basename "$md" .md)"
  local pdf="$DIST/$name.pdf"
  printf '  %-28s ' "$name"

  case "$ENGINE" in
    pandoc+xelatex|pandoc+pdflatex|pandoc+lualatex|pandoc+tectonic)
      local tex="${ENGINE#pandoc+}"
      if pandoc "$md" -o "$pdf" --pdf-engine="$tex" \
           -V geometry:margin=1in -V fontsize=11pt -V colorlinks=true \
           --toc --toc-depth=2 -N 2>"$DIST/$name.log"; then
        echo "ok ($(wc -c < "$pdf" | tr -d ' ') bytes)"
        return 0
      fi
      echo "FAILED (see $name.log)"
      return 1
      ;;
    pandoc+wkhtmltopdf)
      if pandoc "$md" -o "$pdf" --pdf-engine=wkhtmltopdf 2>"$DIST/$name.log"; then
        echo "ok ($(wc -c < "$pdf" | tr -d ' ') bytes)"
        return 0
      fi
      echo "FAILED (see $name.log)"
      return 1
      ;;
    pandoc-html|browser:*)
      local browser
      if [ "$ENGINE" = "pandoc-html" ]; then browser="$(find_browser)" || browser=""; else browser="${ENGINE#browser:}"; fi
      if [ -z "$browser" ]; then echo "FAILED (no browser)"; return 1; fi
      if build_with_browser "$browser" "$md" "$pdf"; then
        echo "ok ($(wc -c < "$pdf" | tr -d ' ') bytes)"
        return 0
      fi
      echo "FAILED"
      return 1
      ;;
    *)
      echo "FAILED (no engine)"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------- build
echo "documents:"
ok=0; fail=0
for md in "$DOCS"/*.md; do
  [ -f "$md" ] || continue
  case "$(basename "$md")" in README.md) continue ;; esac
  if build_one "$md"; then ok=$((ok+1)); else fail=$((fail+1)); fi
done

echo
echo "built $ok, failed $fail -> $DIST"
[ "$fail" -eq 0 ]
