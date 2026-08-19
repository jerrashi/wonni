# Firestore & Storage Rules — Test Cases

This document provides concrete test cases for Firebase Console Rules Playground validation.

**Location:** Firebase Console → Project (wonni-app) → Firestore → Rules → "Rules Playground" tab

---

## Setup

Before running tests, set up test data:

**Create test documents in Firestore:**

```
products/test-product-1
  userId: "user-alice"
  title: "Test Product"

listings/test-listing-1
  userId: "user-alice"
  title: "Test Listing"

orders/test-order-1
  userId: "user-alice"
  orderId: "order-123"

users/user-alice
  email: "alice@test.com"

users/user-alice/integrations/ebay
  isConnected: true
  accessToken: "test-token"
```

**Test Users:**
- User A: `user-alice` (uid)
- User B: `user-bob` (uid)

---

## Firestore Rules Test Cases

### Test Group 1: Read/Write Isolation

| # | Test Case | Auth User | Path | Operation | Expected | Status |
|---|-----------|-----------|------|-----------|----------|--------|
| 1.1 | User reads own product | user-alice | products/test-product-1 | read | ✓ Allow | [ ] |
| 1.2 | User reads other's product | user-bob | products/test-product-1 | read | ✗ Deny | [ ] |
| 1.3 | User writes own product | user-alice | products/test-product-1 | write | ✓ Allow | [ ] |
| 1.4 | User writes other's product | user-bob | products/test-product-1 | write | ✗ Deny | [ ] |
| 1.5 | Unauthenticated reads product | (none) | products/test-product-1 | read | ✗ Deny | [ ] |

### Test Group 2: Create Constraints (products)

| # | Test Case | Auth User | Path | Data | Expected | Status |
|---|-----------|-----------|------|------|----------|--------|
| 2.1 | Create with correct userId | user-alice | products/new-1 | {userId: "user-alice", title: "Test"} | ✓ Allow | [ ] |
| 2.2 | Create with wrong userId | user-alice | products/new-2 | {userId: "user-bob", title: "Test"} | ✗ Deny | [ ] |
| 2.3 | Create without userId | user-alice | products/new-3 | {title: "Test"} | ✗ Deny (missing field) | [ ] |
| 2.4 | Unauthenticated create | (none) | products/new-4 | {userId: "user-alice", title: "Test"} | ✗ Deny | [ ] |

### Test Group 3: Create Constraints (listings)

| # | Test Case | Auth User | Path | Data | Expected | Status |
|---|-----------|-----------|------|------|----------|--------|
| 3.1 | Create with correct userId | user-alice | listings/new-1 | {userId: "user-alice", title: "Test Listing"} | ✓ Allow | [ ] |
| 3.2 | Create with wrong userId | user-alice | listings/new-2 | {userId: "user-bob", title: "Test Listing"} | ✗ Deny | [ ] |
| 3.3 | Read own listing | user-alice | listings/test-listing-1 | read | ✓ Allow | [ ] |
| 3.4 | Read other's listing | user-bob | listings/test-listing-1 | read | ✗ Deny | [ ] |

### Test Group 4: Orders (Dual-Write)

| # | Test Case | Auth User | Path | Data | Expected | Status |
|---|-----------|-----------|------|------|----------|--------|
| 4.1 | User reads own order | user-alice | orders/test-order-1 | read | ✓ Allow | [ ] |
| 4.2 | User reads other's order | user-bob | orders/test-order-1 | read | ✗ Deny | [ ] |
| 4.3 | Create order with correct userId | user-alice | orders/new-1 | {userId: "user-alice", orderId: "new-123"} | ✓ Allow | [ ] |
| 4.4 | Create order with wrong userId | user-alice | orders/new-2 | {userId: "user-bob", orderId: "new-456"} | ✗ Deny | [ ] |

### Test Group 5: User Profile & Integrations

| # | Test Case | Auth User | Path | Operation | Expected | Status |
|---|-----------|-----------|------|-----------|----------|--------|
| 5.1 | User reads own profile | user-alice | users/user-alice | read | ✓ Allow | [ ] |
| 5.2 | User reads other's profile | user-bob | users/user-alice | read | ✗ Deny | [ ] |
| 5.3 | User reads own integration | user-alice | users/user-alice/integrations/ebay | read | ✓ Allow | [ ] |
| 5.4 | User reads other's integration | user-bob | users/user-alice/integrations/ebay | read | ✗ Deny | [ ] |
| 5.5 | User writes own integration | user-alice | users/user-alice/integrations/tiktok | write | ✓ Allow | [ ] |
| 5.6 | User writes other's integration | user-bob | users/user-alice/integrations/tiktok | write | ✗ Deny | [ ] |

