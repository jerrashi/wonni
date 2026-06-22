# Mercari Photo Sync Debug Analysis
**Branch:** `feature/debug-mercari-photo-sync`  
**Date:** 2026-06-22  
**Issue:** Manually imported Mercari sales show generic tag icon instead of actual listing photos

---

## Investigation Summary

I've traced the complete photo extraction pipeline for manually imported Mercari sales (via both `MercariSalesImportSheet` bulk import and `AddSaleSheet` single-URL import) and added comprehensive debugging at every stage.

---

## Photo Sync Pipeline Overview

### Flow 1: Bulk Import from Mercari Profile
```
MercariSalesImportSheet
  ↓ (user scans Mercari sold items page)
MercariSalesPageImporter.scanCurrentPage()
  ↓ JavaScript extracts items from page
  ├─ __NEXT_DATA__ phase: checks item.thumbnailUrl, item.image, item.imageUrl
  └─ DOM fallback phase: queries for img.src, img.data-src, Mercari CDN URLs
  ↓ (JavaScript returns JSON array)
  ↓ [NEW] Swift parsing logs extracted thumbnailUrl
  ↓ User selects items and taps "Import"
MercariSalesImportSheet.importSelected()
  ↓ [NEW] Logs thumbnailUrl before Sale creation
  ↓ Creates Sale(thumbnailUrl: item.thumbnailUrl)
SaleRepository.addSale()
  ↓ [NEW] Logs thumbnailUrl before Firestore write
  ↓ Firestore encodes Sale struct as JSON
  ↓ (Sale stored with thumbnailUrl field)
  ↓ [NEW] SaleRepository.fetchSales() logs thumbnailUrl on retrieval
  ↓
SaleRow displays image
```

### Flow 2: Single URL Import
```
AddSaleSheet (user pastes item URL)
  ↓ Taps "Fetch"
AddSaleSheet.fetchFromURL()
  ↓ Extracts Mercari item ID from URL
  ↓ Calls MercariItemLoader.load(itemId:)
    ↓ Loads Mercari item page in hidden WKWebView
    ↓ JavaScript extracts: price, name, status, photo (thumbnail)
    ↓ Parses JSON output → sets loader.thumbnailUrl
  ↓ User taps "Save"
AddSaleSheet.save()
  ↓ Creates Sale(thumbnailUrl: loader.thumbnailUrl)
  ↓ SaleRepository.addSale() [with logging]
  ↓
SaleRow displays image
```

---

## Debugging Additions (3 Commits)

### Commit 1: Comprehensive Logging Pipeline
**Files Modified:**
- `Views/SalesDashboardView.swift`: Enhanced MercariSalesPageImporter.scanCurrentPage()
- `Data/SaleRepository.swift`: Added debug logging to fetchSales()

**Changes:**
- Log extracted `thumbnailUrl` values during JavaScript parsing
- Log each MercariFoundSaleItem's thumbnailUrl after Swift struct creation
- Log all Mercari sales on retrieval from Firestore (coverPhotoPath, thumbnailUrl)

**Debug Output Points:**
```
[MercariSalesPageImporter] Raw JSON from JS: [...]
[MercariSalesPageImporter] Parsed item ID: m123456
[MercariSalesPageImporter]   thumbnailUrl: https://...
[SaleRepository.fetchSales] Mercari sale ID: xxx
[SaleRepository.fetchSales]   thumbnailUrl: https://... (or "nil")
```

### Commit 2: Image Extraction Robustness + Save-Stage Logging
**Files Modified:**
- `Views/SalesDashboardView.swift`: Improved DOM image selector fallbacks
- `Data/SaleRepository.swift`: Added logging to addSale() before Firestore write

**Changes:**
- Added fallback to search for Mercari CDN URLs (mercdn.net, mercari-images) in all img elements within listing cards
- Improved __NEXT_DATA__ extraction to handle photos array and multiple field names (thumbnailUrl, image, imageUrl, thumbnail, photo)
- Added logging at the moment Sale is written to Firestore (verifies data passes through import pipeline correctly)

