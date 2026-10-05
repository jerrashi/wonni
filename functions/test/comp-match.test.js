/**
 * comp_match.js — what a listing's text says is included, and whether an eBay
 * comp is in the same state. Every string below is a real eBay title or
 * short description (searches run 2026-10-04) unless marked otherwise, so a
 * new phrase can be added by pasting the title that was misread.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const { classifyIncluded, normalizeIncluded, compIncluded, isDifferentItem, matchLevel, descriptionConfirms } = require("../comp_match");

test("classifyIncluded: real titles and descriptions", () => {
  const cases = {
    complete: [
      "Pokemon Blue Version Nintendo Game Boy First Print CIB Complete",
      "Original Pokemon Blue Version w/ Box, Trainer's Guide & Game Boy Manual, Tested",
      "Pokemon Blue Version Game Boy Game Cart, Box, Manual,  and Insert Tested/Saves",
      "Super Smash Bros. Brawl (Wii, 2008) Game/Case/Manual/Inserts (CIB) - Tested",
      "Nintendo Super Smash Bros. Brawl Nintendo Wii w/ Case & Manual",
      "Super Smash Bros Brawl Nintendo Wii Complete CIB Clean Disc w Manual",
      "It comes with the box, game, advertisements",
      "disc + manual + case", // the product owner's own wording
    ],
    partial: [
      "Super Smash Bros. Brawl (Nintendo Wii) No Manual - Tested - Free Shipping",
      "Super Smash Bros Brawl Nintendo Wii Case & Disc No Manual TESTED WORKS VGC",
      "Used. Missing manual.",
    ],
    loose: [
      "Pokemon Blue Version (Game Boy, 1998) Authentic Cartridge Only",
      "Pokemon Blue Version (Game Boy, 1998) Cart Only! Authentic - Fast Shipping!",
      "Pokemon Blue Version, Cartridge w/ Case, Tested & Saves Nintendo Game Boy, 1998",
      "Pokemon Blue Version Nintendo Game Boy Authentic Cart Save Battery Tested",
      "Super Smash Bros. Brawl - Nintendo  Wii Game Only",
      "Super Smash Bros. Brawl DISC ONLY",
      "No box, manual, or other accessories are included.",
      "disc with generic case", // the product owner's own wording
    ],
    sealed: [
      "Super Smash Bros. Brawl (Nintendo Wii, 2008) Factory Sealed",
      "new. factory sealed. nonsmoking home.",
      "LEGO Star Wars 75192 Millennium Falcon New In Box",
    ],
    packaging: [
      "Pokemon Blue Version Nintendo Game Boy 1998 *** BOX ONLY *** See photos",
      "Super Smash Bros Brawl Nintendo Wii -CASE ONLY-",
      "Original CASE & MANUAL ONLY.",
      "Empty box, no game",
    ],
    unknown: [
      "Super Smash Bros. Brawl (Nintendo Wii, 2008)",
      "Pokemon Blue Version (Nintendo Game Boy, 1998) *Pre-owned* FREE SHIPPING",
      "Resealed copy", // "resealed" is not "sealed"
      "",
    ],
  };
  for (const [want, texts] of Object.entries(cases)) {
    for (const text of texts) assert.equal(classifyIncluded(text), want, text);
  }
});

test("normalizeIncluded: anything that is not a known state is unknown", () => {
  assert.equal(normalizeIncluded("Loose"), "loose");
  assert.equal(normalizeIncluded("cartridge only"), "unknown");
  assert.equal(normalizeIncluded(undefined), "unknown");
});

test("compIncluded: the title wins; the short description fills in a silent title", () => {
  assert.equal(compIncluded({ title: "Pokemon Blue Version (Game Boy, 1998)", shortDescription: "Fully working, cartridge only." }), "loose");
  assert.equal(compIncluded({ title: "Pokemon Blue CIB", shortDescription: "cartridge only photos on request" }), "complete");
  assert.equal(compIncluded({ title: "Pokemon Blue Version" }), "unknown");
});

test("isDifferentItem: repros, graded copies and broken items — unless that is what we are selling", () => {
  assert.equal(isDifferentItem("NEW Pokemon Blue. These cartridges are newly made", "Pokemon Blue Game Boy"), true);
  assert.equal(isDifferentItem("Nintendo Wii Super Smash Bros Brawl 9.6 A+ WATA Graded", "Super Smash Bros Brawl Wii"), true);
  assert.equal(isDifferentItem("Game Boy Color for parts", "Game Boy Color"), true);
  assert.equal(isDifferentItem("Game Boy Color for parts", "Game Boy Color for parts"), false);
  assert.equal(isDifferentItem("Pokemon Blue Version Game Boy Authentic", "Pokemon Blue Game Boy"), false);
  // Whole words only: "Palace" is not "PAL".
  assert.equal(isDifferentItem("Luigi's Mansion Dark Palace", "Luigi's Mansion"), false);
});

test("matchLevel: the table from comp_match.js", () => {
  const loose = { title: "Pokemon Blue Authentic Cartridge Only" };
  const boxed = { title: "Pokemon Blue CIB" };
  const silent = { title: "Pokemon Blue Version (Game Boy, 1998)" };
  const box = { title: "Pokemon Blue BOX ONLY" };
  assert.equal(matchLevel("loose", loose), 2);
  assert.equal(matchLevel("loose", silent), 1);
  assert.equal(matchLevel("loose", boxed), 0);
  assert.equal(matchLevel("complete", boxed), 2);
  assert.equal(matchLevel("complete", loose), 0);
  assert.equal(matchLevel("unknown", boxed), 1);
  assert.equal(matchLevel("unknown", loose), 1);
  assert.equal(matchLevel("unknown", box), 0);
  assert.equal(matchLevel("packaging", box), 2);
  assert.equal(matchLevel("loose", { title: "Pokemon Blue Cartridge Only reproduction" }, "Pokemon Blue"), 0);
});

test("descriptionConfirms: true / false / null (still silent)", () => {
  assert.equal(descriptionConfirms("loose", "You get the cartridge only."), true);
  assert.equal(descriptionConfirms("loose", "Complete in box with manual."), false);
  assert.equal(descriptionConfirms("loose", "Tested and working."), null);
});