---

## Cloud Storage Rules Test Cases

**Location:** Firebase Console → Project (wonni-app) → Storage → Rules → "Rules Playground" tab

### Setup

Create test files in Storage:

```
gs://bucket/dropship/user-alice/product-1.jpg (exists, readable, writable by alice)
gs://bucket/dropship/user-bob/product-2.jpg (exists, readable, writable by bob)
```

### Test Group 6: Storage Read Access

| # | Test Case | Auth User | Path | Operation | Expected | Status |
|---|-----------|-----------|------|-----------|----------|--------|
| 6.1 | Read own product image | user-alice | dropship/user-alice/product-1.jpg | read | ✓ Allow | [ ] |
| 6.2 | Read other's product image | user-bob | dropship/user-alice/product-1.jpg | read | ✓ Allow | [ ] |
| 6.3 | Unauthenticated read | (none) | dropship/user-alice/product-1.jpg | read | ✗ Deny | [ ] |
| 6.4 | Read outside dropship folder | user-alice | other/image.jpg | read | ✗ Deny | [ ] |

### Test Group 7: Storage Write Access

| # | Test Case | Auth User | Path | Operation | Expected | Status |
|---|-----------|-----------|------|-----------|----------|--------|
| 7.1 | Upload to own folder | user-alice | dropship/user-alice/new-image.jpg | write | ✓ Allow | [ ] |
| 7.2 | Upload to other's folder | user-alice | dropship/user-bob/image.jpg | write | ✗ Deny | [ ] |
| 7.3 | Delete own file | user-alice | dropship/user-alice/product-1.jpg | delete | ✓ Allow | [ ] |
| 7.4 | Delete other's file | user-alice | dropship/user-bob/product-2.jpg | delete | ✗ Deny | [ ] |
| 7.5 | Unauthenticated write | (none) | dropship/user-alice/image.jpg | write | ✗ Deny | [ ] |
| 7.6 | Write outside dropship | user-alice | other/image.jpg | write | ✗ Deny | [ ] |

---

## Rules Playground: Step-by-Step Instructions

### For Each Test Case:

1. **In Rules Playground:**
   - Set "Authenticate as:" to test user (or leave blank for unauthenticated)
   - Set "Document path:" to the path (e.g., `products/test-product-1`)
   - Set "Request method:" to operation (read, write, delete)
   - Click "Run"

2. **Verify Result:**
   - Green checkmark (✓) = Rule allowed
   - Red X (✗) = Rule denied
   - Check against "Expected" column

3. **Document Result:**
   - Mark [ ] with [✓] if result matches expected
   - Mark [ ] with [✗] if result does NOT match expected
   - **Stop and investigate if any test fails**

### Example: Test Case 1.1 (User reads own product)

```
Rules Playground Setup:
  Authenticate as: user-alice
  Document path: products/test-product-1
  Request method: get (read)
  
Expected: ✓ Allow (green checkmark)
```

---

## Troubleshooting

### If a test fails (result ≠ expected):

1. **Review the rules** in the Rules editor
2. **Check test data** — does the doc have the correct `userId` field?
3. **Verify auth user** — is the test using the correct uid?
4. **Read error message** — Rules Playground shows why a read/write was denied

### Common Issues:

**"Permission denied" when expected "Allow"**
- [ ] Check `userId` field matches in document data
- [ ] Verify `request.auth.uid` is set correctly
- [ ] Ensure rule path pattern matches (e.g., `/products/{productId}`)

**"Allow" when expected "Deny"**
- [ ] Rule may be too permissive (check for `if true` or missing uid check)
- [ ] Check that `request.auth.uid` is actually being checked
- [ ] Verify rule path pattern is correct

---

## Passing Criteria

✅ **All tests pass:** Rules are correct, safe to deploy

❌ **Any test fails:** Do NOT deploy — fix rules first

---

## Post-Test Actions

### If All Tests Pass:

1. Note passing date: ________________
2. Run: `firebase deploy --only firestore:rules,storage --project wonni-app`
3. Monitor production logs for permission errors (first 24 hours)
4. Update CLAUDE.md with validation completion

### If Any Tests Fail:

1. Document which tests failed (copy failed rows)
2. Review rules in wonni-app repo
3. Propose fixes
4. Re-test after fixes
5. Do NOT deploy until all tests pass

---

**Validation Date:** __________________  
**Validated By:** __________________  
**All Tests Passed:** [ ] Yes [ ] No  
**Rules Deployed:** [ ] Yes [ ] No (if yes, date: __________________)
