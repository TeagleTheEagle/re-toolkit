#!/usr/bin/env node
/**
 * detect.mjs — classify a target artifact and pick the REA inspection commands
 * that apply to it.
 *
 * Usage:
 *   node detect.mjs <target> [--json]
 *
 * Prints JSON:
 *   {
 *     "path": "...",
 *     "size": 12345,
 *     "sha256": "...",
 *     "kind": "pe",              // coarse family
 *     "format": "pe",            // precise container format
 *     "architecture": "x86_64",
 *     "commands": [ ... ],       // REA inspect-* commands valid for this kind
 *     "reason": "MZ header + PE signature"
 *   }
 *
 * Design notes:
 * - Magic-byte detection only; no execution of the target.
 * - The command table is intentionally data-driven so new REA operations can be
 *   added without touching the orchestrator.
 * - `commands` never includes operations that would launch the target.
 */

import { readFileSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { basename, extname } from "node:path";

/* ------------------------------------------------------------------ *
 * Command dispatch table.
 * Each entry: kind -> REA inspect-* / analysis commands valid for it.
 * ------------------------------------------------------------------ */
const KIND_COMMANDS = {
  pe: [
    "inspect-binary-layout",
    "inspect-binary-hardening",
    "inspect-pe-imports",
    "inspect-pe-resources",
    "inspect-pe-certificates",
    "inspect-pe-load-config",
    "inspect-native-exports",
    "inspect-native-load-image",
    "inspect-native-api",
    "inspect-byte-entropy",
    "inspect-with-objdump",
  ],
  elf: [
    "inspect-binary-layout",
    "inspect-binary-hardening",
    "inspect-elf-notes",
    "inspect-elf-unwind-ranges",
    "inspect-native-exports",
    "inspect-native-load-image",
    "inspect-native-api",
    "inspect-byte-entropy",
    "inspect-with-objdump",
  ],
  macho: [
    "inspect-binary-layout",
    "inspect-binary-hardening",
    "inspect-macho",
    "inspect-native-exports",
    "inspect-native-load-image",
    "inspect-native-api",
    "inspect-byte-entropy",
  ],
  go: ["inspect-go-binary", "inspect-native-exports", "inspect-byte-entropy"],
  rust: ["inspect-rust-binary", "inspect-native-exports", "inspect-byte-entropy"],
  managed: [
    "inspect-managed-artifact",
    "inspect-managed-members",
    "inspect-managed-native-boundaries",
    "inspect-byte-entropy",
  ],
  dotnet: ["inspect-managed-artifact", "inspect-managed-members", "inspect-byte-entropy"],
  wasm: ["inspect-wasm-artifact", "inspect-artifact", "inspect-byte-entropy"],
  python_pyc: ["inspect-python-pyc", "inspect-artifact", "inspect-byte-entropy"],
  apk: ["inspect-android-package", "inspect-apk-signature", "inspect-android-jni-bindings"],
  android_dex: ["inspect-android-class", "inspect-android-method"],
  // Not an executable: only generic, always-valid inspections apply.
  image: ["inspect-artifact", "inspect-byte-entropy"],
  firmware: ["inspect-firmware-regions", "inspect-kernel-build-config", "inspect-artifact", "inspect-byte-entropy"],
  archive: ["inspect-artifact", "inspect-byte-entropy"],
  jsbundle: ["inspect-artifact", "inspect-byte-entropy"],
  sqlite: ["inspect-sqlite-database", "inspect-artifact", "inspect-byte-entropy"],
  generic: ["inspect-artifact", "inspect-byte-entropy"],
};

/* Extension-driven hints for container formats without a leading magic. */
const EXT_HINTS = {
  ".apk": "apk",
  ".aab": "apk",
  ".jar": "managed",
  ".war": "managed",
  ".ear": "managed",
  ".dll": "managed",
  ".wasm": "wasm",
  ".pyc": "python_pyc",
  ".dex": "android_dex",
  ".o": "elf",
  ".so": "elf",
  ".elf": "elf",
  ".exe": "pe",
  ".dylib": "macho",
  ".a": "archive",
  ".zip": "archive",
  ".tar": "archive",
  ".gz": "archive",
  ".img": "firmware",
  ".bin": "firmware",
  ".db": "sqlite",
  ".sqlite": "sqlite",
  ".sqlite3": "sqlite",
  ".js": "jsbundle",
  ".mjs": "jsbundle",
  ".cjs": "jsbundle",
};

/** Read the first bytes of a file as a Buffer. */
function head(file, n = 512) {
  const fd = readFileSync(file);
  return fd.subarray(0, n);
}

/**
 * Classify by magic bytes.
 * @returns {{kind: string, format: string, architecture: string, reason: string}}
 */
function classify(buf, path) {
  const ext = extname(path).toLowerCase();

  // --- Java class / Mach-O / ELF / PE -------------------------------
  if (buf.length >= 4 && buf.readUInt32BE(0) === 0xcafebabe) {
    // 0xCAFEBABE is shared by Java class files and Mach-O fat binaries.
    if (buf.length >= 8 && buf.readUInt32BE(4) === 0x00000002) {
      return { kind: "macho", format: "macho-fat", architecture: "universal", reason: "FAT_MAGIC" };
    }
    return { kind: "managed", format: "java-class", architecture: "jvm", reason: "0xCAFEBABE class magic" };
  }

  if (buf.length >= 4 && buf.readUInt32BE(0) === 0xcffaedfe) {
    return { kind: "macho", format: "macho", architecture: "x86_64", reason: "MH_MAGIC_64" };
  }

  if (buf.length >= 4 && buf.readUInt32BE(0) === 0xfeedface) {
    return { kind: "macho", format: "macho", architecture: "x86", reason: "MH_MAGIC" };
  }

  if (buf.length >= 4 && buf.readUInt32BE(0) === 0x7f454c46) {
    // e_ident[EI_CLASS] byte 4: 1 = 32-bit, 2 = 64-bit
    const is64 = buf[4] === 2;
    return {
      kind: "elf",
      format: "elf",
      architecture: is64 ? "x86_64" : "x86",
      reason: `\\x7fELF magic (${is64 ? "64" : "32"}-bit)`,
    };
  }

  if (buf.length >= 2 && buf[0] === 0x4d && buf[1] === 0x5a) {
    // "MZ" — DOS header. The PE header offset lives at 0x3c.
    let arch = "unknown";
    let reason = 'MZ header ("MZ")';
    if (buf.length >= 0x40) {
      const peOffset = buf.readUInt32LE(0x3c);
      if (peOffset + 6 <= buf.length && buf.readUInt32LE(peOffset) === 0x00004550) {
        const machine = buf.readUInt16LE(peOffset + 4);
        arch =
          { 0x014c: "x86", 0x8664: "x86_64", 0xaa64: "arm64", 0x01c0: "arm" }[machine] ??
          `machine:0x${machine.toString(16)}`;
        reason = `MZ header + PE signature at 0x${peOffset.toString(16)}`;
      }
    }
    return { kind: "pe", format: "pe", architecture: arch, reason };
  }

  if (buf.length >= 4 && buf.readUInt32BE(0) === 0x89504e47) {
    return { kind: "image", format: "png", architecture: "n/a", reason: "PNG signature" };
  }

  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xd8) {
    return { kind: "image", format: "jpeg", architecture: "n/a", reason: "JPEG SOI" };
  }

  if (buf.length >= 12 && buf.subarray(0, 4).toString("latin1") === "RIFF") {
    return { kind: "image", format: "riff", architecture: "n/a", reason: "RIFF container" };
  }

  if (buf.length >= 3 && buf.subarray(0, 3).toString("latin1") === "GIF") {
    return { kind: "image", format: "gif", architecture: "n/a", reason: "GIF signature" };
  }

  if (buf.length >= 4 && buf.readUInt32BE(0) === 0x04034b50) {
    return { kind: "archive", format: "zip", architecture: "n/a", reason: "PK\\x03\\x04 local header" };
  }

  if (buf.length >= 3 && buf.subarray(0, 3).toString("latin1") === "BZh") {
    return { kind: "archive", format: "bzip2", architecture: "n/a", reason: "BZh magic" };
  }

  if (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b) {
    return { kind: "archive", format: "gzip", architecture: "n/a", reason: "gzip magic" };
  }

  if (buf.length >= 6 && buf.subarray(0, 6).toString("latin1") === "ustar") {
    return { kind: "archive", format: "tar", architecture: "n/a", reason: "ustar magic" };
  }

  if (buf.length >= 16 && buf.subarray(0, 4).toString("latin1") === "SQLi") {
    return { kind: "sqlite", format: "sqlite", architecture: "n/a", reason: "SQLite header" };
  }

  if (buf.length >= 4 && buf.readUInt32BE(0) === 0x00a72123) {
    return { kind: "firmware", format: "uimage", architecture: "arm", reason: "uImage magic" };
  }

  if (buf.length >= 4 && buf.readUInt32LE(0) === 0x194c456c) {
    // \x7fELF is checked above; this is "elf\0" reversed check for safety.
    return { kind: "elf", format: "elf", architecture: "unknown", reason: "ELF-ish magic" };
  }

  // --- Language / runtime specific --------------------------------
  if (buf.length >= 2 && buf[0] === 0xca && buf[1] === 0xfe) {
    return { kind: "managed", format: "java-class", architecture: "jvm", reason: "Java class magic" };
  }
  if (buf.length >= 4 && buf.readUInt32BE(0) === 0x0061736d) {
    return { kind: "wasm", format: "wasm", architecture: "wasm", reason: "\\0asm magic" };
  }

  // --- Fall back to extension --------------------------------------
  const hint = EXT_HINTS[ext];
  if (hint) {
    return { kind: hint, format: ext.slice(1), architecture: "unknown", reason: `extension ${ext}` };
  }

  // --- Executable script / text -----------------------------------
  const headText = buf.subarray(0, 256).toString("utf8");
  if (/^#!/.test(headText)) {
    const interp = headText.split("\n", 1)[0].slice(2).trim();
    return { kind: "script", format: "script", architecture: "n/a", reason: `shebang: ${interp}` };
  }

  return { kind: "generic", format: "unknown", architecture: "unknown", reason: "no known magic matched" };
}

