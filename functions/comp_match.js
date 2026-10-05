/**
 * comp_match.js — is this eBay listing the same item, IN THE SAME STATE, as ours?
 *
 * WHY THIS EXISTS
 * "Drafts from a List" (bulk_text_drafts.js) borrows two things from live eBay
 * listings ("comps"): a price and a photo. A search for "Pokemon Blue Game Boy"
 * returns loose cartridges ($55), complete-in-box copies ($350), sealed copies
 * ($1,900), empty boxes, graded slabs and reproductions — all the same game.
 * Picking by title similarity alone put a boxed copy's photo on a
 * "cartridge only" draft, and can price a boxed copy like a loose one.
 *
 * THE IDEA
 * Every listing has an `included` state — what physically comes with it:
 *
 *   complete   every original part: "CIB", "complete in box", disc + case + manual
 *   partial    original case/box but something missing: "no manual"
 *   loose      the item alone: "cartridge only", "disc only", "generic case", "no box"
 *   sealed     factory sealed / unopened
 *   packaging  NOT the item: "box only", "case only", "manual only", "no game"
 *   unknown    the text does not say
 *
 * Our listing's state comes from the list parser (the model reads "CIB" or
 * "cart only" from the seller's text). A comp's state is read from its title
 * and, when the title is silent, from the short description eBay returns with
 * search results. Both use `classifyIncluded` below — plain phrase matching,
 * no AI call, so it is free, instant and unit-tested.
 *
 * HOW A COMP IS JUDGED — `matchLevel(listingIncluded, comp)`:
 *
 *   our listing says   comp says        level
 *   ----------------   --------------   -----------------------------------
 *   (anything)         a DIFFERENT_ITEM marker (repro, graded, for parts…)  0
 *   unknown            packaging        0   never show an empty box
 *   unknown            anything else    1   best match, as before
 *   loose              loose            2   explicit match
 *   loose              unknown          1   unverified — see below
 *   loose              complete/sealed… 0   contradiction
 *
 * WHAT USES IT
 *   photos  `rankPhotoComps` orders candidates level 2 first. When our listing
 *           states what is included, a level-1 comp is only used if its FULL
 *           description (fetched for that one comp) says the same state;
 *           otherwise the draft gets a placeholder card. Rule agreed with the
 *           product owner 2026-10-04: no photo beats a wrong photo.
 *   price   `comparableComps` in bulk_text_drafts.js drops level-0 comps and,
 *           when enough level-2 comps exist, prices from those alone.
 *
 * EXTENDING IT
 * To teach it a new phrase, add it to the matching list below and add a line
 * to test/comp-match.test.js. Order matters in `classifyIncluded`: the first
 * state whose pattern matches wins (packaging → sealed → loose → partial →
 * complete), because "cartridge only, no box" must not read as "box".
 * The lists are written for media and electronics but nothing is game-specific:
 * "console only", "no charger" style phrases fit the same five states.
 */

const INCLUDED_STATES = ["complete", "partial", "loose", "sealed", "packaging", "unknown"];

/** Lowercase, punctuation → spaces, so "w/ Box", "Game/Case/Manual" and
 *  "*CIB*" all match word patterns. */
function normalize(text) {
  return ` ${String(text || "").toLowerCase().replace(/&/g, " and ").replace(/[^a-z0-9.]+/g, " ").replace(/\s+/g, " ").trim()} `;
}

// "no manual", "missing the original box", "without case", "does not include…"
const NEGATION = "(?:no|not|missing|without|w o|lacks?|lacking|minus|doesn t (?:come with|include|have)|does not (?:come with|include|have)|not includ(?:ed|ing))";
const FILLER = "(?:the |a |an |any |its |original |outer |game |instruction )*";
const negated = (thing) => new RegExp(`\\b${NEGATION} ${FILLER}(?:${thing})s?\\b`);
const present = (thing) => new RegExp(`\\b(?:${thing})s?\\b`);

const THE_ITEM = "game|disc|disk|cartridge|cart|console|system|unit|handheld|device|controller|figure";
const OUTER = "box|case";
const PAPERWORK = "manual|booklet|instructions|inserts?";