**Debug Output Point:**
```
[SaleRepository.addSale] Saving sale with:
[SaleRepository.addSale]   platform: mercari
[SaleRepository.addSale]   thumbnailUrl: https://... (or "nil")
[SaleRepository.addSale] Sale saved successfully
```

### Commit 3: JavaScript Console Logging
**Files Modified:**
- `Views/SalesDashboardView.swift`: Added console.log in DOM extraction phase

**Changes:**
- Logs what's actually extracted for each item during DOM phase
- Helps identify if images are found but malformed, filtered out, or missing

**Debug Output Point (Safari Web Inspector):**
```
[MercariSalesPageImporter] Extracted item: {"id":"m123456","name":"...","price":25.00,"thumbnailUrl":"https://..."}
```

---

## Root Cause Hypotheses

Based on code analysis, the most likely issues are:

### Hypothesis 1: Image URLs Are Nil (60% likely)
**Symptom:** Thumbnail URLs are extracted as null/empty strings
**Causes:**
- Mercari's DOM structure changed; image elements aren't found by current selectors
- Images are lazy-loaded with placeholder data URIs (filtered out by code)
- __NEXT_DATA__ doesn't include thumbnail URLs for sold items

**Evidence for:**
- Recent DOM changes at Mercari happen frequently
- Sold items pages might use different DOM containers than active listings

**Evidence against:**
- MercariItemLoader (AddSaleSheet) has proven extraction with og:image fallback
- Code already checks multiple field names and selectors

### Hypothesis 2: URLs Are Valid But Don't Render (25% likely)
**Symptom:** thumbnailUrl field stores correctly, but AsyncImage fails to load
**Causes:**
- Mercari URLs require authentication/referrer headers
- URLs are CDN redirects that return 403
- CORS or SSL pinning issues with Mercari CDN

**Evidence for:**
- Mercari aggressively protects image CDNs
- Some image URLs might be session-dependent

**Evidence against:**
- MercariItemLoader urls successfully load in MercariSheetWebView
- AsyncImage would show placeholder, not tag icon

### Hypothesis 3: Firestore Encoding Issue (10% likely)
**Symptom:** Data is extracted and created correctly but doesn't persist
**Causes:**
- Optional String fields not encoded properly by Firestore
- Security rules blocking thumbnailUrl field writes

**Evidence for:**
- Sale struct is `Codable` with automatic Firestore encoding

**Evidence against:**
- Very unlikely; optional fields work in other structs
- Sale.coverPhotoPath (also optional String) works fine

### Hypothesis 4: Feature Incomplete (5% likely)
**Symptom:** Commit 6d7e8b4 claims to fix this but it doesn't work
**Causes:**
- Fix was partial; only handles one code path
- Code was added but never tested with real Mercari data

**Evidence for:**
- Bulk import path (MercariSalesImportSheet) was the focus
- Single-URL import might not have been tested

**Evidence against:**
- Code looks complete and correct in both paths

---

## How to Debug Further

### Step 1: Verify Image Extraction Works
1. Enable Safari Web Inspector for WKWebView
2. Navigate to Mercari sold items page
3. Open Xcode console and look for:
   ```
   [MercariSalesPageImporter] Raw JSON from JS: [...]
   [MercariSalesPageImporter] Extracted item: {...thumbnailUrl: "..."}
   ```
4. Check browser console for:
   ```
   [MercariSalesPageImporter] Extracted item: {"id":"...","thumbnailUrl":"https://..."}
   ```

### Step 2: Verify Data Flows Through Save
1. Import a Mercari sale (either via bulk import or URL)
2. Check Xcode console for:
   ```
   [MercariImport] Item thumbnailUrl: https://...
   [SaleRepository.addSale] thumbnailUrl: https://...
   [SaleRepository.addSale] Sale saved successfully
   ```
3. If thumbnailUrl is nil here, the extraction failed

