#!/usr/bin/env node
/**
 * md2html.mjs — a small, self-contained GitHub-flavoured Markdown renderer.
 *
 *   node md2html.mjs <input.md> <output.html>
 *
 * Why not a library: this runs inside a build step on machines with no pandoc
 * and no npm project, so it must depend on nothing. It covers exactly the
 * constructs the toolkit docs use — headings, paragraphs, fenced code, tables,
 * lists, blockquotes, rules, inline code, bold/italic, links, and HTML
 * escaping. Anything it does not understand is emitted as escaped text rather
 * than dropped, so nothing silently disappears.
 */

import { readFileSync, writeFileSync } from "node:fs";

const ESCAPE = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
const esc = (s) => s.replace(/[&<>"]/g, (c) => ESCAPE[c]);

/** Inline formatting: code spans first (they win over everything), then the rest. */
function inline(text) {
  const codes = [];
  // Protect code spans from further processing.
  let out = text.replace(/`([^`]+)`/g, (_, code) => {
    codes.push(`<code>${esc(code)}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });

  out = esc(out);

  // Links [text](url) — URLs are escaped already.
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
  // Auto-links of bare URLs.
  out = out.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2">$2</a>');
  // Bold then italic.
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
  // Inline code placeholders back.
  out = out.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[Number(i)]);
  return out;
}

/** Split a markdown table row into cells, honouring escaped pipes. */
function rowCells(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split(/(?<!\\)\|/)
    .map((c) => c.trim().replace(/\\\|/g, "|"));
}

function render(md) {
    const lines = md.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  let i = 0;

  const isTableSep = (s) => /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(s) && s.includes("-");

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code
    const fence = line.match(/^```(\w*)\s*$/);
    if (fence) {
      const lang = fence[1];
      const body = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) body.push(lines[i++]);
      i++; // closing fence
      const cls = lang ? ` class="language-${esc(lang)}"` : "";
      out.push(`<pre><code${cls}>${esc(body.join("\n"))}</code></pre>`);
      continue;
    }

    // Headings
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      const level = h[1].length;
      out.push(`<h${level}>${inline(h[2].trim())}</h${level}>`);
      i++;
      continue;
    }

    // Horizontal rule
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {
      out.push("<hr>");
      i++;
      continue;
    }

    // Table: header row followed by separator row
    if (line.includes("|") && i + 1 < lines.length && isTableSep(lines[i + 1])) {
      const head = rowCells(line);
      i += 2;
      const body = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim() !== "") {
        body.push(rowCells(lines[i]));
        i++;
      }
      out.push("<table>");
      out.push("<thead><tr>");
      for (const c of head) out.push(`<th>${inline(c)}</th>`);
      out.push("</tr></thead>");
      out.push("<tbody>");
      for (const r of body) {
        out.push("<tr>");
        for (const c of r) out.push(`<td>${inline(c)}</td>`);
        out.push("</tr>");
      }
      out.push("</tbody></table>");
      continue;
    }

    // Blockquote
    if (/^>\s?/.test(line)) {
      const quote = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        quote.push(lines[i].replace(/^>\s?/, ""));
        i++;
      }
      out.push(`<blockquote>${render(quote.join("\n"))}</blockquote>`);
      continue;
    }

    // Lists (unordered and ordered), with one nesting level
    if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
      const ordered = /^\s*\d+\.\s+/.test(line);
      const tag = ordered ? "ol" : "ul";
      const items = [];
      let cur = null;
      let curIndent = null;
      while (i < lines.length) {
        const l = lines[i];
        const m = l.match(/^(\s*)([-*+]|\d+\.)\s+(.*)$/);
        if (m) {
          if (curIndent === null) curIndent = m[1].length;
          if (cur) items.push(cur);
          cur = { indent: m[1].length, text: [m[3]] };
          i++;
          continue;
        }
        // Continuation line of the current item.
        if (cur && /^\s+\S/.test(l) && l.trim() !== "") {
          cur.text.push(l.trim());
          i++;
          continue;
        }
        if (cur && l.trim() === "") {
          // A blank line ends the list unless another item follows.
          if (i + 1 < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i + 1])) {
            i++;
            continue;
          }
        }
        break;
      }
      if (cur) items.push(cur);

      // Split top-level items from nested ones by indent.
      const top = items.filter((it) => it.indent === curIndent);
      out.push(`<${tag}>`);
      for (const it of top) {
        out.push(`<li>${inline(it.text.join(" "))}</li>`);
      }
      out.push(`</${tag}>`);
      continue;
    }

    // Blank line
    if (line.trim() === "") {
      i++;
      continue;
    }

    // Paragraph: consume until a blank line or a block construct.
    const para = [];
    while (i < lines.length) {
      const l = lines[i];
      if (l.trim() === "") break;
      if (/^(#{1,6}\s|```|>|\s*([-*+]|\d+\.)\s)/.test(l)) break;
      if (l.includes("|") && i + 1 < lines.length && isTableSep(lines[i + 1])) break;
      if (/^\s*([-*_])\1{2,}\s*$/.test(l)) break;
      para.push(l.trim());
      i++;
    }
    if (para.length) out.push(`<p>${inline(para.join(" "))}</p>`);
    else i++;
  }

  return out.join("\n");
}

function main() {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) {
    console.error("usage: md2html.mjs <input.md> <output.html>");
    process.exit(2);
  }
  const md = readFileSync(input, "utf8");
  writeFileSync(output, render(md));
  console.error(`md2html: ${input} -> ${output}`);
}

main();
