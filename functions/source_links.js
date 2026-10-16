/**
 * source_links.js — product links inside pasted text, for `textToListings`.
 *
 * The text a reseller pastes may carry product URLs: an Amazon order they want
 * to flip, an AliExpress or Weverse page to dropship, an eBay listing to copy.
 * Links are handled BEFORE the AI parse, in plain code, so the model never has
 * to find or reproduce a URL:
 *
 *   1. `extractLinks(text)`  — every http(s) URL, in order, replaced in the
 *                              text by a token `[link N]`.
 *   2. `resolveLink(url)`    — host → adapter → a SourceProduct
 *                              { source, sourceId, url, title, description,
 *                                imageUrls, price, status }.
 *                              Adapters: weverse (page's __NEXT_DATA__),
 *                              aliexpress (DS API, needs the user's connection),
 *                              amazon (ASIN + title slug from the URL, then a
 *                              best-effort page fetch — Amazon often answers a
 *                              bot check, so the slug is the guaranteed floor),
 *                              ebay (Browse getItem), web (Open Graph tags).
 *   3. `tokenizeText(text, sources)` — the tokens become `[link N: <title>]`,
 *                              so the model reads a real product name and
 *                              writes a proper listing for "iphone case [link 1]"
 *                              or for a bare link on its own line.
 *
 * After the parse the caller attaches each source back to the listing whose
 * `sourceText` carries its token (bulk_text_drafts.js `attachSources`): its
 * photos become the listing's photos, its price the cost (`sourcePrice`), its
 * URL the provenance. Comps still run — the user resells at a market price,
 * not at what they paid.
 *
 * Nothing here persists. Every adapter returns `status: "failed"` with a
 * reason instead of throwing, so one dead link never fails the whole paste.
 *
 * Security: a pasted URL is user input fetched from inside a Cloud Function.
 * `fetchHtml` only fetches https on the default port, resolves the host first
 * and refuses anything that is not a public address (loopback, private,
 * link-local incl. the GCE metadata server 169.254.169.254, *.internal), then
 * CONNECTS TO THE VALIDATED ADDRESSES (`pinnedFetch`, a custom `lookup` on
 * https.request) so the name cannot be re-resolved to something else in
 * between, and follows redirects by hand so every hop is checked the same way.
 */

"use strict";

const dns = require("dns").promises;
const net = require("net");
const https = require("https");

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";
const FETCH_TIMEOUT_MS = 12000;
const MAX_HTML_BYTES = 2 * 1024 * 1024;
const MAX_SOURCE_PHOTOS = 8;
const MAX_LINKS = 40;