### Step 3: Verify Firestore Retrieval
1. After import completes, check Xcode console when viewing sales:
   ```
   [SaleRepository.fetchSales] Mercari sale ID: xxx
   [SaleRepository.fetchSales]   thumbnailUrl: https://... (or "nil")
   ```
2. If nil here, the Firestore write didn't persist it

### Step 4: Verify URL Works
1. If thumbnailUrl IS being retrieved, but image doesn't show:
2. Copy the URL and paste into Safari
3. Check if it loads or returns error/redirect

---

## SaleRow Display Logic

When a sale is displayed in the SalesDashboardView:

```swift
struct SaleRow: View {
    var body: some View {
        HStack {
            Group {
                if let path = sale.coverPhotoPath {
                    // Firebase Storage image (from Wonni listings)
                    AsyncFirebaseImage(path: path)
                } else if let urlStr = sale.thumbnailUrl, let url = URL(string: urlStr) {
                    // External CDN URL (from Mercari manual import)
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            RoundedRectangle(...).fill(Color(.systemGray5)) // Gray placeholder
                        }
                    }
                } else {
                    // Fallback: Gray box with tag icon ← WHAT YOU SEE WHEN thumbnailUrl IS NIL
                    RoundedRectangle(...).fill(Color(.systemGray5))
                        .overlay(Image(systemName: "tag").foregroundStyle(.secondary))
                }
            }
        }
    }
}
```

The tag icon appears when **both** `coverPhotoPath` and `thumbnailUrl` are nil/invalid.

---

## Recommended Fixes

### If Extraction Is Failing (Hypothesis 1):
1. **Widen DOM selectors** - Add more fallback image selectors for different Mercari DOM structures
2. **Force image load** - Use `img.currentSrc` instead of just `img.src` for potential lazy-load issues
3. **Use Mercari API** - If they have a public API (check recent terms)

### If URLs Don't Render (Hypothesis 2):
1. **Download and cache images** - Instead of direct CDN URLs, download to Firebase Storage during import
2. **Use og:image fallback** - More reliable than direct img extraction
3. **Validate URLs** - Test URL accessibility before saving

### If Firestore Isn't Persisting:
1. **Add Firestore rules logging** - Check if security rules are blocking the write
2. **Force explicit encoding** - Add custom Codable implementation if needed
3. **Verify schema** - Check Firestore console directly to see what's stored

---

## Key Code Locations

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| Bulk Import Extraction | `SalesDashboardView.swift` | 911-962 | JavaScript extraction from Mercari sold items page |
| Bulk Import Swift Parsing | `SalesDashboardView.swift` | 954-968 | Parse JS JSON and create MercariFoundSaleItem structs |
| Bulk Import Save | `SalesDashboardView.swift` | 1120-1137 | Create Sale with thumbnailUrl and save |
| Single URL Extraction | `CrossPostWebView.swift` | 4218-4303 | MercariItemLoader JavaScript for single item |
| Single URL Save | `SalesDashboardView.swift` | 846-871 | AddSaleSheet save with loader.thumbnailUrl |
| Firestore Save | `SaleRepository.swift` | 73-88 | addSale() persists to Firestore |
| Firestore Fetch | `SaleRepository.swift` | 30-56 | fetchSales() retrieves with logging |
| Display | `SalesDashboardView.swift` | 470-520 | SaleRow displays image or fallback |

---

## Next Steps

1. **Run the app** with debugging enabled
2. **Try importing a Mercari sale** via bulk import or URL
3. **Check Xcode console** for the three logging stages:
   - JavaScript extraction → `[MercariSalesPageImporter] Raw JSON`
   - Swift parsing → `[MercariSalesPageImporter] Parsed item`
   - Firestore save → `[SaleRepository.addSale] thumbnailUrl`
   - Firestore fetch → `[SaleRepository.fetchSales] thumbnailUrl`
4. **Identify where it fails** and debug from there

The comprehensive logging now makes it easy to pinpoint exactly where the thumbnail URL is being lost.
