/**
 * ebay_condition.js — conditions for eBay categories that need more than one
 * word: trading cards (and anything else eBay gives "condition descriptors").
 *
 * WHY THIS EXISTS
 * In most categories a condition is one value ("Used"). In the trading-card
 * categories the SAME numeric ids mean something else and need extra fields:
 *
 *   2750  "Graded"    requires  Professional Grader (27501) + Grade (27502),
 *                     optional  Certification Number (27503)
 *   4000  "Ungraded"  requires  Card Condition (40001): Near mint or better /
 *                     Lightly played / Moderately played / Heavily played
 *
 * Our generic mapping turned the app's "like new" into 2750, so a raw
 * Near-Mint Magic card was sent as "Graded" with no grade and eBay answered
 * "Grade (27502) is a required field" (live failure 2026-10-04).
 *
 * WHAT IT DOES
 * `cardCondition(product, policy)` looks at the category's own condition
 * policy (Sell Metadata API `get_item_condition_policies`, fetched per
 * category at post time — ids and value lists are never hard-coded here):
 *   - the category has no "Grade" descriptor → returns null, caller keeps the
 *     ordinary one-word condition;
 *   - the product is professionally graded (see `gradingOf`) and eBay offers
 *     that grader + grade → the Graded condition with its descriptors;
 *   - otherwise → the Ungraded condition with a Card Condition picked from
 *     the app's condition and any "lightly played"-style words in the title.
 *
 * WHERE A GRADE COMES FROM — `gradingOf(product)`, first hit wins:
 *   1. `product.grader` / `.grade` / `.gradeCertNumber` — written by the AI
 *      field fill (listing_fields.js) or, later, a user-facing field;
 *   2. item specifics "Professional Grader" / "Grade" / "Certification Number"
 *      (enrichListing mirrors the AI's answer there, so the iOS draft flow
 *      carries a grade with no extra app fields);
 *   3. the title/description: "PSA 10", "BGS 9.5", "CGC Gem Mint 10".
 * A grade is only used when BOTH grader and grade are known. "Ungraded",
 * "raw" or "potential PSA 10" wording always means not graded.
 */

const GRADERS = ["PSA", "BGS", "BVG", "BCCG", "CGC", "SGC", "KSA", "GMA", "HGA", "ISA", "PCA", "GSG", "PGS", "MNT", "TAG", "RCG", "PCG", "ACE", "CGA", "TCG", "ARK", "AGS", "DSG"];
const NOT_GRADED = /\b(ungraded|un-graded|raw|potential|candidate|contender|worthy|not graded)\b/i;
const GRADE_IN_TEXT = new RegExp(`\\b(${GRADERS.join("|")})\\b[\\s:#-]*(?:gem[\\s-]*mint|gem[\\s-]*mt|pristine|black label|mint|nm[\\s-]*mt|nm)?[\\s:#-]*(10|[1-9](?:\\.5)?)(?!\\d|\\.\\d)`, "i");

/** eBay's raw policy → the parts we use. null when there is no policy. */
function parseConditionPolicy(policy) {
  if (!policy) return null;
  const conditions = (policy.itemConditions || []).map((c) => ({
    id: String(c.conditionId),
    name: c.conditionDescription || "",
    descriptors: (c.conditionDescriptors || []).map((d) => ({
      id: String(d.conditionDescriptorId),
      name: d.conditionDescriptorName || "",
      required: d.conditionDescriptorConstraint?.usage === "REQUIRED",
      freeText: d.conditionDescriptorConstraint?.mode === "FREE_TEXT",
      maxLength: d.conditionDescriptorConstraint?.maxLength || 20,
      values: (d.conditionDescriptorValues || []).map((v) => ({
        id: String(v.conditionDescriptorValueId),
        name: v.conditionDescriptorValueName || "",
        // Some grades exist only for some graders (PSA has no 9.5).
        onlyWith: (v.conditionDescriptorValueConstraints || []).flatMap((k) => (k.applicableToConditionDescriptorValueIds || []).map(String)),
      })),
    })),
  }));
  return { allowedIds: conditions.map((c) => c.id), conditions };
}

function specific(product, names) {
  const all = { ...(product.geminiItemSpecifics || {}), ...(product.ebayAspects || {}) };
  for (const [key, raw] of Object.entries(all)) {
    if (!names.includes(key.toLowerCase().trim())) continue;
    const value = Array.isArray(raw) ? raw[0] : raw;
    if (value != null && String(value).trim()) return String(value).trim();
  }
  return "";
}

/** `{ grader, grade, certNumber }` for a professionally graded item, else null. */
function gradingOf(product = {}) {
  const text = `${product.title || ""} ${product.description || ""}`;
  const clean = (v) => (v == null ? "" : String(v).trim());
  let grader = clean(product.grader) || specific(product, ["professional grader", "grader"]);
  let grade = clean(product.grade) || specific(product, ["grade"]);
  const certNumber = clean(product.gradeCertNumber) || specific(product, ["certification number", "cert number"]);
  if (!grader || !grade) {
    if (NOT_GRADED.test(text)) return null;
    const m = GRADE_IN_TEXT.exec(text);
    if (!m) return null;
    grader = grader || m[1].toUpperCase();
    grade = grade || m[2];
  }
  if (/^(ungraded|none|n\/a|no|raw)$/i.test(grader) || /^(ungraded|none|n\/a)$/i.test(grade)) return null;
  return { grader, grade, ...(certNumber ? { certNumber } : {}) };
}