/** Detect a Go or Rust build from observable section/linker markers. */
function refineLanguage(kind, buf) {
  const text = buf.subarray(0, 4096).toString("latin1");
  if (kind === "pe" || kind === "elf" || kind === "macho") {
    if (text.includes("Go build ID:") || text.includes("runtime.goexit")) {
      return { kind: "go", reason: "Go runtime markers" };
    }
    if (text.includes("rustc") || text.includes(".rustc")) {
      return { kind: "rust", reason: "rustc markers" };
    }
  }
  return null;
}

function main() {
  const args = process.argv.slice(2);
  const target = args.find((a) => !a.startsWith("--"));
  if (!target) {
    console.error("usage: detect.mjs <target> [--json]");
    process.exit(2);
  }

  const st = statSync(target);
  if (!st.isFile()) {
    console.error(`not a regular file: ${target}`);
    process.exit(2);
  }

  const bytes = readFileSync(target);
  const buf = bytes.subarray(0, 4096);
  let cls = classify(buf, target);
  const refined = refineLanguage(cls.kind, buf);
  if (refined) cls = { ...cls, ...refined };

  const commands = KIND_COMMANDS[cls.kind] ?? KIND_COMMANDS.generic;

  const result = {
    path: target,
    name: basename(target),
    size: st.size,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    kind: cls.kind,
    format: cls.format,
    architecture: cls.architecture,
    reason: cls.reason,
    commands,
  };

  console.log(JSON.stringify(result, null, 2));
}

main();
