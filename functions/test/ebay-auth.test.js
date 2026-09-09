/**
 * ebay-auth.test.js — the OAuth-scope-intersection logic that unblocks
 * syncSales / getOrderTakeHome without breaking web-user token refreshes.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { refreshScopeFor, hasOrderReadScopes, EBAY_SCOPES } = require("../ebay_auth");

const S = {
  inv: "https://api.ebay.com/oauth/api_scope/sell.inventory",
  acct: "https://api.ebay.com/oauth/api_scope/sell.account",
  ful: "https://api.ebay.com/oauth/api_scope/sell.fulfillment",
  fin: "https://api.ebay.com/oauth/api_scope/sell.finances",
};

test("refreshScopeFor: legacy connection (no recorded grant) → safe base subset", () => {
  assert.equal(refreshScopeFor({}), EBAY_SCOPES);
  assert.equal(refreshScopeFor({ grantedScopes: undefined }), EBAY_SCOPES);
});

test("refreshScopeFor: web-only grant → base only, never requests fulfillment/finances", () => {
  const scope = refreshScopeFor({ grantedScopes: `${S.inv} ${S.acct}` });
  assert.ok(!scope.includes("fulfillment"));
  assert.ok(!scope.includes("finances"));
});

test("refreshScopeFor: full grant → intersection includes fulfillment + finances", () => {
  const scope = refreshScopeFor({ grantedScopes: `${S.inv} ${S.acct} ${S.ful} ${S.fin}` });
  assert.ok(scope.includes("sell.fulfillment"));
  assert.ok(scope.includes("sell.finances"));
});

test("refreshScopeFor: ignores extra granted scopes we don't ask for (identity)", () => {
  const scope = refreshScopeFor({
    grantedScopes: `${S.inv} ${S.acct} https://api.ebay.com/oauth/api_scope/commerce.identity.readonly`,
  });
  assert.ok(!scope.includes("identity"));
});

test("hasOrderReadScopes: true only when fulfillment was granted", () => {
  assert.equal(hasOrderReadScopes({ grantedScopes: `${S.inv} ${S.acct} ${S.ful}` }), true);
  assert.equal(hasOrderReadScopes({ grantedScopes: `${S.inv} ${S.acct}` }), false);
  assert.equal(hasOrderReadScopes({}), false);
});
