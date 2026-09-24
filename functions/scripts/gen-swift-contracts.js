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

const {
  ALL,
  SaleDocSchema,
  MercariScrapeItemSchema,
  MercariRowLooseSchema,
  MercariBatchResultSchema,
  ListingFieldsSchema,
  OptionSchema,
  VariantSchema,
  ProductDocSchema,
  WeverseOrderTaskWithIdSchema,
  CarrierSchema,
} = require("../contracts");

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
// `refs` names recurring nested schemas so quicktype emits a $ref'd type with
// that name, instead of inferring one from the enclosing property (e.g. an
// `items` array field would otherwise synthesize a class literally named
// "Item", colliding with the app's own SwiftData `Item` model).
function add(name, schema, refs) {
  const js = zodToJsonSchema(schema, {
    name,
    target: "jsonSchema7",
    // "none" never emits $refs (even for pre-named `definitions`), so a
    // schema passed via `refs` needs "root" to actually get referenced by
    // name instead of inlined-and-renamed at each occurrence.
    $refStrategy: refs ? "root" : "none",
    ...(refs ? { definitions: refs } : {}),
  });
  // zodToJsonSchema nests the named schema under definitions[name]; hoist it.
  const body = js.definitions?.[name] ?? js;
  definitions[name] = body;
  for (const refName of Object.keys(refs ?? {})) {
    if (js.definitions?.[refName]) definitions[refName] = js.definitions[refName];
  }
}

// Per-contract nested schemas that need an explicit name (see `add` above).
// Keyed by contract name; each entry names the request/response's recurring
// nested schema(s) so quicktype doesn't synthesize a type name from the
// enclosing property that happens to collide with a Swift/Foundation type
// (`Result`, `Task`) or an app type (`Carrier` in CrossPostWebView.swift).
const REQUEST_REFS = {
  recordSale: { SaleCarrier: CarrierSchema },
  recordMercariSalesBatch: { MercariBatchRow: MercariRowLooseSchema },
};
const RESPONSE_REFS = {
  recordMercariSalesBatch: { MercariBatchResult: MercariBatchResultSchema },
  listWeverseOrderTasks: { WeverseOrderTaskWithId: WeverseOrderTaskWithIdSchema },
};

for (const c of ALL) {
  add(`${titleCase(c.name)}Request`, c.request, REQUEST_REFS[c.name]);
  add(`${titleCase(c.name)}Response`, c.response, RESPONSE_REFS[c.name]);
}
add("SaleDoc", SaleDocSchema, { SaleCarrier: CarrierSchema });
add("MercariScrapeItem", MercariScrapeItemSchema);
add("ListingFields", ListingFieldsSchema);
add("Option", OptionSchema);
add("Variant", VariantSchema);
add("ProductDoc", ProductDocSchema);

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