const URL_RE = /https?:\/\/[^\s<>"'`\])}]+/gi;

// ── 1. find the links ──────────────────────────────────────────────────────

/** Trailing punctuation that belongs to the sentence, not the URL. */
function trimUrl(raw) {
  return raw.replace(/[.,;:!?]+$/, "");
}

/**
 * Every URL in `text`, in order, each replaced by `[link N]` (1-based). The
 * same URL pasted twice is two links — they may belong to two entries.
 */
function extractLinks(text) {
  const links = [];
  const tokenized = String(text || "").replace(URL_RE, (match) => {
    if (links.length >= MAX_LINKS) return match;
    const url = trimUrl(match);
    const tail = match.slice(url.length);
    links.push({ index: links.length + 1, url });
    return `[link ${links.length}]${tail}`;
  });
  return { text: tokenized, links };
}

/** Which `[link N]` tokens a snippet carries. */
function linkIndexes(text) {
  return [...String(text || "").matchAll(/\[link (\d+)(?::|\])/g)].map((m) => Number(m[1]));
}

/** `[link N]` → `[link N: Title]` so the model sees what the link is. A
 *  failed link keeps whatever the URL itself said (slug) or stays bare. */
function tokenizeText(text, sources) {
  return String(text || "").replace(/\[link (\d+)\]/g, (match, n) => {
    const src = sources.find((s) => s.index === Number(n));
    const title = src?.title?.trim();
    return title ? `[link ${n}: ${title.slice(0, 160)}]` : match;
  });
}

// ── 2. host → adapter ──────────────────────────────────────────────────────

const AMAZON_HOSTS = /(^|\.)amazon\.[a-z.]+$|(^|\.)amzn\.(to|com|eu|asia)$|^a\.co$/i;
const EBAY_HOSTS = /(^|\.)ebay\.[a-z.]+$|^ebay\.us$/i;
const ALIEXPRESS_HOSTS = /(^|\.)aliexpress\.(com|us|ru)$|^a\.aliexpress\.com$/i;

/** Decode "Apple-iPhone-15-Pro-Case-Clear" style path slugs into words. */
function slugWords(segment) {
  try { segment = decodeURIComponent(segment); } catch { /* keep raw */ }
  const words = segment.replace(/[-_+]+/g, " ").replace(/\s+/g, " ").trim();
  // A slug is at least two words and is not an id (B0..., 1234567890).
  if (words.split(" ").length < 2 || /^[A-Z0-9]{10}$/.test(words)) return "";
  return words.slice(0, 160);
}

/**
 * `{ source, sourceId, title? }` from the URL alone, before any fetch.
 * `source` is one of weverse | aliexpress | amazon | ebay | web.
 */
function detectSource(rawUrl) {
  let url;
  try { url = new URL(rawUrl); } catch { return null; }
  if (!/^https?:$/.test(url.protocol)) return null;
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  const segments = url.pathname.split("/").filter(Boolean);

  if (host === "shop.weverse.io") {
    const m = url.pathname.match(/\/artists\/(\d+)\/sales\/(\d+)/);
    return { source: "weverse", sourceId: m ? m[2] : null, url: url.href };
  }
  if (ALIEXPRESS_HOSTS.test(host)) {
    const m = url.pathname.match(/\/item\/(\d+)\.html/) || url.search.match(/[?&]id=(\d+)/);
    return { source: "aliexpress", sourceId: m ? m[1] : null, url: url.href };
  }
  if (AMAZON_HOSTS.test(host)) {
    // /dp/ASIN, /gp/product/ASIN, /gp/aw/d/ASIN, /<slug>/dp/ASIN; short links
    // (amzn.to, a.co) carry no ASIN until followed.
    const asinAt = segments.findIndex((s, i) => /^(dp|product|d)$/i.test(s) && /^[A-Z0-9]{10}$/i.test(segments[i + 1] || ""));
    const asin = asinAt >= 0 ? segments[asinAt + 1].toUpperCase() : null;
    const slug = asinAt > 0 ? slugWords(segments[asinAt - 1]) : "";
    return { source: "amazon", sourceId: asin, url: url.href, title: slug || undefined };
  }
  if (EBAY_HOSTS.test(host)) {
    // /itm/<slug>/123456789012 or /itm/123456789012
    const m = url.pathname.match(/\/itm\/(?:[^/]+\/)?(\d{9,15})/);
    const slug = url.pathname.match(/\/itm\/([^/]+)\/\d{9,15}/);
    return { source: "ebay", sourceId: m ? m[1] : null, url: url.href, title: slug ? slugWords(slug[1]) || undefined : undefined };
  }
  return { source: "web", sourceId: null, url: url.href };
}

// ── page fetch + HTML helpers ──────────────────────────────────────────────

const MAX_REDIRECTS = 5;

/**
 * Is this a public internet address? The pasted URL is user input fetched
 * from inside a Cloud Function, so anything that resolves to loopback,
 * private, link-local (the GCE metadata server lives at 169.254.169.254) or
 * unspecified space is refused — before the first request and again on every
 * redirect hop (`fetchHtml` follows them by hand).
 */
function isPublicAddress(ip) {
  const v = net.isIP(ip);
  if (v === 4) {
    const [a, b] = ip.split(".").map(Number);
    if (a === 0 || a === 10 || a === 127) return false;
    if (a === 169 && b === 254) return false;
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 168) return false;
    if (a === 100 && b >= 64 && b <= 127) return false;   // carrier NAT
    if (a === 192 && b === 0) return false;                // 192.0.0.0/24 + 192.0.2.0/24 (IETF, TEST-NET)
    if (a === 198 && (b === 18 || b === 19)) return false; // benchmarking
    if (a >= 224) return false;                            // multicast / reserved / broadcast
    return true;
  }
  if (v === 6) {
    const lower = ip.toLowerCase();
    if (lower === "::" || lower === "::1") return false;
    if (lower.startsWith("fe8") || lower.startsWith("fe9") || lower.startsWith("fea") || lower.startsWith("feb")) return false; // link-local
    if (lower.startsWith("fc") || lower.startsWith("fd")) return false;  // unique local
    if (lower.startsWith("::ffff:")) {
      // IPv4-mapped, dotted ("::ffff:10.0.0.1") or hex ("::ffff:a00:1") form.
      const rest = lower.slice(7);
      if (net.isIP(rest) === 4) return isPublicAddress(rest);
      const [hi, lo] = rest.split(":").map((h) => parseInt(h || "0", 16));
      if (!Number.isFinite(hi) || !Number.isFinite(lo)) return false;
      return isPublicAddress(`${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`);
    }
    if (lower.startsWith("64:ff9b:")) return false;   // NAT64 — the embedded v4 is not checked, refuse
    if (lower.startsWith("2001:db8:")) return false;  // documentation
    if (lower.startsWith("2002:")) return false;      // 6to4 — embeds an arbitrary v4
    return true;
  }
  return false;
}

