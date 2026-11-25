import test from "node:test";
import assert from "node:assert/strict";
import { madeOn, isPhoneDraft, isWaitingForAI, visibleProducts } from "./draftOrigin.js";

const U = (n) => `0089695A-AF02-4CAB-AD44-37${n}A7AE2365`;
const phoneDraft = { id: U("11"), source: "ios", isDraft: true, title: "Kuromi plush" };
const photoOnly = { id: U("22"), source: "ios", isDraft: true, title: null };
const phoneListed = { id: U("33"), source: "ios", isDraft: false, title: "Wii" };
const pcDraft = { id: "WphLZ61Q9IKvWwjTm06z", source: "weverse", isDraft: true, title: "Keyring" };
const downloaded = { id: "c2xxxxxxxxxxxxxxxxxx", source: "ios", isDraft: true, title: "Brawl" };
const all = [phoneDraft, photoOnly, phoneListed, pcDraft, downloaded];

test("madeOn: an iOS UUID id is phone, a Firestore auto-id is pc, madeOn wins", () => {
  assert.equal(madeOn(phoneDraft), "phone");
  assert.equal(madeOn(pcDraft), "pc");
  assert.equal(madeOn({ id: "abc", source: "text" }), "pc");
  assert.equal(madeOn(downloaded), "pc", "regression: a PC draft whose source the old iOS sync overwrote is still PC");
  assert.equal(madeOn({ ...phoneDraft, madeOn: "pc" }), "pc");
});

test("only unlisted phone drafts are phone drafts", () => {
  assert.equal(isPhoneDraft(phoneDraft), true);
  assert.equal(isPhoneDraft(phoneListed), false);
  assert.equal(isPhoneDraft(downloaded), false);
  assert.equal(isPhoneDraft({ id: U("44") }), true, "isDraft unset counts as a draft");
});

test("waiting for AI = phone draft with no title", () => {
  assert.equal(isWaitingForAI(photoOnly), true);
  assert.equal(isWaitingForAI({ ...photoOnly, title: "  " }), true);
  assert.equal(isWaitingForAI(phoneDraft), false);
  assert.equal(isWaitingForAI({ ...pcDraft, title: "" }), false);
});

test("visibleProducts: hidden by default, mixed with the setting, alone under Phone", () => {
  assert.deepEqual(visibleProducts(all).map((p) => p.id), [U("33"), pcDraft.id, downloaded.id]);
  assert.deepEqual(visibleProducts(all, { showPhoneDrafts: true }).map((p) => p.id), all.map((p) => p.id));
  assert.deepEqual(visibleProducts(all, { phoneOnly: true }).map((p) => p.id), [U("11"), U("22")]);
});
