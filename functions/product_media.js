const https = require("https");
const Jimp = require("jimp");

const DEFAULT_ALLOWED_IMAGE_HOSTS = [
  ".weverseshop.io",
  ".cdn-contents.weverseshop.io",
  ".alicdn.com",
  ".aliexpress-media.com",
  ".storage.googleapis.com",
  ".firebasestorage.googleapis.com",
];

const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

function isAllowedImageUrl(rawUrl, allowedHosts = DEFAULT_ALLOWED_IMAGE_HOSTS) {
  try {
    const { protocol, hostname } = new URL(rawUrl);
    if (protocol !== "https:") return false;
    return allowedHosts.some((host) => hostname === host.slice(1) || hostname.endsWith(host));
  } catch {
    return false;
  }
}

function downloadBuffer(url, { allowedHosts = DEFAULT_ALLOWED_IMAGE_HOSTS, maxRedirects = 3 } = {}, depth = 0) {
  if (!isAllowedImageUrl(url, allowedHosts)) {
    return Promise.reject(new Error(`Disallowed image URL: ${url}`));
  }
  if (depth > maxRedirects) {
    return Promise.reject(new Error("Too many redirects"));
  }

  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const nextUrl = new URL(res.headers.location, url).href;
          return downloadBuffer(nextUrl, { allowedHosts, maxRedirects }, depth + 1).then(resolve).catch(reject);
        }

        if (res.statusCode && res.statusCode >= 400) {
          res.resume();
          return reject(new Error(`Failed to download image (${res.statusCode})`));
        }

        const chunks = [];
        let size = 0;
        res.on("data", (chunk) => {
          size += chunk.length;
          if (size > MAX_IMAGE_BYTES) {
            res.destroy();
            reject(new Error("Image too large"));
            return;
          }
          chunks.push(chunk);
        });
        res.on("end", () => resolve(Buffer.concat(chunks)));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

function publicStorageUrl(bucketName, path) {
  return `https://storage.googleapis.com/${bucketName}/${path.split("/").map(encodeURIComponent).join("/")}`;
}

async function savePublicBuffer(bucketName, file, buffer, contentType) {
  await file.save(buffer, { contentType, public: true });
  return publicStorageUrl(bucketName, file.name);
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

async function splitImageBuffer(buffer, sliceHeight = 1800) {
  const image = await Jimp.read(buffer);
  const { width, height } = image.bitmap;
  const safeSliceHeight = clamp(Math.floor(Number(sliceHeight) || 1800), 200, 4000);

  const slices = [];
  for (let top = 0; top < height; top += safeSliceHeight) {
    const cropHeight = Math.min(safeSliceHeight, height - top);
    const cropped = image.clone().crop(0, top, width, cropHeight);
    const sliceBuffer = await cropped.getBufferAsync(Jimp.MIME_PNG);
    slices.push({
      buffer: sliceBuffer,
      width,
      height: cropHeight,
      top,
      mimeType: Jimp.MIME_PNG,
    });
  }

  return { width, height, slices };
}

module.exports = {
  DEFAULT_ALLOWED_IMAGE_HOSTS,
  MAX_IMAGE_BYTES,
  isAllowedImageUrl,
  downloadBuffer,
  publicStorageUrl,
  savePublicBuffer,
  splitImageBuffer,
};