const BLOCKED_HOSTS = new Set(["localhost", "metadata.google.internal", "metadata", "instance-data"]);

/** Throws unless `rawUrl` is https on the default port and its host resolves
 *  only to public addresses. `lookup` is injectable for tests. */
async function assertPublicUrl(rawUrl, lookup = (host) => dns.lookup(host, { all: true })) {
  const url = new URL(rawUrl);
  if (url.protocol !== "https:") throw new Error("Only https links are fetched.");
  if (url.port && url.port !== "443") throw new Error("Only the default https port is fetched.");
  if (url.username || url.password) throw new Error("Links with credentials are not fetched.");
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (BLOCKED_HOSTS.has(host) || host.endsWith(".internal") || host.endsWith(".local") || host.endsWith(".localhost")) {
    throw new Error("That address is not a public website.");
  }
  const literal = host.startsWith("[") ? host.slice(1, -1) : host;
  const addresses = net.isIP(literal) ? [{ address: literal, family: net.isIP(literal) }] : await lookup(literal);
  if (!addresses.length || addresses.some((a) => !isPublicAddress(a.address))) {
    throw new Error("That address is not a public website.");
  }
  // The caller connects to THESE addresses (pinnedFetch), so a name cannot be
  // re-resolved to something else between the check and the connection.
  return { url, addresses: addresses.map((a) => ({ address: a.address, family: a.family || net.isIP(a.address) })) };
}

/**
 * A fetch-shaped GET over Node https that connects to `pinnedAddresses` (the
 * ones `assertPublicUrl` just validated) instead of resolving the host again
 * — closes the DNS-rebinding window between check and connect. Returns
 * { ok, status, headers.get, body (web stream), text() } like fetch, with
 * redirects left to the caller (status 3xx + location). `request` is
 * injectable for tests.
 */
