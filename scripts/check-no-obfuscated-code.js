#!/usr/bin/env node
// Malware tripwire — added 2026-09-24 after an obfuscated infostealer was found
// appended to web/vite.config.js (it ran on every `vite dev` / `vite build`, and
// kept coming back through merges of stale branches).
//
// Pure Node, no dependencies, READ-ONLY: it never executes or imports the files
// it inspects, so it is safe to run BEFORE vite/npm loads any config.
//
//   node scripts/check-no-obfuscated-code.js [rootDir]
//
// Wired into: web `predev`/`prebuild`, githooks/pre-commit, githooks/post-merge
// (so a `git pull` that brings the payload back is flagged immediately), and CI.
// Exit 1 = suspicious content found.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.resolve(process.argv[2] || path.join(__dirname, ".."));

const CODE_EXT = /\.(js|mjs|cjs|jsx|ts|tsx|html|sh)$/i;
// Legitimately huge single-line / generated files.
const SKIP = [
  /(^|\/)package-lock\.json$/,
  /(^|\/)node_modules\//,
  /(^|\/)generated\//,
  /(^|\/)public\/assets\//,
  /(^|\/)dist\//,
  /\.min\.js$/i,
];
const MAX_LINE = 3000;

// Signatures of the payload family seen here (javascript-obfuscator output that
// stages data then phones home). Kept deliberately specific to avoid noise.
const SIGNATURES = [
  [/global\[\s*['"](r|m|_V|_H|_H2|_t_s|_t_u)['"]\s*\]\s*=/, "global[...] payload bootstrap"],
  [/\['push'\]\(\s*\w+\['shift'\]\(\)\s*\)/, "obfuscator array-rotation idiom"],
  [/\b_0x[0-9a-f]{5,}\s*\(/, "obfuscator _0x… call pattern"],
  [/166\.88\.134\.75/, "known C2 address"],
];
// Config files execute on dev/build, so hold them to a stricter standard.
const CONFIG_FILE = /(^|\/)(vite|postcss|tailwind|webpack|rollup|next|eslint|babel)\.config\.[cm]?[jt]s$/i;
const CONFIG_BANNED = /\b(child_process|spawn|execSync|exec\s*\(|eval\s*\(|new Function)\b/;

function listFiles() {
  try {
    const out = execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    return out.split("\0").filter(Boolean);
  } catch {
    const acc = [];
    (function walk(dir) {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.name === ".git" || e.name === "node_modules") continue;
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p);
        else acc.push(path.relative(root, p));
      }
    })(root);
    return acc;
  }
}

const problems = [];
for (const rel of listFiles()) {
  const norm = rel.split(path.sep).join("/");
  if (!CODE_EXT.test(norm) || SKIP.some((re) => re.test(norm))) continue;
  let text;
  try { text = fs.readFileSync(path.join(root, rel), "utf8"); } catch { continue; }
  const lines = text.split("\n");
  const longest = lines.reduce((m, l) => Math.max(m, l.length), 0);
  if (longest > MAX_LINE) problems.push(`${norm}: line of ${longest} chars (limit ${MAX_LINE})`);
  for (const [re, label] of SIGNATURES) if (re.test(text)) problems.push(`${norm}: ${label}`);
  if (CONFIG_FILE.test(norm) && CONFIG_BANNED.test(text)) problems.push(`${norm}: config file uses process-spawning/eval APIs`);
}

if (problems.length) {
  console.error("\n✗ SUSPICIOUS CODE DETECTED — do NOT run npm dev/build/install until this is resolved:\n");
  for (const p of [...new Set(problems)]) console.error("  • " + p);
  console.error(
    "\nThis matches the 2026-09-24 vite.config.js infostealer. Restore the file from a known-good commit\n" +
    "(git checkout origin/main -- <file>), then rotate credentials if it already ran. See memory: session-todo-2026-09-24.\n"
  );
  process.exit(1);
}
console.log("✓ no obfuscated/suspicious code found");
