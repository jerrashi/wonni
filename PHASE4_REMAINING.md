# Phase 4 UI Redesign — Remaining Deferred Work

## Status Summary (2026-08-19)

**Completed in this session:**
- ✅ Collapsible sidebar with localStorage persistence
- ✅ Autosave for text fields (removed Save button)
- ✅ Header reorganization with OverflowMenu
- ✅ Mercari URL fields (single products + variants)
- ✅ Apply Mercari Edits modal with full blocker integration

**Completed:**

### ✅ Post Button as Anchored Popover (2026-08-19)

**Implementation (commit b62000d):**
- Added `mode` prop to PostModal ("modal" | "popover")
- PostModal tracks button position with `getBoundingClientRect()`
- When `mode="popover"`: renders as fixed-position element below button
- Lightweight transparent backdrop for click-outside close
- ProductDetail passes `mode="popover"` and `postButtonRef` to PostModal
- No impact on posting logic — pure presentation refactor

**Status:** Live on main. Post button now anchors popover below itself for better context and space efficiency.

---

### 2. Firestore Rules Validation

**Current state:** 
- Dropship repo rules in `firestore.rules` and `storage.rules` are sound
- Real backend is wonni-app (Phase B merge completed)
- wonni-app rules have been updated with dropship collections but not locally validated

**What needs validation:**
- No Java/emulator available on this machine
- Need to validate merged rules in wonni-app repo via:
  1. Firebase Console's Rules Playground
  2. Or test deploy: `firebase deploy --only firestore:rules,storage --project wonni-app`

**Firestore rules review (dropship repo, pre-merge state):**
```
✓ products: read/write by owner (userId field)
✓ orders: read/write by owner (userId field)  
✓ users/{uid}: read/write by owner
✓ users/{uid}/integrations: read/write by owner
```

**Storage rules review (dropship repo):**
```
✓ dropship/{userId}/*: read by all, write by owner
✓ everything else: deny all
```
Rules are correctly scoped.

**Why deferred:** 
- Requires manual action in Firebase Console (not scriptable from CLI without emulator)
- Blocked by lack of Java for local emulator
- Won't block deployment since Phase B merge was already vetted before this session
- Can be validated any time before production cutover

**Validation checklist:**
- [ ] Review merged wonni-app firestore.rules for `dropship` collections
- [ ] Review merged wonni-app storage.rules for `dropship/{userId}` paths
- [ ] Test with Firebase Console Rules Playground
- [ ] Or run test deploy to sandbox first

---

## Notes

- Rules validation is lower urgency since Phase B merge was completed separately
- Firestore/Storage rule changes have already been made in wonni-app repo but not locally emulator-tested
- Can be validated anytime before production cutover
- No impact on current development or testing

**Final Status:** Phase 4 UI redesign **COMPLETE**. Only remaining task is rules validation (optional before prod cutover).