function pinnedFetch(url, { signal, headers = {}, pinnedAddresses = [] } = {}, request = https.request) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    let next = 0;
    const lookup = (hostname, options, cb) => {
      if (!pinnedAddresses.length) return cb(new Error("No validated address to connect to."));
      if (options && options.all) return cb(null, pinnedAddresses);
      const pick = pinnedAddresses[next++ % pinnedAddresses.length];
      cb(null, pick.address, pick.family);
    };
    const req = request({
      protocol: "https:",
      hostname: target.hostname,
      port: 443,
      path: `${target.pathname}${target.search}`,
      method: "GET",
      headers,
      lookup,
      servername: target.hostname,
      signal,
    }, (res) => {
      const { Readable } = require("stream");
      resolve({
        ok: res.statusCode >= 200 && res.statusCode < 300,
        status: res.statusCode,
        url,
        headers: { get: (name) => { const v = res.headers[String(name).toLowerCase()]; return Array.isArray(v) ? v[0] : (v ?? null); } },
        body: Readable.toWeb(res),
        text: () => new Promise((ok, bad) => { const parts = []; res.on("data", (c) => parts.push(c)); res.on("end", () => ok(Buffer.concat(parts).toString("utf8"))); res.on("error", bad); }),
      });
    });
    req.on("error", reject);
    req.end();
  });
}

/** The first MAX_HTML_BYTES of a response body. Streams and stops at the
 *  cap, so a giant (or endless) body never lands in memory whole. */
async function readCapped(res) {
  const declared = Number(res.headers?.get?.("content-length"));
  if (Number.isFinite(declared) && declared > MAX_HTML_BYTES * 4) throw new Error("The page is too large to read.");
  if (!res.body || typeof res.body.getReader !== "function") return String(await res.text()).slice(0, MAX_HTML_BYTES);
  const reader = res.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: false });
  let out = "";
  try {
    while (out.length < MAX_HTML_BYTES) {
      const { value, done } = await reader.read();
      if (done) break;
      out += decoder.decode(value, { stream: true });
    }
  } finally {
    reader.cancel().catch(() => {});
  }
  return out.slice(0, MAX_HTML_BYTES);
}

/**
 * GET a binary resource (an image to re-host) from a public https URL, with the
 * same host checks and manual redirects as `fetchHtml`, reading at most
 * `maxBytes`. Returns { buffer, contentType }. Used by commit_listing_proposals.
 */
async function fetchBytes(url, { maxBytes = 10 * 1024 * 1024, fetchImpl = pinnedFetch, lookup = undefined } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    let current = url;
    for (let hop = 0; ; hop++) {
      const { addresses } = await assertPublicUrl(current, lookup);
      const res = await fetchImpl(current, {
        redirect: "manual",
        pinnedAddresses: addresses,
        signal: controller.signal,
        headers: { "User-Agent": USER_AGENT, "Accept": "image/*,*/*;q=0.8" },
      });
      const location = res.status >= 300 && res.status < 400 ? res.headers?.get?.("location") : null;
      if (location) {
        if (hop >= MAX_REDIRECTS) throw new Error("Too many redirects.");
        current = new URL(location, current).href;
        continue;
      }
      if (!res.ok) throw new Error(`Failed to download image (${res.status})`);
      const declared = Number(res.headers?.get?.("content-length"));
      if (Number.isFinite(declared) && declared > maxBytes) throw new Error("Image too large");
      const contentType = String(res.headers?.get?.("content-type") || "").split(";")[0].trim().toLowerCase();
      const chunks = [];
      let size = 0;
      if (res.body && typeof res.body.getReader === "function") {
        const reader = res.body.getReader();
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > maxBytes) throw new Error("Image too large");
            chunks.push(Buffer.from(value));
          }
        } finally {
          reader.cancel().catch(() => {});
        }
      } else {
        const text = await res.arrayBuffer?.();
        if (!text) throw new Error("No body");
        if (text.byteLength > maxBytes) throw new Error("Image too large");
        chunks.push(Buffer.from(text));
      }
      return { buffer: Buffer.concat(chunks), contentType };
    }
  } finally {
    clearTimeout(timer);
  }
}

/**
 * GET a page as a browser would. Redirects are followed by hand so every hop
 * is checked by `assertPublicUrl` (a public URL must not bounce us to the
 * metadata server). `fetchImpl` / `lookup` are injectable for tests.
 */
