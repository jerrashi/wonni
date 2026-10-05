/**
 * ebay_condition.js — graded / ungraded conditions for eBay's card categories.
 * POLICY is the live `get_item_condition_policies` answer for category 183454
 * (CCG Individual Cards) fetched 2026-10-04, trimmed to a few values.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const { parseConditionPolicy, gradingOf, toGrading, cardCondition } = require("../ebay_condition");
const { resolveItemCondition, conditionFields } = require("../ebay_listing")._internal;
const { toListingFields } = require("../enrichment")._internal;

const value = (id, name, onlyWith) => ({
  conditionDescriptorValueId: id, conditionDescriptorValueName: name,
  ...(onlyWith ? { conditionDescriptorValueConstraints: [{ applicableToConditionDescriptorId: "27501", applicableToConditionDescriptorValueIds: onlyWith }] } : {}),
});
const POLICY = parseConditionPolicy({
  categoryId: "183454",
  itemConditions: [
    {
      conditionId: "2750", conditionDescription: "Graded",
      conditionDescriptors: [
        { conditionDescriptorId: "27501", conditionDescriptorName: "Professional Grader", conditionDescriptorConstraint: { mode: "SELECTION_ONLY", usage: "REQUIRED" },
          conditionDescriptorValues: [value("275010", "Professional Sports Authenticator (PSA)"), value("275013", "Beckett Grading Services (BGS)"), value("2750123", "Other")] },
        { conditionDescriptorId: "27502", conditionDescriptorName: "Grade", conditionDescriptorConstraint: { mode: "SELECTION_ONLY", usage: "REQUIRED" },
          conditionDescriptorValues: [value("275020", "10", ["275010", "275013", "2750123"]), value("275021", "9.5", ["275013", "2750123"]), value("275022", "9", ["275010", "275013", "2750123"])] },
        { conditionDescriptorId: "27503", conditionDescriptorName: "Certification Number", conditionDescriptorConstraint: { mode: "FREE_TEXT", maxLength: 20 } },
      ],
    },
    { conditionId: "3000", conditionDescription: "Used" },
    {
      conditionId: "4000", conditionDescription: "Ungraded",
      conditionDescriptors: [
        { conditionDescriptorId: "40001", conditionDescriptorName: "Card Condition", conditionDescriptorConstraint: { mode: "SELECTION_ONLY", usage: "REQUIRED" },
          conditionDescriptorValues: [value("400010", "Near mint or better"), value("400015", "Lightly played (Excellent)"), value("400016", "Moderately played (Very good)"), value("400017", "Heavily played (Poor)")] },
      ],
    },
  ],
});
const GAMES_POLICY = parseConditionPolicy({ itemConditions: [{ conditionId: "1000" }, { conditionId: "2750" }, { conditionId: "4000" }, { conditionId: "5000" }] });

test("regression: a raw 'like new' card is Ungraded + Near mint, not Graded with no grade", () => {
  // The live failure 2026-10-04: "Grade (27502) is a required field."
  const product = { title: "The Soul Stone - MTG Marvel Universes Beyond - Non-Foil Near Mint", condition: "likenew" };
  assert.deepEqual(resolveItemCondition(product, POLICY), {
    conditionEnum: "USED_VERY_GOOD", // eBay id 4000, which this category calls "Ungraded"
    conditionDescriptors: [{ name: "40001", values: ["400010"] }],
  });
});

test("cardCondition: ungraded card condition follows the app condition and title words", () => {
  const pick = (product) => cardCondition(product, POLICY).conditionDescriptors[0].values[0];
  assert.equal(pick({ title: "Black Lotus", condition: "new" }), "400010");
  assert.equal(pick({ title: "Black Lotus", condition: "good" }), "400015");
  assert.equal(pick({ title: "Black Lotus", condition: "fair" }), "400016");
  assert.equal(pick({ title: "Black Lotus", condition: "poor" }), "400017");
  assert.equal(pick({ title: "Black Lotus Lightly Played", condition: "new" }), "400015", "the title is more specific");
  assert.equal(pick({ title: "Charizard potential PSA 10", condition: "likenew" }), "400010", "'potential PSA 10' is a raw card");
});

test("cardCondition: a graded card gets grader + grade (+ cert) descriptors", () => {
  assert.deepEqual(cardCondition({ title: "PSA 10 Charizard Base Set 2 Holo", condition: "likenew" }, POLICY), {
    conditionId: "2750",
    conditionDescriptors: [{ name: "27501", values: ["275010"] }, { name: "27502", values: ["275020"] }],
  });
  assert.deepEqual(cardCondition({ title: "Charizard", grader: "BGS", grade: "9.5", gradeCertNumber: "0012345678" }, POLICY).conditionDescriptors, [
    { name: "27501", values: ["275013"] }, { name: "27502", values: ["275021"] }, { name: "27503", additionalInfo: "0012345678" },
  ]);
  // From item specifics, the way enrichListing hands a grade to the app.
  assert.equal(cardCondition({ title: "Charizard", geminiItemSpecifics: { "Professional Grader": "PSA", Grade: "9" } }, POLICY).conditionDescriptors[1].values[0], "275022");
  // A grader eBay does not list by name → "Other".
  assert.equal(cardCondition({ title: "Charizard", grader: "XYZ Grading", grade: "10" }, POLICY).conditionDescriptors[0].values[0], "2750123");
  // PSA has no 9.5: not listable as graded → falls back to ungraded.
  assert.equal(cardCondition({ title: "Charizard", grader: "PSA", grade: "9.5" }, POLICY).conditionId, "4000");
});

test("cardCondition: a category without grading descriptors is left to the ordinary mapping", () => {
  assert.equal(cardCondition({ title: "PSA 10 Charizard" }, GAMES_POLICY), null);
  assert.equal(cardCondition({ title: "x" }, null), null);
  assert.deepEqual(resolveItemCondition({ title: "Mario Kart Wii", condition: "likenew" }, GAMES_POLICY), { conditionEnum: "LIKE_NEW", conditionDescriptors: undefined });
  assert.deepEqual(resolveItemCondition({ title: "Mario Kart Wii", condition: "good" }, null), { conditionEnum: "USED_GOOD", conditionDescriptors: undefined });
});

test("gradingOf: fields, specifics, then text; never from 'ungraded' wording", () => {
  assert.deepEqual(gradingOf({ title: "2020 Topps Chrome BGS Gem Mint 9.5 Rookie" }), { grader: "BGS", grade: "9.5" });
  assert.deepEqual(gradingOf({ title: "Pikachu", description: "Graded CGC 10." }), { grader: "CGC", grade: "10" });
  assert.equal(gradingOf({ title: "Pikachu Illustrator ungraded, PSA 10 candidate" }), null);
  assert.equal(gradingOf({ title: "Pikachu 25/102 base set" }), null);
  assert.equal(gradingOf({ title: "PSA 100 card lot" }), null, "100 is not a grade");
});

test("conditionFields: descriptors ride with their condition and are dropped with a recovery override", () => {
  const descriptors = [{ name: "40001", values: ["400010"] }];
  assert.deepEqual(conditionFields("USED_VERY_GOOD", descriptors), { condition: "USED_VERY_GOOD", conditionDescriptors: descriptors });
  assert.deepEqual(conditionFields("USED_VERY_GOOD", descriptors, "USED_EXCELLENT"), { condition: "USED_EXCELLENT" });
  assert.deepEqual(conditionFields("NEW", undefined), { condition: "NEW" });
});

test("toGrading / toListingFields: the AI's optional grade is validated and mirrored into item specifics", () => {
  assert.deepEqual(toGrading({ grader: "PSA", grade: "Gem Mint 10", gradeCertNumber: "#1234 5678" }), { grader: "PSA", grade: "10", gradeCertNumber: "12345678" });
  assert.equal(toGrading({ grader: "none", grade: "" }), null);
  assert.equal(toGrading({ grader: "PSA", grade: "near mint" }), null, "a condition word is not a grade");
  const fields = toListingFields({ name: "Charizard", grader: "PSA", grade: "9", itemSpecifics: { Game: "Pokemon TCG" } });
  assert.equal(fields.grader, "PSA");
  assert.deepEqual(fields.itemSpecifics, { Game: "Pokemon TCG", "Professional Grader": "PSA", Grade: "9" });
  assert.equal("grade" in toListingFields({ name: "Raw card", grade: "ungraded", grader: "" }), false);
});
