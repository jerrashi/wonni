#!/usr/bin/env node
/**
 * check-contracts.js — CI / pre-commit guard.
 *
 * Regenerates every derived artifact from functions/contracts/ and fails if
 * anything is out of date (i.e. a schema changed but the generated files were
 * not regenerated + committed).
 *
 *   HARD FAIL : contracts/ doesn't load  ·  the JSON Schema bundle is stale
 *   WARN ONLY : BACKEND.md AUTOGEN block stale  ·  Swift file stale/ungenerated
 *               (quicktype needs network for `npx --yes`; not always available)
 *
 * Run from functions/:  npm run contracts:check
 */

"use strict";

const { execFileSync } = require("child_process");
const path = require("path");

const FUNCTIONS_DIR = path.join(__dirname, "..");
const SCHEMA_REL = "functions/contracts/generated/backend-contracts.schema.json";
const BACKEND_MD_REL = "BACKEND.md";
const SWIFT_REL = "wonni/wonni/Generated/BackendContracts.swift";

function sh(cmd, args, opts = {}) {
  return execFileSync(cmd, args, { encoding: "utf8", ...opts }).trim();
}

function gitClean(pathspec) {
  try {
    sh("git", ["diff", "--quiet", "--", pathspec], { cwd: repoRoot });
    return true;
  } catch {
    return false;
  }
}

// 1. contracts/ must load at all.
try {
  require("../contracts");
} catch (err) {
  console.error("✗ functions/contracts/ failed to load:\n  " + err.message);
  process.exit(1);
}

const repoRoot = sh("git", ["rev-parse", "--show-toplevel"], { cwd: FUNCTIONS_DIR });

// 2. Regenerate everything.
console.log("· regenerating derived contract artifacts…");
execFileSync("node", ["scripts/gen-swift-contracts.js"], { cwd: FUNCTIONS_DIR, stdio: "inherit" });
execFileSync("node", ["scripts/gen-backend-md.js"], { cwd: FUNCTIONS_DIR, stdio: "inherit" });

// 3. The JSON Schema bundle is fully deterministic — stale = hard fail.
if (!gitClean(SCHEMA_REL)) {
  console.error(
    `\n✗ ${SCHEMA_REL} is out of date.\n` +
    `  A contract schema changed without regenerating. Run:\n` +
    `      cd functions && npm run contracts:gen\n` +
    `  then commit the generated files.\n`
  );
  process.exit(1);
}

// 4. Soft checks.
let warned = false;
if (!gitClean(BACKEND_MD_REL)) {
  console.warn(`⚠ ${BACKEND_MD_REL} changed after regen — commit the refreshed AUTOGEN block.`);
  warned = true;
}
if (!gitClean(SWIFT_REL)) {
  console.warn(`⚠ ${SWIFT_REL} changed / not regenerated (quicktype unavailable offline is OK in CI).`);
  warned = true;
}

console.log(warned ? "\n✓ contracts OK (with warnings above)" : "\n✓ contracts OK — all derived artifacts up to date");