async function fetchHtml(url, fetchImpl = pinnedFetch, lookup = undefined) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    let current = url;
    for (let hop = 0; ; hop++) {
      const { addresses } = await assertPublicUrl(current, lookup);
      const res = await fetchImpl(current, {
        redirect: "manual",
        pinnedAddresses: addresses,
        signal: controller.signal,
        headers: {
          "User-Agent": USER_AGENT,
          "Accept": "text/html,application/xhtml+xml",
          "Accept-Language": "en-US,en;q=0.9",
        },
      });
      const location = res.status >= 300 && res.status < 400 ? res.headers?.get?.("location") : null;
      if (location) {
        if (hop >= MAX_REDIRECTS) throw new Error("Too many redirects.");
        current = new URL(location, current).href;
        continue;
      }
      return { ok: res.ok, status: res.status, url: current, html: await readCapped(res) };
    }
  } finally {
    clearTimeout(timer);
  }
}

function decodeEntities(s) {
  return String(s || "")
    .replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/\s+/g, " ").trim();
}

/** `<meta property="og:title" content="...">` in either attribute order. */
function metaContent(html, name) {
  const re = new RegExp(
    `<meta[^>]+(?:property|name)=["']${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}["'][^>]*content=["']([^"']*)["']|` +
    `<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}["']`,
    "i"
  );
  const m = re.exec(html);
  return m ? decodeEntities(m[1] ?? m[2]) : "";
}

function metaAll(html, name) {
  const out = [];
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(
    `<meta[^>]+(?:property|name)=["']${escaped}["'][^>]*content=["']([^"']*)["']|` +
    `<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']${escaped}["']`,
    "gi"
  );
  for (const m of html.matchAll(re)) out.push(decodeEntities(m[1] ?? m[2]));
  return out;
}

function stripTags(html) {
  return decodeEntities(String(html || "").replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, "").replace(/<[^>]+>/g, " "));
}

function parsePriceText(text) {
  const m = String(text || "").replace(/,/g, "").match(/\d+(?:\.\d{1,2})?/);
  const n = m ? Number(m[0]) : NaN;
  return Number.isFinite(n) && n > 0 && n < 1e6 ? Math.round(n * 100) / 100 : undefined;
}

const httpsOnly = (u) => typeof u === "string" && /^https:\/\//i.test(u);

// ── adapters ───────────────────────────────────────────────────────────────

/** Amazon's bot-check page: no product data, and retrying now won't help. */
function isAmazonBotCheck(html) {
  return /Robot Check|To discuss automated access|api-services-support@amazon\.com|captcha/i.test(html.slice(0, 20000))
    && !/id="productTitle"/.test(html);
}

/**
 * Amazon product page → title, cover + gallery, price, bullets. Every field
 * is best effort; `null` means the page gave nothing usable (bot check, 404).
 */
