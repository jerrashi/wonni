#!/usr/bin/env node
/**
 * gen-swift-contracts.js
 *
 * Turns the zod contract registry (functions/contracts/) into:
 *   1. contracts/generated/backend-contracts.schema.json  — JSON Schema, always
 *   2. <ios>/Generated/BackendContracts.swift              — if quicktype is available
 *
 * Run from functions/:  node scripts/gen-swift-contracts.js
 * CI should run this and fail if the generated files are out of date.
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { zodToJsonSchema } = require("zod-to-json-schema");

const { ALL, SaleDocSchema, MercariScrapeItemSchema, ListingFieldsSchema } = require("../contracts");

const OUT_DIR = path.join(__dirname, "..", "contracts", "generated");
const SCHEMA_PATH = path.join(OUT_DIR, "backend-contracts.schema.json");
// Adjust once the repos are merged; for now the iOS tree lives here:
const SWIFT_OUT = path.join(
  __dirname, "..", "..", "wonni", "wonni", "Generated", "BackendContracts.swift"
);

function titleCase(s) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

const definitions = {};
function add(name, schema) {
  const js = zodToJsonSchema(schema, { name, target: "jsonSchema7", $refStrategy: "none" });
  // zodToJsonSchema nests the named schema under definitions[name]; hoist it.
  const body = js.definitions?.[name] ?? js;
  definitions[name] = body;
}

for (const c of ALL) {
  add(`${titleCase(c.name)}Request`, c.request);
  add(`${titleCase(c.name)}Response`, c.response);
}
add("SaleDoc", SaleDocSchema);
add("MercariScrapeItem", MercariScrapeItemSchema);
add("ListingFields", ListingFieldsSchema);

const bundle = {
  $schema: "http://json-schema.org/draft-07/schema#",
  title: "WonniBackendContracts",
  description: "Generated from functions/contracts/. Do not edit by hand.",
  type: "object",
  properties: Object.fromEntries(
    Object.keys(definitions).map((k) => [k, { $ref: `#/definitions/${k}` }])
  ),
  definitions,
};

fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(SCHEMA_PATH, JSON.stringify(bundle, null, 2) + "\n");
console.log(`✓ wrote ${path.relative(process.cwd(), SCHEMA_PATH)} (${ALL.length} functions, ${Object.keys(definitions).length} types)`);

// ── Swift, best-effort ─────────────────────────────────────────────────────
try {
  fs.mkdirSync(path.dirname(SWIFT_OUT), { recursive: true });
  execFileSync(
    "npx",
    [
      "--yes", "quicktype",
      "--src-lang", "schema",
      "--lang", "swift",
      "--acronym-style", "camel",
      "--sendable",
      "-o", SWIFT_OUT,
      SCHEMA_PATH,
    ],
    { stdio: "inherit" }
  );
  console.log(`✓ wrote ${path.relative(process.cwd(), SWIFT_OUT)}`);
} catch (err) {
  console.warn(
    `\n⚠ Swift not generated (${err.message}).\n` +
    `  Install quicktype and re-run, or generate manually:\n` +
    `  npx quicktype --src-lang schema --lang swift -o BackendContracts.swift ${path.relative(process.cwd(), SCHEMA_PATH)}\n`
  );
}
