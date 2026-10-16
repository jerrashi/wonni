/**
 * source-links.test.js — product links inside pasted text (source_links.js):
 * extraction + tokens, host detection, the Amazon / Open Graph page parsers
 * (against captured-shape fixtures) and `resolveLink` with an injected fetch.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "test-client-id";
process.env.EBAY_CLIENT_SECRET = "test-client-secret";

const {
  extractLinks, linkIndexes, tokenizeText, detectSource, slugWords, parseAmazonPage, parseOpenGraph, isAmazonBotCheck, resolveLink, resolveLinks,
} = require("../source_links");

// ── 1. extraction ──────────────────────────────────────────────────────────

test("extractLinks: every URL becomes [link N] in order; sentence punctuation stays outside", () => {
  const { text, links } = extractLinks(
    "iphone 18 pro phone case https://www.amazon.com/Spigen-Ultra-Hybrid-iPhone/dp/B0CHX1W1XY, and this: https://shop.weverse.io/en/shop/USD/artists/255/sales/64536.\nhttps://a.co/d/3xYz12Q"
  );
  assert.equal(links.length, 3);
  assert.equal(links[0].url, "https://www.amazon.com/Spigen-Ultra-Hybrid-iPhone/dp/B0CHX1W1XY");
  assert.equal(links[1].url, "https://shop.weverse.io/en/shop/USD/artists/255/sales/64536");
  assert.equal(links[2].url, "https://a.co/d/3xYz12Q");
  assert.equal(text, "iphone 18 pro phone case [link 1], and this: [link 2].\n[link 3]");
  assert.deepEqual(linkIndexes("case [link 1] and [link 2: Some Title]"), [1, 2]);
  assert.deepEqual(extractLinks("no links here").links, []);
});

test("tokenizeText: resolved titles go into the token the model reads; unresolved stay bare", () => {
  const out = tokenizeText("case [link 1]\n[link 2]", [
    { index: 1, title: "Spigen Ultra Hybrid Case for iPhone 15 Pro" },
    { index: 2, title: "" },
  ]);
  assert.equal(out, "case [link 1: Spigen Ultra Hybrid Case for iPhone 15 Pro]\n[link 2]");
});

// ── 2. host detection ──────────────────────────────────────────────────────

test("detectSource: amazon dp / gp / short links, ASIN + title slug", () => {
  const dp = detectSource("https://www.amazon.com/Spigen-Ultra-Hybrid-Designed-iPhone/dp/B0CHX1W1XY/ref=sr_1_3?keywords=case");
  assert.equal(dp.source, "amazon");
  assert.equal(dp.sourceId, "B0CHX1W1XY");
  assert.equal(dp.title, "Spigen Ultra Hybrid Designed iPhone");
  const gp = detectSource("https://amazon.co.uk/gp/product/b0chx1w1xy");
  assert.equal(gp.source, "amazon");
  assert.equal(gp.sourceId, "B0CHX1W1XY");
  assert.equal(gp.title, undefined);
  const short = detectSource("https://a.co/d/3xYz12Q");
  assert.equal(short.source, "amazon");
  assert.equal(short.sourceId, null);
  assert.equal(detectSource("https://amzn.to/3abc").source, "amazon");
});

test("detectSource: ebay item numbers, weverse sales, aliexpress items, anything else is web", () => {
  const ebay = detectSource("https://www.ebay.com/itm/Super-Smash-Bros-Brawl-Wii-CIB/137561869182?hash=abc");
  assert.equal(ebay.source, "ebay");
  assert.equal(ebay.sourceId, "137561869182");
  assert.equal(ebay.title, "Super Smash Bros Brawl Wii CIB");
  assert.equal(detectSource("https://ebay.com/itm/137561869182").sourceId, "137561869182");
  const wev = detectSource("https://shop.weverse.io/en/shop/USD/artists/255/sales/64536");
  assert.equal(wev.source, "weverse");
  assert.equal(wev.sourceId, "64536");
  const ali = detectSource("https://www.aliexpress.us/item/3256805123456789.html?spm=x");
  assert.equal(ali.source, "aliexpress");
  assert.equal(ali.sourceId, "3256805123456789");
  assert.equal(detectSource("https://www.etsy.com/listing/123/thing").source, "web");
  assert.equal(detectSource("not a url"), null);
  assert.equal(detectSource("ftp://x.y/z"), null);
  assert.equal(slugWords("B0CHX1W1XY"), "");
  assert.equal(slugWords("dp"), "");
});

// ── 3. page parsers ────────────────────────────────────────────────────────

const AMAZON_HTML = `<html><head><title>Amazon.com: Spigen Ultra Hybrid Case : Cell Phones</title></head><body>
<span id="productTitle" class="a-size-large product-title-word-break">   Spigen Ultra Hybrid Designed for iPhone 15 Pro Case (2023) - Crystal Clear  </span>
<div id="imgTagWrapperId"><img alt="x" src="https://m.media-amazon.com/images/I/61abc._AC_SX679_.jpg" data-old-hires="https://m.media-amazon.com/images/I/61abc._AC_SL1500_.jpg" id="landingImage" data-a-dynamic-image="{&quot;https://m.media-amazon.com/images/I/61abc._AC_SX425_.jpg&quot;:[425,425],&quot;https://m.media-amazon.com/images/I/61abc._AC_SX679_.jpg&quot;:[679,679]}"></div>
<script>var data = {"colorImages":{"initial":[{"hiRes":"https://m.media-amazon.com/images/I/61abc._AC_SL1500_.jpg"},{"hiRes":"https://m.media-amazon.com/images/I/71def._AC_SL1500_.jpg"}]}};</script>
<span class="a-price aok-align-center"><span class="a-offscreen">$15.99</span><span aria-hidden="true">$15.99</span></span>
<div id="feature-bullets"><ul><li><span class="a-list-item"> Crystal clear back &amp; TPU bumper </span></li><li><span class="a-list-item">Air Cushion Technology</span></li></ul></div>
</body></html>`;

test("parseAmazonPage: title, hi-res cover first then gallery, price, bullets as description", () => {
  const page = parseAmazonPage(AMAZON_HTML);
  assert.equal(page.title, "Spigen Ultra Hybrid Designed for iPhone 15 Pro Case (2023) - Crystal Clear");
  assert.deepEqual(page.imageUrls, [
    "https://m.media-amazon.com/images/I/61abc._AC_SL1500_.jpg",
    "https://m.media-amazon.com/images/I/61abc._AC_SX679_.jpg",
    "https://m.media-amazon.com/images/I/61abc._AC_SX425_.jpg",
    "https://m.media-amazon.com/images/I/71def._AC_SL1500_.jpg",
  ]);
  assert.equal(page.price, 15.99);
  assert.equal(page.description, "Crystal clear back & TPU bumper Air Cushion Technology");
});

test("parseAmazonPage: the bot-check page is null, not a listing called 'Robot Check'", () => {
  const bot = `<html><head><title>Robot Check</title></head><body><p>To discuss automated access to Amazon data please contact api-services-support@amazon.com.</p><form action="/errors/validateCaptcha"></form></body></html>`;
  assert.equal(isAmazonBotCheck(bot), true);
  assert.equal(parseAmazonPage(bot), null);
  assert.equal(isAmazonBotCheck(AMAZON_HTML), false);
});

test("parseOpenGraph: og tags in either attribute order, several images, product price", () => {
  const html = `<html><head><meta property="og:title" content="Vintage Casio F-91W Watch &amp; Box"/>
<meta content="https://cdn.example.com/a.jpg" property="og:image">
<meta property="og:image" content="https://cdn.example.com/b.jpg">
<meta property="og:image" content="http://insecure.example.com/c.jpg">
<meta property="product:price:amount" content="24.50">
<meta name="description" content="A classic digital watch."></head></html>`;
  const og = parseOpenGraph(html);
  assert.equal(og.title, "Vintage Casio F-91W Watch & Box");
  assert.deepEqual(og.imageUrls, ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]);
  assert.equal(og.price, 24.5);
  assert.equal(og.description, "A classic digital watch.");
  assert.equal(parseOpenGraph("<html><body>nothing</body></html>"), null);
});

// ── 4. resolveLink with an injected fetch ──────────────────────────────────

// Public DNS stand-in: every host resolves to a public address.
const publicLookup = async () => [{ address: "93.184.216.34" }];
const fakeFetch = (routes) => async (url) => {
  const hit = routes[url] || { status: 404, body: "" };
  if (hit.finalUrl && hit.finalUrl !== url) {
    // A redirect hop, as a real server would answer with redirect: "manual".
    routes[hit.finalUrl] = routes[hit.finalUrl] || { body: hit.body, status: hit.status };
    return { ok: false, status: 302, url, headers: { get: (h) => (h === "location" ? hit.finalUrl : null) }, text: async () => "" };
  }
  return { ok: (hit.status || 200) < 300, status: hit.status || 200, url, headers: { get: () => null }, text: async () => hit.body || "" };
};
const { isPublicAddress, assertPublicUrl } = require("../source_links");

test("resolveLink: amazon page read → ok with ASIN, photos and cost", async () => {
  const url = "https://www.amazon.com/Spigen-Ultra-Hybrid/dp/B0CHX1W1XY";
  const src = await resolveLink({ index: 1, url }, { lookup: publicLookup, fetchImpl: fakeFetch({ [url]: { body: AMAZON_HTML } }) });
  assert.equal(src.status, "ok");
  assert.equal(src.source, "amazon");
  assert.equal(src.sourceId, "B0CHX1W1XY");
  assert.equal(src.title.startsWith("Spigen Ultra Hybrid Designed"), true);
  assert.equal(src.price, 15.99);
  assert.equal(src.imageUrls.length, 4);
});

test("resolveLink: amazon bot check → partial with the slug as the title; a short link reads the ASIN off the redirect", async () => {
  const bot = `<html><head><title>Robot Check</title></head><body>To discuss automated access to Amazon data please contact api-services-support@amazon.com.</body></html>`;
  const slugged = "https://www.amazon.com/Apple-iPhone-15-Pro-Case/dp/B0CHX1W1XY";
  const a = await resolveLink({ index: 1, url: slugged }, { lookup: publicLookup, fetchImpl: fakeFetch({ [slugged]: { body: bot } }) });
  assert.equal(a.status, "partial");
  assert.equal(a.title, "Apple iPhone 15 Pro Case");
  assert.equal(a.sourceId, "B0CHX1W1XY");
  assert.match(a.error, /bot check/);

  const short = "https://a.co/d/3xYz12Q";
  const b = await resolveLink({ index: 2, url: short }, { lookup: publicLookup, fetchImpl: fakeFetch({ [short]: { body: bot, finalUrl: "https://www.amazon.com/Sony-WH-1000XM5-Headphones/dp/B09XS7JWHH?ref=x" } }) });
  assert.equal(b.status, "partial");
  assert.equal(b.sourceId, "B09XS7JWHH");
  assert.equal(b.title, "Sony WH 1000XM5 Headphones");

  const bare = "https://a.co/d/nothing";
  const c = await resolveLink({ index: 3, url: bare }, { lookup: publicLookup, fetchImpl: fakeFetch({ [bare]: { body: bot } }) });
  assert.equal(c.status, "failed");
  assert.equal(c.imageUrls.length, 0);
});

test("resolveLink: ebay item → Browse getItem detail with sell-similar fields; web → Open Graph; 404 → failed", async () => {
  const ebay = await resolveLink({ index: 1, url: "https://www.ebay.com/itm/137561869182" }, {
    ebayDetail: async (id) => {
      assert.equal(id, "v1|137561869182|0");
      return { itemId: id, title: "Pokemon Blue GBC", images: ["https://i.ebayimg.com/images/g/x/s-l1600.jpg"], categoryId: 139973, conditionId: 4000, epid: "123", aspects: { Platform: "Nintendo Game Boy" }, price: 42.5, shortDescription: "Tested" };
    },
  });
  assert.equal(ebay.status, "ok");
  assert.equal(ebay.title, "Pokemon Blue GBC");
  assert.equal(ebay.ebayCategoryId, "139973");
  assert.equal(ebay.ebayConditionId, "4000");
  assert.equal(ebay.epid, "123");
  assert.equal(ebay.price, 42.5);
  assert.deepEqual(ebay.aspects, { Platform: "Nintendo Game Boy" });

  const page = "https://www.etsy.com/listing/1/watch";
  const web = await resolveLink({ index: 2, url: page }, { lookup: publicLookup, fetchImpl: fakeFetch({ [page]: { body: `<meta property="og:title" content="Casio Watch"><meta property="og:image" content="https://cdn/x.jpg">` } }) });
  assert.equal(web.status, "ok");
  assert.equal(web.source, "web");
  assert.equal(web.title, "Casio Watch");
  assert.deepEqual(web.imageUrls, ["https://cdn/x.jpg"]);

  const gone = await resolveLink({ index: 3, url: "https://example.com/gone" }, { lookup: publicLookup, fetchImpl: fakeFetch({}) });
  assert.equal(gone.status, "failed");
  assert.match(gone.error, /404/);

  const boom = await resolveLink({ index: 4, url: "https://example.com/boom" }, { lookup: publicLookup, fetchImpl: async () => { throw new Error("socket hang up"); } });
  assert.equal(boom.status, "failed");
  assert.equal(boom.error, "socket hang up");
});

test("resolveLinks: keeps order under concurrency and never throws for one bad link", async () => {
  const urls = ["https://example.com/a", "https://example.com/b", "https://example.com/c"];
  const out = await resolveLinks(urls.map((url, i) => ({ index: i + 1, url })), {
    lookup: publicLookup,
    fetchImpl: fakeFetch({
      [urls[0]]: { body: `<meta property="og:title" content="A">` },
      [urls[2]]: { body: `<meta property="og:title" content="C">` },
    }),
  }, 2);
  assert.deepEqual(out.map((s) => s.status), ["ok", "failed", "ok"]);
  assert.deepEqual(out.map((s) => s.index), [1, 2, 3]);
});

// ── 5. SSRF guard ──────────────────────────────────────────────────────────

test("isPublicAddress: loopback, private, link-local (GCE metadata), CGNAT, multicast and v6 locals are refused", () => {
  for (const ip of ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.1", "169.254.169.254", "0.0.0.0", "100.64.0.1", "224.0.0.1", "::1", "::", "fe80::1", "fd12::1", "::ffff:127.0.0.1", "not-an-ip"]) {
    assert.equal(isPublicAddress(ip), false, ip);
  }
  for (const ip of ["8.8.8.8", "93.184.216.34", "172.32.0.1", "2606:4700::1111", "::ffff:8.8.8.8"]) {
    assert.equal(isPublicAddress(ip), true, ip);
  }
});

test("assertPublicUrl: https only, default port, no credentials, blocked hosts, and every resolved address must be public", async () => {
  await assert.rejects(assertPublicUrl("http://example.com/x", publicLookup), /https/);
  await assert.rejects(assertPublicUrl("https://example.com:8443/x", publicLookup), /port/);
  await assert.rejects(assertPublicUrl("https://user:pw@example.com/x", publicLookup), /credentials/);
  await assert.rejects(assertPublicUrl("https://metadata.google.internal/computeMetadata/v1/", publicLookup), /not a public website/);
  await assert.rejects(assertPublicUrl("https://localhost/", publicLookup), /not a public website/);
  await assert.rejects(assertPublicUrl("https://169.254.169.254/latest/meta-data/", publicLookup), /not a public website/);
  await assert.rejects(assertPublicUrl("https://[::1]/", publicLookup), /not a public website/);
  // A public-looking name that resolves (even partly) to a private address.
  await assert.rejects(assertPublicUrl("https://evil.example/", async () => [{ address: "93.184.216.34" }, { address: "10.0.0.5" }]), /not a public website/);
  await assert.rejects(assertPublicUrl("https://nx.example/", async () => []), /not a public website/);
  const ok = await assertPublicUrl("https://example.com/ok", publicLookup);
  assert.equal(ok.url.hostname, "example.com");
  assert.deepEqual(ok.addresses, [{ address: "93.184.216.34", family: 4 }]);
  for (const ip of ["::ffff:a00:1", "::ffff:7f00:1", "64:ff9b::a00:1", "2002:0a00:0001::", "192.0.2.1", "198.18.0.1"]) assert.equal(isPublicAddress(ip), false, ip);
  assert.equal(isPublicAddress("::ffff:5db8:d822"), true);
});

test("resolveLink: a redirect to a private address is refused mid-chain; a plain http link is refused before any fetch", async () => {
  let fetched = [];
  const src = await resolveLink({ index: 1, url: "https://short.example/abc" }, {
    lookup: async (host) => [{ address: host === "short.example" ? "93.184.216.34" : "169.254.169.254" }],
    fetchImpl: async (url) => {
      fetched.push(url);
      return { ok: false, status: 302, url, headers: { get: (h) => (h === "location" ? "https://metadata.google.internal/computeMetadata/v1/" : null) }, text: async () => "" };
    },
  });
  assert.equal(src.status, "failed");
  assert.match(src.error, /not a public website/);
  assert.deepEqual(fetched, ["https://short.example/abc"], "the metadata hop was never requested");

  fetched = [];
  const http = await resolveLink({ index: 2, url: "http://example.com/page" }, { lookup: publicLookup, fetchImpl: async (url) => { fetched.push(url); throw new Error("should not fetch"); } });
  assert.equal(http.status, "failed");
  assert.match(http.error, /https/);
  assert.deepEqual(fetched, []);

  const hops = await resolveLink({ index: 3, url: "https://a.example/1" }, {
    lookup: publicLookup,
    fetchImpl: async (url) => ({ ok: false, status: 301, url, headers: { get: (h) => (h === "location" ? url + "x" : null) }, text: async () => "" }),
  });
  assert.equal(hops.status, "failed");
  assert.match(hops.error, /Too many redirects/);
});

test("fetchHtml: a huge body is read only up to the cap and the stream is cancelled", async () => {
  const { fetchHtml } = require("../source_links")._internal;
  let reads = 0;
  let cancelled = false;
  const chunk = new TextEncoder().encode("x".repeat(256 * 1024));
  const res = await fetchHtml("https://big.example/page", async () => ({
    ok: true, status: 200,
    headers: { get: () => null },
    body: { getReader: () => ({ read: async () => { reads++; return { value: chunk, done: false }; }, cancel: async () => { cancelled = true; } }) },
    text: async () => { throw new Error("should stream"); },
  }), publicLookup);
  assert.equal(res.html.length, 2 * 1024 * 1024);
  assert.equal(reads, 8);
  assert.equal(cancelled, true);

  await assert.rejects(fetchHtml("https://big.example/huge", async () => ({
    ok: true, status: 200, headers: { get: (h) => (h === "content-length" ? String(100 * 1024 * 1024) : null) }, text: async () => "",
  }), publicLookup), /too large/);
});

test("pinnedFetch: connects through a lookup that returns only the validated addresses, never re-resolving the host", async () => {
  const { pinnedFetch } = require("../source_links")._internal;
  const { PassThrough } = require("stream");
  let seen;
  const request = (options, onResponse) => {
    seen = options;
    const res = new PassThrough();
    res.statusCode = 200;
    res.headers = { "content-type": "text/html", location: undefined };
    process.nextTick(() => { onResponse(res); res.end("<title>hi</title>"); });
    return { on() {}, end() {} };
  };
  const res = await pinnedFetch("https://example.com/a?b=1", { headers: { "User-Agent": "t" }, pinnedAddresses: [{ address: "93.184.216.34", family: 4 }] }, request);
  assert.equal(seen.hostname, "example.com");
  assert.equal(seen.servername, "example.com");
  assert.equal(seen.port, 443);
  assert.equal(seen.path, "/a?b=1");
  await new Promise((done) => seen.lookup("example.com", {}, (err, address, family) => { assert.equal(err, null); assert.equal(address, "93.184.216.34"); assert.equal(family, 4); done(); }));
  await new Promise((done) => seen.lookup("example.com", { all: true }, (err, list) => { assert.deepEqual(list, [{ address: "93.184.216.34", family: 4 }]); done(); }));
  assert.equal(res.ok, true);
  assert.equal(res.headers.get("Content-Type"), "text/html");
  assert.equal(await res.text(), "<title>hi</title>");

  const none = await pinnedFetch("https://example.com/", { pinnedAddresses: [] }, request);
  await new Promise((done) => seen.lookup("example.com", {}, (err) => { assert.match(err.message, /No validated address/); done(); }));
  assert.equal(none.ok, true);
});

test("fetchBytes: follows a checked redirect, refuses oversize and non-public hosts, returns buffer + type", async () => {
  const { fetchBytes } = require("../source_links");
  const bytes = new TextEncoder().encode("JPEGDATA");
  const routes = {
    "https://i.ebayimg.com/a.jpg": { status: 302, location: "https://i.ebayimg.com/b.jpg" },
    "https://i.ebayimg.com/b.jpg": { status: 200, type: "image/jpeg", body: bytes },
    "https://i.ebayimg.com/huge.jpg": { status: 200, type: "image/jpeg", length: String(50 * 1024 * 1024), body: bytes },
  };
  const fetchImpl = async (url) => {
    const r = routes[url] || { status: 404 };
    return {
      ok: r.status === 200, status: r.status, url,
      headers: { get: (h) => ({ location: r.location, "content-type": r.type, "content-length": r.length })[h] ?? null },
      body: r.body ? { getReader: () => { let done = false; return { read: async () => done ? { done: true } : (done = true, { value: r.body, done: false }), cancel: async () => {} }; } } : undefined,
    };
  };
  const got = await fetchBytes("https://i.ebayimg.com/a.jpg", { fetchImpl, lookup: publicLookup });
  assert.equal(got.contentType, "image/jpeg");
  assert.equal(got.buffer.toString(), "JPEGDATA");
  await assert.rejects(fetchBytes("https://i.ebayimg.com/huge.jpg", { fetchImpl, lookup: publicLookup }), /too large/);
  await assert.rejects(fetchBytes("https://i.ebayimg.com/missing.jpg", { fetchImpl, lookup: publicLookup }), /404/);
  await assert.rejects(fetchBytes("https://169.254.169.254/x.jpg", { fetchImpl, lookup: publicLookup }), /not a public website/);
});