function parseAmazonPage(html) {
  if (!html || isAmazonBotCheck(html)) return null;
  const title = decodeEntities((/<span[^>]+id="productTitle"[^>]*>([\s\S]*?)<\/span>/i.exec(html) || [])[1] || "")
    || metaContent(html, "og:title") || decodeEntities((/<title>([\s\S]*?)<\/title>/i.exec(html) || [])[1] || "").replace(/\s*[:|-]\s*Amazon\.com.*$/i, "");
  if (!title) return null;

  const imageUrls = [];
  const landing = /<img[^>]+id="landingImage"[^>]*>/i.exec(html)?.[0] || "";
  const hires = /data-old-hires="([^"]+)"/i.exec(landing)?.[1];
  if (httpsOnly(hires)) imageUrls.push(hires);
  // data-a-dynamic-image='{"https://...jpg":[w,h], ...}' — biggest first.
  const dyn = /data-a-dynamic-image="([^"]+)"/i.exec(landing)?.[1];
  if (dyn) {
    try {
      const map = JSON.parse(decodeEntities(dyn));
      for (const [u] of Object.entries(map).sort((a, b) => (b[1]?.[0] || 0) - (a[1]?.[0] || 0))) {
        if (httpsOnly(u) && !imageUrls.includes(u)) imageUrls.push(u);
      }
    } catch { /* ignore */ }
  }
  // The gallery thumbnails' hi-res variants ("hiRes":"https://...").
  for (const m of html.matchAll(/"hiRes":"(https:\/\/[^"]+)"/g)) {
    if (!imageUrls.includes(m[1])) imageUrls.push(m[1]);
    if (imageUrls.length >= MAX_SOURCE_PHOTOS) break;
  }
  const og = metaContent(html, "og:image");
  if (!imageUrls.length && httpsOnly(og)) imageUrls.push(og);

  const priceText = (/<span class="a-price[^"]*"[^>]*>[\s\S]*?<span class="a-offscreen">([^<]+)<\/span>/i.exec(html) || [])[1]
    || (/id="priceblock_(?:our|deal|sale)price"[^>]*>([^<]+)</i.exec(html) || [])[1];
  const bullets = [...html.matchAll(/<div[^>]+id="feature-bullets"[\s\S]*?<\/div>/gi)].map((m) => m[0])[0] || "";
  const description = [...bullets.matchAll(/<span class="a-list-item">([\s\S]*?)<\/span>/gi)]
    .map((m) => stripTags(m[1])).filter(Boolean).join(" ").slice(0, 2000);

  return { title: title.slice(0, 300), imageUrls: imageUrls.slice(0, MAX_SOURCE_PHOTOS), price: parsePriceText(priceText), description };
}

/** Any page: Open Graph / standard meta tags. */
function parseOpenGraph(html) {
  if (!html) return null;
  const title = metaContent(html, "og:title") || metaContent(html, "twitter:title")
    || decodeEntities((/<title>([\s\S]*?)<\/title>/i.exec(html) || [])[1] || "");
  if (!title) return null;
  const imageUrls = [...metaAll(html, "og:image"), ...metaAll(html, "og:image:secure_url"), metaContent(html, "twitter:image")]
    .filter(httpsOnly).filter((u, i, arr) => arr.indexOf(u) === i).slice(0, MAX_SOURCE_PHOTOS);
  const price = parsePriceText(metaContent(html, "product:price:amount") || metaContent(html, "og:price:amount"));
  const description = (metaContent(html, "og:description") || metaContent(html, "description")).slice(0, 2000);
  return { title: title.slice(0, 300), imageUrls, price, description };
}

/**
 * Resolve one link. `deps` (injectable):
 *   fetchImpl         — global fetch
 *   lookup(host)      — dns.lookup({all:true}); every fetched host must resolve to public addresses
 *   uid               — for the AliExpress DS API (user's connection)
 *   weverse           — { parseWeverseUrl, fetchWeverseSale, mapSaleToProduct }
 *   aliexpress        — { fetchAliexpressDsProduct }
 *   ebayDetail(itemId) — ebay_comps retrieveCompDetail
 */
