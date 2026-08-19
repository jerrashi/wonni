# Firestore Rules Validation Guide

## Overview

This document covers validation of Firestore and Cloud Storage security rules for the Phase B backend merge (wonni_dropship + wonni-app unified backend on `wonni-app` Firebase project).

**Status:** Pre-production validation needed before cutover.

---

## Current State (wonni_dropship repo)

### Firestore Rules

**Dropship repo rules (`firestore.rules`):**

```
/products/{productId}
  - read/write: owner only (userId match)
  - create: owner must set userId

/orders/{orderId}
  - read/write: owner only (userId match)
  - create: owner must set userId

/users/{uid}
  - read/write: user self only (uid match)
  - /integrations/{platform}
    - read/write: user self only
```

**Security model:** Pure user isolation. Each user can only read/write their own docs.

### Cloud Storage Rules

**Dropship repo rules (`storage.rules`):**

```
/dropship/{userId}/**
  - read: all signed-in users (product images are public)
  - write: owner only (userId match)

/* (everything else)
  - read/write: denied
```

**Security model:** Public read (any user can see product photos), private write.

---

## Phase B Merged Schema (wonni-app backend)

Per `CLAUDE.md`, the merged wonni-app backend now includes:

### New Collections

1. **`listings/{listingId}`** (wonni-app's UserListing schema)
   - Owned by a user
   - Linked to source product (AliExpress/Weverse) and per-platform listings (eBay/TikTok/Mercari/Etsy)
   - Cross-posting metadata: `crossPostStatus`, `crossPostListingIds`
   - Per-variant: `ListingVariation.crossPostStatus`, `ListingVariation.crossPostListingIds` (Mercari one-listing-per-variant model)

2. **`orders/{orderId}`** (shared between dropship and iOS)
   - Dual-write now: both apps create orders in same collection
   - `userId` field ties order to user
   - Schema merging happened: iOS `Order` shape + dropship `Order` shape unified
   - May have platform-specific fields (eBay order ID, Mercari order ID, Etsy order ID)

### Modified Collections

1. **`products/{productId}`** (kept for ProductDetail.jsx backward compat)
   - Still canonical for dropship's UI
   - Dual-written alongside new `listings` doc
   - Will be migrated off eventually (deferred Phase 2 work)

2. **Cloud Storage `/dropship/{userId}/**`**
   - Unchanged permission model (public read, private write)
   - Now also stores listing images from both sources

### Unchanged Collections

1. **`users/{uid}`** and **`users/{uid}/integrations/{platform}`**
   - User self isolation unchanged
   - integrations now include both dropship (eBay, AliExpress, TikTok) and wonni-app (Apple ID, etc.)

---

## What Needs Validation

### 1. Firestore Rules (`wonni-app` project)

#### Collections to Verify

**`listings/{listingId}`**
- ✓ Read/write scoped to owner (`request.auth.uid == resource.data.userId`)
- ✓ Create enforces ownership (`request.auth.uid == request.resource.data.userId`)
- ✓ Per-variant cross-posting metadata readable by owner
- ✓ Platform-specific listing IDs readable by owner only

**`orders/{orderId}` (merged)**
- ✓ Read/write scoped to owner (`request.auth.uid == resource.data.userId`)
- ✓ Create enforces ownership
- ✓ Both dropship and iOS write the same collection without conflicts
- ✓ Platform-specific order IDs (eBay, Mercari, Etsy) readable by owner only

**`products/{productId}` (backward compat, still present)**
- ✓ Read/write scoped to owner
- ✓ Dual-write alongside `listings` doesn't create permission gaps

**`users/{uid}` and `/integrations/{platform}` (unchanged)**
- ✓ User self isolation maintained
- ✓ Platform integrations (both dropship and iOS) in same collection

#### Security Checks

1. **User Isolation:**
   - [ ] A user cannot read/write another user's `products`, `listings`, or `orders`
   - [ ] A user cannot read/write another user's `/users/{uid}/integrations`
   
2. **Create Constraints:**
   - [ ] Creating a product/listing/order requires `userId` field set to current user
   - [ ] Cannot create a doc with `userId: "other-user"`
   
3. **Update Safety:**
   - [ ] `userId` field cannot be changed after creation (prevent ownership spoofing)
   - [ ] Platform-specific listing IDs update by owner only
   
4. **Public Read Scenarios:**
   - [ ] Listings/products are NOT publicly readable (unlike storage images)
   - [ ] Only owner can list their products/listings

#### Backward Compatibility Check

- [ ] Both dropship (`products`) and wonni-app (`listings`) dual-write without permission errors
- [ ] iOS can read/write `listings` using same ownership rules
- [ ] Cloud Functions (admin SDK) bypass rules — internal only, not checked by these rules

### 2. Cloud Storage Rules (`wonni-app` project)

#### Paths to Verify

**`/dropship/{userId}/**` (dropship product images)**
- ✓ Public read (any signed-in user)
- ✓ Owner write only

**Possible iOS path patterns** (may exist in wonni-app storage):
- `/wonni/{userId}/**` — iOS product images (if any)
- `/shared/{userId}/**` — Shared resources (if any)

#### Security Checks

1. **Read Access:**
   - [ ] Any signed-in user can read `/dropship/{userId}/**` (product images)
   - [ ] Unauthenticated users cannot read
   
2. **Write Access:**
   - [ ] Only owner can upload to their `/dropship/{uid}/**` folder
   - [ ] User cannot write to another user's folder
   - [ ] Cannot create files outside of `/dropship/{uid}/` (default deny)
   
3. **File Metadata:**
   - [ ] Rules don't restrict file size, extension, or MIME type (Cloud Functions handle validation)
   - [ ] Deletion (write permission) owner-only

---

## Validation Methods

### Option 1: Firebase Console Rules Playground (Recommended)

**Steps:**
1. Go to [Firebase Console](https://console.firebase.google.com) → `wonni-app` project
2. Firestore → Rules → "Rules Playground" tab
3. Simulate reads/writes:
   - **User A reading their own product** → Should allow ✓
   - **User A reading User B's product** → Should deny ✗
   - **User A creating product with userId: "User A"** → Should allow ✓
   - **User A creating product with userId: "User B"** → Should deny ✗
4. Storage → Rules → "Rules Playground" tab
5. Simulate storage access:
   - **User A reading `/dropship/User-A/image.jpg`** → Should allow ✓
   - **Unauthenticated reading `/dropship/User-A/image.jpg`** → Should deny ✗
   - **User A writing `/dropship/User-A/image.jpg`** → Should allow ✓
   - **User A writing `/dropship/User-B/image.jpg`** → Should deny ✗

### Option 2: Test Deploy (Alternative)

**Requirements:** Firebase CLI logged in, `wonni-app` project selected

**Command:**
```bash
firebase deploy --only firestore:rules,storage --project wonni-app
```

**Risks:**
- Deploys to production — ensure valid rules before running
- No rollback on failure (manual revert needed)
- **Recommendation:** Use Console's Rules Playground first, then deploy once validated

### Option 3: Local Rules Emulator (Not Available)

Java required — blocked on this machine (no Java installed).

---

## Validation Checklist

### Pre-Validation

- [ ] Rules changes from Phase B merge are documented (compare old vs. new in wonni-app repo)
- [ ] No breaking changes to existing collections (backward compat verified)
- [ ] New `listings` collection schema aligns with iOS `UserListing` model

### Firestore Rules Tests

- [ ] **User isolation:** User A cannot read User B's `products`, `listings`, `orders`
- [ ] **Create constraints:** Creating doc requires correct `userId` field
- [ ] **Ownership verification:** `userId` field matches `request.auth.uid`
- [ ] **Dual-write compat:** Both `/products` and `/listings` follow same ownership rules
- [ ] **Integration access:** User can read/write own `/users/{uid}/integrations`

### Cloud Storage Rules Tests

- [ ] **Public read:** Any auth'd user can read images under `/dropship/{userId}/**`
- [ ] **Authenticated required:** Unauth'd users denied
- [ ] **Owner write only:** User can only write to their own `/dropship/{uid}/**` folder
- [ ] **Cross-user write blocked:** User A cannot write to `/dropship/User-B/**`
- [ ] **Default deny:** All other paths deny read/write

### Post-Validation

- [ ] Rules validated in Firebase Console Rules Playground
- [ ] No permission errors in production logs post-deploy
- [ ] Data migration (if any) respects new rules
- [ ] iOS app can read/write `listings` and `orders` with same rules

---

## Known Constraints

1. **No Local Emulator:** No Java on this machine — cannot test locally
2. **Cloud Functions bypass rules:** Admin SDK used by Cloud Functions is unrestricted
3. **Rules don't validate data shape:** Only check auth/ownership — Cloud Functions validate field presence, types, etc.
4. **Eventual consistency:** Rules applied immediately to new writes; existing data not re-validated on rule changes

---

## Reference: Dropship → wonni-app Rules Migration

### What Stayed the Same
- User self-isolation model (`userId` field scoping)
- Storage public-read, private-write for product images
- `/users/{uid}/integrations` per-platform integration storage

### What Changed
- New `listings` collection with same ownership rules as `products`
- `orders` collection dual-written by both dropship and iOS apps
- Storage may now include iOS images under a different path pattern

### Why Rules Are the Same
- Both dropship and wonni-app use user-based ownership (no shared/admin collections)
- No change to the fundamental security model
- Rules need no modification for dual-write pattern (same ownership checks apply)

---

## Next Steps

1. **Validate** using Firebase Console Rules Playground (Option 1)
2. **Deploy** once validation complete: `firebase deploy --only firestore:rules,storage --project wonni-app`
3. **Monitor** production logs for permission errors post-deploy
4. **Document** any issues found and deployment date in CLAUDE.md

---

## Contacts & Escalation

- **Firebase Project:** `wonni-app` (not wonni_dropship)
- **Repo with merged rules:** `~/Documents/GitHub/wonni` (wonni-app repo)
- **Phase B merge plan:** `~/.claude/plans/wise-sniffing-salamander.md`

---

**Last Updated:** 2026-08-19
**Status:** Pre-production validation needed before data migration
