#!/usr/bin/env node
/**
 * report.mjs — turn a directory of REA step artifacts into summary.json and
 * report.md.
 *
 * Usage:
 *   node report.mjs <artifacts-dir> [--out <dir>]
 *
 * Expected layout inside <artifacts-dir>:
 *   detect.json          output of detect.mjs
 *   steps/<name>.json    raw REA JSON envelope per step
 *   steps/<name>.log     stderr / diagnostics per step
 *   steps/<name>.status  "ok" | "skipped" | "error"
 *
 * The report is deliberately evidence-first: every line in report.md is derived
 * from a REA envelope or from a local tool, never from model speculation.
 */

import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

/** Read a JSON file, returning null on any parse failure. */
function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/**
 * Flatten one level of a REA normalized_result into printable facts.
 * Scalars are kept verbatim; arrays/objects are summarised by size so the
 * report stays readable without hiding that data existed.
 */
function flattenFacts(value, depth = 0, prefix = "") {
  const facts = [];
  if (value === null || value === undefined) return facts;
  if (typeof value !== "object") {
    facts.push({ key: prefix || "value", value: String(value) });
    return facts;
  }
  for (const [key, val] of Object.entries(value)) {
    const name = prefix ? `${prefix}.${key}` : key;
    if (val === null || val === undefined) continue;
    if (typeof val === "object" && !Array.isArray(val)) {
      if (depth >= 1) {
        facts.push({ key: name, value: `{${Object.keys(val).length} keys}` });
      } else {
        facts.push(...flattenFacts(val, depth + 1, name));
      }
    } else if (Array.isArray(val)) {
      const preview =
        val.length && typeof val[0] === "object"
          ? `${val.length} entries`
          : `${val.length} items`;
      facts.push({ key: name, value: `[${preview}]` });
    } else {
      facts.push({ key: name, value: String(val) });
    }
  }
  return facts;
}

function esc(text) {
  return String(text).replace(/\|/g, "\\|");
}