async function resolveLink(link, deps = {}) {
  const fetchImpl = deps.fetchImpl || pinnedFetch;
  const detected = detectSource(link.url);
  const base = {
    index: link.index,
    url: link.url,
    source: detected?.source || "web",
    sourceId: detected?.sourceId || null,
    title: detected?.title || "",
    description: "",
    imageUrls: [],
    price: undefined,
    status: "failed",
    error: "",
  };
  if (!detected) return { ...base, error: "Not a valid URL." };

  const done = (data) => ({
    ...base,
    ...Object.fromEntries(Object.entries(data).filter(([, v]) => v !== undefined && v !== null && v !== "")),
    status: "ok",
  });
  const failed = (error) => ({ ...base, error: String(error?.message || error || "failed").slice(0, 200) });

  try {
    switch (detected.source) {
      case "weverse": {
        const w = deps.weverse || require("./weverse_product");
        const parsed = w.parseWeverseUrl(link.url);
        if (!parsed) return failed("Not a Weverse sale URL.");
        const product = w.mapSaleToProduct(await w.fetchWeverseSale(parsed.url, parsed.saleId), parsed.url);
        return done({
          sourceId: parsed.saleId,
          title: product.title,
          description: product.description,
          imageUrls: (product.images || []).filter(httpsOnly).slice(0, MAX_SOURCE_PHOTOS),
          price: parsePriceText(product.price),
        });
      }
      case "aliexpress": {
        if (!detected.sourceId) return failed("No AliExpress item id in the link.");
        const a = deps.aliexpress || require("./aliexpress_product");
        const product = await a.fetchAliexpressDsProduct(detected.sourceId, link.url, deps.uid);
        return done({
          title: product.title,
          imageUrls: (product.images || []).filter(httpsOnly).slice(0, MAX_SOURCE_PHOTOS),
          price: parsePriceText(product.price),
        });
      }
      case "ebay": {
        if (!detected.sourceId) return failed("No eBay item number in the link.");
        const detail = deps.ebayDetail
          ? await deps.ebayDetail(`v1|${detected.sourceId}|0`)
          : await require("./ebay_comps")._internal.retrieveCompDetail(`v1|${detected.sourceId}|0`);
        return done({
          title: detail.title,
          description: (detail.shortDescription || detail.description || "").slice(0, 2000),
          imageUrls: (detail.images || []).filter(httpsOnly).slice(0, MAX_SOURCE_PHOTOS),
          price: parsePriceText(detail.price),
          ebayItemId: detail.itemId,
          ebayCategoryId: detail.categoryId ? String(detail.categoryId) : undefined,
          ebayConditionId: detail.conditionId ? String(detail.conditionId) : undefined,
          epid: detail.epid ? String(detail.epid) : undefined,
          aspects: detail.aspects,
        });
      }
      case "amazon": {
        const page = await fetchHtml(link.url, fetchImpl, deps.lookup);
        // A short link resolves to the real product URL — read the ASIN off it.
        const resolved = detectSource(page.url);
        const sourceId = detected.sourceId || resolved?.sourceId || null;
        const slug = detected.title || resolved?.title || "";
        const parsed = page.ok ? parseAmazonPage(page.html) : null;
        if (!parsed) {
          // The guaranteed floor: ASIN + whatever the URL slug says.
          return slug || sourceId
            ? { ...base, sourceId, title: slug, status: "partial", error: page.ok ? "Amazon returned a bot check; using the link's own words." : `Amazon returned ${page.status}.` }
            : failed(page.ok ? "Amazon returned a bot check and the link carries no product name." : `Amazon returned ${page.status}.`);
        }
        return done({ sourceId, ...parsed });
      }
      default: {
        const page = await fetchHtml(link.url, fetchImpl, deps.lookup);
        if (!page.ok) return failed(`The page returned ${page.status}.`);
        const parsed = parseOpenGraph(page.html);
        return parsed ? done(parsed) : failed("The page has no product information we can read.");
      }
    }
  } catch (e) {
    return failed(e);
  }
}

/** Resolve every link, a few at a time, in order. */
async function resolveLinks(links, deps = {}, concurrency = 4) {
  const out = new Array(links.length);
  let next = 0;
  async function worker() {
    while (next < links.length) {
      const i = next++;
      out[i] = await resolveLink(links[i], deps);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, links.length) }, worker));
  return out;
}

module.exports = {
  MAX_SOURCE_PHOTOS,
  extractLinks,
  linkIndexes,
  tokenizeText,
  detectSource,
  slugWords,
  parseAmazonPage,
  parseOpenGraph,
  isAmazonBotCheck,
  resolveLink,
  resolveLinks,
  isPublicAddress,
  assertPublicUrl,
  fetchBytes,
  _internal: { fetchHtml, pinnedFetch, metaContent, decodeEntities, parsePriceText },
};
