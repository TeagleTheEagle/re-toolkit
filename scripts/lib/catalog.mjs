#!/usr/bin/env node
/**
 * catalog.mjs — generate the REA command catalog from the installed engine.
 *
 *   node catalog.mjs > docs/rea-command-catalog.md
 *
 * The catalog is generated, never hand-maintained, so it cannot drift from
 * the engine that is actually installed.
 */

import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";

function run(args) {
  try {
    // shell: true is required on Windows, where `rea` is a .cmd shim.
    return execSync(`rea ${args.join(" ")}`, {
      encoding: "utf8",
      shell: true,
      maxBuffer: 8 * 1024 * 1024,
    });
  } catch {
    return "";
  }
}

const help = run(["--help"]);
const version = (run(["--version"]) || "unknown").trim().replace(/^rea@/, "");

const lines = [];
lines.push("# REA Command Catalog");
lines.push("");
lines.push(`_Generated from the installed engine: \`${version}\`, on ${new Date().toISOString().slice(0, 10)}._`);
lines.push("");
lines.push("This is the complete command surface the RE toolkit drives. It is generated, not");
lines.push("hand-written — regenerate it whenever the engine is upgraded:");
lines.push("");
lines.push("```bash");
lines.push("rea --help > docs/rea-command-catalog.md");
lines.push("```");
lines.push("");
lines.push("## Commands");
lines.push("");
lines.push("| Command | Purpose |");
lines.push("| --- | --- |");

const cmdRe = /^ {2}([a-z][a-z0-9-]+) {2,}(.*)$/;
let count = 0;
for (const raw of help.split("\n")) {
  const m = raw.match(cmdRe);
  if (!m) continue;
  const [, name, desc] = m;
  lines.push(`| \`${name}\` | ${desc.trim()} |`);
  count++;
}

lines.push("");
lines.push(`_${count} commands._`);
lines.push("");
lines.push("## Global options");
lines.push("");
lines.push("| Option | Effect |");
lines.push("| --- | --- |");
const optRe = /^ {2}(--[a-z-]+(?: <[^>]+>)?) {2,}(.*)$/;
for (const raw of help.split("\n")) {
  const m = raw.match(optRe);
  if (!m) continue;
  lines.push(`| \`${m[1].trim()}\` | ${m[2].trim()} |`);
}

lines.push("");
lines.push("## Output formats");
lines.push("");
lines.push("Every command accepts `--format <toon|json|yaml|md|jsonl>`. The toolkit uses");
lines.push("`--format json` so that every step produces machine-checkable evidence.");
lines.push("");
lines.push("## Filtering large output");
lines.push("");
lines.push("```bash");
lines.push("rea analyze ./app.exe --format json --filter-output normalized_result.segments");
lines.push("rea analyze ./app.exe --format json --token-limit 4000");
lines.push("rea analyze ./app.exe --format json --full-output");
lines.push("```");
lines.push("");

const out = lines.join("\n");
if (process.argv[2]) {
  writeFileSync(process.argv[2], out);
  console.error(`wrote ${process.argv[2]} (${count} commands)`);
} else {
  console.log(out);
}
