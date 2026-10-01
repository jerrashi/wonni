//
//  DraftPhotoStore.swift
//  wonni
//
//  On-disk home for the photo bytes a draft keeps locally (camera shots, photos pulled
//  down from another device): one file per photo, one folder per draft.
//
//  2026-09-30: replaces `Item.photosData: [Data]`. Despite `.externalStorage`, SwiftData
//  stored that array as ONE blob inline in the draft's SQLite row, so every save of a
//  camera draft — a new shot, a reorder, even a title edit — rewrote every photo in it
//  on the main thread. Measured on the simulator with 3 MB photos: adding the 12th photo
//  took 565 ms, a title-only save 70-80 ms (vs 1.3 ms for a draft with no local photos).
//  A file write is 3-8 ms and the row stays small.
//
//  `Item.localPhotoFilesByAsset` maps assetId -> file name in here; `Item` owns all
//  bookkeeping. Plain file operations, safe from any thread.
//

import Foundation

enum DraftPhotoStore {
    /// Tests point this at a temp directory so they never touch real drafts.
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        // Application Support, next to the SwiftData store these bytes used to live in —
        // same backup and purge behavior as before.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DraftPhotos", isDirectory: true)
    }

    static func directory(for itemID: UUID) -> URL {
        root.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    static func url(itemID: UUID, fileName: String) -> URL {
        directory(for: itemID).appendingPathComponent(fileName)
    }

    /// Writes one photo and returns its file name (unique per write, so a photo's bytes
    /// are never overwritten in place).
    static func write(_ data: Data, itemID: UUID) throws -> String {
        let directory = directory(for: itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + ".photo"
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    static func read(itemID: UUID, fileName: String) -> Data? {
        try? Data(contentsOf: url(itemID: itemID, fileName: fileName), options: .mappedIfSafe)
    }

    static func delete(itemID: UUID, fileName: String) {
        try? FileManager.default.removeItem(at: url(itemID: itemID, fileName: fileName))
    }

    /// Removes every photo a draft stored. Call wherever a draft is deleted.
    static func deleteAll(itemID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: itemID))
    }

    /// Deletes folders belonging to drafts that no longer exist — the backstop for any
    /// delete path that missed `deleteAll`. Returns how many were removed.
    @discardableResult
    static func sweepOrphans(keeping liveItemIDs: Set<UUID>) -> Int {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for folder in folders {
            // Anything not named like a draft isn't ours to judge — leave it.
            guard let itemID = UUID(uuidString: folder.lastPathComponent),
                  !liveItemIDs.contains(itemID) else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed += 1 }
        }
        return removed
    }
}

/// How bytes left in the old `Item.photosData` array map back onto a draft's photos.
/// Pure, so it's unit-testable (LegacyDraftPhotosTests).
enum LegacyDraftPhotos {
    /// Blob index for each assetId that can be attributed with confidence; photos
    /// missing from the result have no recoverable local bytes.
    ///
    /// The old array was positional but only camera shots were ever appended to it, so
    /// it lines up with `assetIds` only when every photo is a camera shot. When counts
    /// differ (a draft mixing library picks and camera shots), the one case still
    /// attributable is "save to camera roll" off: those shots carry `local_temp_` ids
    /// and were appended in order. Otherwise nothing is attributed — every photo there
    /// has a real library id, so PhotoKit serves it (the old positional read returned
    /// the wrong photo's bytes for these).
    static func blobIndexByAsset(assetIds: [String], blobCount: Int) -> [String: Int] {
        guard blobCount > 0 else { return [:] }
        let attributable: [String]
        if assetIds.count == blobCount {
            attributable = assetIds
        } else {
            let localOnly = assetIds.filter { $0.hasPrefix("local_temp_") }
            guard localOnly.count == blobCount else { return [:] }
            attributable = localOnly
        }
        return Dictionary(attributable.enumerated().map { ($0.element, $0.offset) },
                          uniquingKeysWith: { first, _ in first })
    }
}