/**
 * A model's grading answer → `{ grader, grade, gradeCertNumber? }`, or null.
 * Both grader and grade are needed; "none" / "ungraded" style answers and a
 * grade that is not a number or an "Authentic" label are dropped.
 */
function toGrading(g = {}) {
  const clean = (v, cap) => (v == null ? "" : String(v).trim().slice(0, cap));
  const grader = clean(g.grader, 40);
  const grade = clean(g.grade, 20).replace(/^(gem\s*)?(mint|mt)\s*/i, "");
  const none = /^(|none|n\/a|na|null|ungraded|raw|unknown|no)$/i;
  if (none.test(grader) || none.test(grade)) return null;
  if (!/^(10|[1-9](\.5)?|authentic.*)$/i.test(grade)) return null;
  const cert = clean(g.gradeCertNumber ?? g.certNumber, 20).replace(/[^a-z0-9-]/gi, "");
  return { grader, grade, ...(cert ? { gradeCertNumber: cert } : {}) };
}

const find = (condition, pattern) => condition?.descriptors.find((d) => pattern.test(d.name));

function graderValue(descriptor, grader) {
  const wanted = grader.toLowerCase();
  const abbreviation = wanted.match(/\(([a-z]+)\)\s*$/)?.[1] || wanted;
  return descriptor.values.find((v) => v.name.toLowerCase().includes(`(${abbreviation})`))
    || descriptor.values.find((v) => v.name.toLowerCase() === wanted)
    || descriptor.values.find((v) => /^other$/i.test(v.name))
    || null;
}

function gradeValue(descriptor, grade, graderId) {
  const number = Number(grade);
  const wanted = Number.isFinite(number) ? String(number) : String(grade).toLowerCase();
  const value = descriptor.values.find((v) => v.name.toLowerCase() === wanted);
  if (!value) return null;
  return value.onlyWith.length && !value.onlyWith.includes(graderId) ? null : value;
}

/** The app's five conditions (+ card-grading words in the title) → which
 *  Card Condition value to pick, matched against eBay's own value names. */
function cardConditionPattern(product) {
  const text = `${product.title || ""}`.toLowerCase();
  if (/\b(heavily played|hp|damaged|poor)\b/.test(text)) return /heavily|poor/i;
  if (/\b(moderately played|mp)\b/.test(text)) return /moderately|very good/i;
  if (/\b(lightly played|lp|excellent)\b/.test(text)) return /lightly|excellent/i;
  if (/\b(near mint|nm|mint)\b/.test(text)) return /near mint/i;
  const condition = String(product.condition ?? product.mercariCondition ?? "").toLowerCase().replace(/[^a-z]/g, "");
  if (condition === "poor") return /heavily|poor/i;
  if (condition === "fair") return /moderately|very good/i;
  if (condition === "good" || condition === "used") return /lightly|excellent/i;
  return /near mint/i;
}

/**
 * The condition for a category that grades its items, or null when this
 * category does not (the caller then uses its ordinary mapping).
 * Returns `{ conditionId, conditionDescriptors }` where conditionDescriptors
 * is the Inventory API shape: `[{ name: "<descriptor id>", values: ["<value
 * id>"] }]`, or `{ name, additionalInfo }` for free text.
 */
function cardCondition(product, policy) {
  const graded = policy?.conditions.find((c) => find(c, /^grade$/i));
  if (!graded) return null;

  const grading = gradingOf(product);
  if (grading) {
    const graderDescriptor = find(graded, /grader/i);
    const gradeDescriptor = find(graded, /^grade$/i);
    const certDescriptor = find(graded, /certification/i);
    const grader = graderDescriptor && graderValue(graderDescriptor, grading.grader);
    const grade = grader && gradeValue(gradeDescriptor, grading.grade, grader.id);
    if (grader && grade) {
      const conditionDescriptors = [
        { name: graderDescriptor.id, values: [grader.id] },
        { name: gradeDescriptor.id, values: [grade.id] },
      ];
      if (certDescriptor && grading.certNumber) {
        conditionDescriptors.push({ name: certDescriptor.id, additionalInfo: grading.certNumber.slice(0, certDescriptor.maxLength) });
      }
      return { conditionId: graded.id, conditionDescriptors };
    }
  }

  const ungraded = policy.conditions.find((c) => c !== graded && find(c, /card condition/i));
  if (!ungraded) return null;
  const descriptor = find(ungraded, /card condition/i);
  const value = descriptor.values.find((v) => cardConditionPattern(product).test(v.name)) || descriptor.values[0];
  if (!value) return null;
  return { conditionId: ungraded.id, conditionDescriptors: [{ name: descriptor.id, values: [value.id] }] };
}

module.exports = { parseConditionPolicy, gradingOf, toGrading, cardCondition };