function main() {
  const args = process.argv.slice(2);
  const dir = args[0];
  if (!dir) {
    console.error("usage: report.mjs <artifacts-dir> [--out <dir>]");
    process.exit(2);
  }
  const outIdx = args.indexOf("--out");
  const outDir = outIdx !== -1 ? args[outIdx + 1] : dir;

  const detect = readJson(join(dir, "detect.json")) ?? {};
  const stepsDir = join(dir, "steps");
  const stepFiles = existsSync(stepsDir)
    ? readdirSync(stepsDir).filter((f) => f.endsWith(".json")).sort()
    : [];

  const steps = [];
  for (const file of stepFiles) {
    const name = file.replace(/\.json$/, "");
    const envelope = readJson(join(stepsDir, file));
    const statusFile = join(stepsDir, `${name}.status`);
    const status = existsSync(statusFile) ? readFileSync(statusFile, "utf8").trim() : "unknown";

    // Local tools (file, strings, objdump) emit plain text, not JSON. Treat a
    // successful non-JSON step as ok with a raw preview instead of an error.
    if (!envelope && status === "ok") {
      const jsonPath = join(stepsDir, file);
      const raw = existsSync(jsonPath) ? readFileSync(jsonPath, "utf8") : "";
      const logPath = join(stepsDir, `${name}.log`);
      const errText = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
      steps.push({
        step: name,
        status: "ok",
        operation: "local-tool",
        predicate_type: null,
        confidence: null,
        authority: "local-tool",
        evidence_id: null,
        digest: null,
        facts: raw
          .split("\n")
          .filter((l) => l.trim())
          .slice(0, 40)
          .map((l, i) => ({ key: `line ${i + 1}`, value: l.slice(0, 160) })),
        limitations: ["Raw output of a local tool; not REA Evidence."],
        error: errText.trim() ? errText.trim().split("\n").slice(0, 6).join("\n") : null,
        rawPreview: raw.split("\n").slice(0, 40).join("\n"),
      });
      continue;
    }

    const step = {
      step: name,
      status,
      operation: envelope?.operation ?? null,
      predicate_type: envelope?.predicate_type ?? null,
      confidence: envelope?.confidence ?? null,
      authority: envelope?.authority ?? null,
      evidence_id: envelope?.evidence_id ?? null,
      digest: envelope?.digest ?? envelope?.analysis_profile?.digest ?? null,
      facts: envelope ? flattenFacts(envelope.normalized_result ?? envelope.raw_result ?? {}) : [],
      limitations: Array.isArray(envelope?.limitations)
        ? envelope.limitations.map((l) => String(l).split(":")[0])
        : [],
      error: null,
    };
    if (!envelope) {
      const logPath = join(stepsDir, `${name}.log`);
      const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
      step.error = log.trim().split("\n").slice(0, 6).join("\n") || "no JSON output produced";
    }
    steps.push(step);
  }

  const summary = {
    generated_by: "re-toolkit re-analyze.sh",
    target: {
      name: detect.name ?? null,
      path: detect.path ?? null,
      size: detect.size ?? null,
      sha256: detect.sha256 ?? null,
      kind: detect.kind ?? null,
      format: detect.format ?? null,
      architecture: detect.architecture ?? null,
      detection_reason: detect.reason ?? null,
    },
    counts: {
      steps_total: steps.length,
      steps_ok: steps.filter((s) => s.status === "ok").length,
      steps_error: steps.filter((s) => s.status === "error").length,
      steps_skipped: steps.filter((s) => s.status === "skipped").length,
    },
    steps,
  };

  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, "summary.json"), JSON.stringify(summary, null, 2));

  /* ---------------- markdown ---------------- */
  const t = summary.target;
  const lines = [];
  lines.push(`# Reverse-Engineering Report — ${t.name ?? "unknown target"}`);
  lines.push("");
  lines.push("## Target");
  lines.push("");
  lines.push("| Field | Value |");
  lines.push("| --- | --- |");
  lines.push(`| Path | \`${esc(t.path ?? "n/a")}\` |`);
  lines.push(`| Size | ${t.size ?? "n/a"} bytes |`);
  lines.push(`| SHA-256 | \`${t.sha256 ?? "n/a"}\` |`);
  lines.push(`| Detected kind | ${esc(t.kind ?? "n/a")} |`);
  lines.push(`| Format | ${esc(t.format ?? "n/a")} |`);
  lines.push(`| Architecture | ${esc(t.architecture ?? "n/a")} |`);
  lines.push(`| Detection reason | ${esc(t.detection_reason ?? "n/a")} |`);
  lines.push("");
  lines.push(
    `**Steps:** ${summary.counts.steps_total} run · ${summary.counts.steps_ok} ok · ` +
      `${summary.counts.steps_error} error · ${summary.counts.steps_skipped} skipped`,
  );
  lines.push("");

  lines.push("## Step Index");
  lines.push("");
  lines.push("| # | Step | Status | Operation | Confidence |");
  lines.push("| --- | --- | --- | --- | --- |");
  steps.forEach((s, i) => {
    lines.push(
      `| ${i + 1} | \`${esc(s.step)}\` | ${s.status} | ${esc(s.operation ?? "—")} | ${esc(s.confidence ?? "—")} |`,
    );
  });
  lines.push("");

  lines.push("## Details");
  lines.push("");
  for (const s of steps) {
    lines.push(`### \`${s.step}\``);
    lines.push("");
    if (s.status !== "ok" || s.facts.length === 0) {
      lines.push(`Status: **${s.status}**`);
      if (s.error) {
        lines.push("");
        lines.push("```");
        lines.push(s.error);
        lines.push("```");
      }
      lines.push("");
      continue;
    }
    lines.push(`- Evidence id: \`${s.evidence_id ?? "n/a"}\``);
    lines.push(`- Digest: \`${s.digest ?? "n/a"}\``);
    lines.push(`- Authority: ${s.authority ?? "n/a"}`);
    lines.push("");
    if (s.rawPreview) {
      lines.push("```");
      lines.push(s.rawPreview);
      lines.push("```");
      lines.push("");
    }
    lines.push("| Field | Observed value |");
    lines.push("| --- | --- |");
    for (const f of s.facts.slice(0, 60)) {
      lines.push(`| ${esc(f.key)} | ${esc(f.value)} |`);
    }
    if (s.facts.length > 60) {
      lines.push(`| … | ${s.facts.length - 60} more fields |`);
    }
    lines.push("");
  }

  const md = lines.join("\n");
  writeFileSync(join(outDir, "report.md"), md);
  console.log(`report: ${join(outDir, "report.md")}`);
  console.log(`summary: ${join(outDir, "summary.json")}`);
}

main();