const PATTERNS = {
  // Not the item at all.
  packaging: [
    new RegExp(`\\b(?:${OUTER}|${PAPERWORK}|artwork|cover art|cover|sleeve)(?: and (?:${OUTER}|${PAPERWORK}|artwork))? only\\b`),
    negated(THE_ITEM),
    /\bempty (?:box|case)\b/,
    /\breplacement (?:box|case|cover|artwork)\b/,
  ],
  sealed: [
    /\b(?:factory |still |brand new )?sealed\b/,
    /\bunopened\b/,
    /\bnib\b/,
    /\bnew in (?:the )?box\b/,
    /\bshrink ?wrap(?:ped)?\b/,
  ],
  // The item alone.
  loose: [
    new RegExp(`\\b(?:${THE_ITEM}) only\\b`),
    /\bonly the (?:game|disc|cartridge|cart)\b/,
    /\bloose\b/,
    /\bgeneric (?:case|box)\b/,
    negated(OUTER),
  ],
  // Original case/box, something else missing.
  partial: [
    negated(PAPERWORK),
    negated("cover art|artwork"),
  ],
  complete: [
    /\bcib\b/,
    /\bcomplete in (?:the )?(?:box|case)\b/,
    /\bcomplete(?! your| the collection| set of)\b/,
    /\bboxed\b/,
    /\bin (?:the |its )?(?:original )?box\b/,
    new RegExp(`\\b(?:with|w|includes?|including|comes with|plus) ${FILLER}(?:box|${PAPERWORK})\\b`),
    new RegExp(`\\b(?:${PAPERWORK}) included\\b`),
  ],
};

/**
 * What a piece of listing text says is included. Returns one of
 * INCLUDED_STATES; "unknown" when the text is silent.
 */
function classifyIncluded(text) {
  const t = normalize(text);
  if (!t.trim()) return "unknown";
  for (const state of ["packaging", "sealed", "loose", "partial", "complete"]) {
    if (PATTERNS[state].some((re) => re.test(t))) return state;
  }
  // Names both the outer packaging and the paperwork ("Game/Case/Manual"):
  // complete, even with no "CIB".
  if (present(OUTER).test(t) && present(PAPERWORK).test(t)) return "complete";
  // Says "cartridge" and nothing about a box, case or manual: a bare cartridge.
  // (Boxed copies say so in the title — that is where their price comes from.)
  if (/\b(?:cartridge|cart)\b/.test(t)) return "loose";
  return "unknown";
}

/** Coerce a model- or client-supplied value to a valid state. */
function normalizeIncluded(value) {
  const v = String(value || "").toLowerCase().trim();
  return INCLUDED_STATES.includes(v) ? v : "unknown";
}

// A comp carrying one of these is a different thing to buy, whatever its
// title shares with ours — unless our own query says the same.
const DIFFERENT_ITEM = [
  "for parts", "parts only", "not working", "broken", "as is", "untested", "read description",
  "reproduction", "repro", "replica", "newly made", "not original", "not the original", "not authentic", "fake", "bootleg", "custom",
  "rom hack", "sd card", "region locked", "japanese", "jpn", "pal",
  "graded", "wata", "vga", "psa", "cgc",
];

function isDifferentItem(compText, query) {
  const text = normalize(compText);
  const ours = normalize(query);
  return DIFFERENT_ITEM.some((phrase) => text.includes(` ${phrase} `) && !ours.includes(` ${phrase} `));
}

/** A comp's state: the title wins; the short description fills in a silent title. */
function compIncluded(comp = {}) {
  const fromTitle = classifyIncluded(comp.title);
  return fromTitle !== "unknown" ? fromTitle : classifyIncluded(comp.shortDescription);
}

/**
 * 0 = do not use, 1 = usable but unverified, 2 = explicitly the same state.
 * See the table at the top of this file.
 */
function matchLevel(listingIncluded, comp, query = "") {
  if (isDifferentItem(`${comp.title || ""} ${comp.shortDescription || ""}`, query)) return 0;
  const ours = normalizeIncluded(listingIncluded);
  const theirs = compIncluded(comp);
  if (ours === "unknown") return theirs === "packaging" ? 0 : 1;
  if (theirs === ours) return 2;
  return theirs === "unknown" ? 1 : 0;
}

/**
 * After fetching ONE comp's full details: does its long description settle a
 * silent title? Returns true (same state), false (a different state) or null
 * (still silent).
 */
function descriptionConfirms(listingIncluded, detailText) {
  const theirs = classifyIncluded(detailText);
  if (theirs === "unknown") return null;
  return theirs === normalizeIncluded(listingIncluded);
}

module.exports = {
  INCLUDED_STATES,
  classifyIncluded,
  normalizeIncluded,
  compIncluded,
  isDifferentItem,
  matchLevel,
  descriptionConfirms,
};
