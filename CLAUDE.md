# CLAUDE.md

See **README.md** for full project documentation: architecture, feature status, backlog, and Firebase setup instructions.

## Quick Reference for Claude Code

**Stack:** SwiftUI + Firebase (Auth, Firestore, Storage, AI/Gemini)

**Project root:** `wonni/wonni.xcodeproj` — all source under `wonni/wonni/`

**Key conventions:**
- New `Data/` files must be registered in `wonni.xcodeproj/project.pbxproj` (4 places: PBXBuildFile, PBXFileReference, Data group, PBXSourcesBuildPhase)
- New `Views/` files already in the project do not need pbxproj edits; new view files do
- Firebase Storage paths: `users/{userId}/{listingId}/{index}.jpg` — permanent from upload, no temp paths
- Listings pre-generate their Firestore ID client-side (UUID) so Storage path is known before the Firestore write
- Avoid composite Firestore indexes where possible — use single-field queries + client-side sort; add to `firestore.indexes.json` when a compound query is unavoidable
- SourceKit errors ("No such module 'FirebaseAI'", etc.) after edits are stale index noise — not real build errors
- Deploy rules/indexes: `cd wonni && firebase deploy --only firestore:rules,firestore:indexes,storage`
