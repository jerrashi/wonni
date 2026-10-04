//
//  CrossPostRunStore.swift
//  wonni
//
//  A cross-post run that survives the app being closed.
//
//  Posting 40 listings to Mercari takes a long time, and the queue that drives it
//  (UploadManager.webAutofillQueue + the deferred eBay/Etsy triggers) lives in
//  memory. Leave the app mid-run and iOS suspends, then kills, the process: the
//  queue is gone, nothing recorded how far it got, and the user finds out days
//  later that 23 listings never went up (reported 2026-10-03).
//
//  This file is the durable half: every job of a run is written to disk when it is
//  queued and marked `ended` when its attempt finishes. On the next launch (or
//  return to the foreground with no live queue) UploadManager compares what is left
//  against Firestore's `crossPostStatus` and offers "17 of 40 posted — retry?".
//
//  Jobs are plain values (Storage photo paths, never a SwiftData object), so a
//  retry needs nothing that died with the old process. The summary logic is pure
//  and unit-tested (CrossPostRunStoreTests).
//

import Foundation

/// One cross-post attempt, in a form that can be written to disk and replayed.
struct PersistedCrossPostJob: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// Browser autofill (Mercari, Facebook): replayed through the web queue.
        case web
        /// Server-side post (eBay, Etsy): replayed with `triggerCrossPost`.
        case api
    }

    var id: UUID
    var kind: Kind
    var platform: String
    var title: String
    var listingId: String?
    var description: String = ""
    var price: Double = 0
    var photoFirebasePaths: [String] = []
    var buyerPaysShipping = false
    var condition: String = "good"
    var suggestedCategory: String?
    var suggestedBrand: String?
    var weightLbs: Double?
    var lengthIn: Double?
    var widthIn: Double?
    var heightIn: Double?
    var variantProductId: String?
    var variantId: String?
    var facebookLocation: String?
    var suggestedFacebookCategory: String?
    /// The attempt finished (posted, failed, or closed by the user) while the app was
    /// alive. False = never started, or cut off mid-attempt.
    var ended = false
}

struct CrossPostRun: Codable, Equatable {
    /// The signed-in user the run belongs to; a run is ignored under another account.
    var userId: String
    var jobs: [PersistedCrossPostJob]

    var hasUnfinishedJobs: Bool { jobs.contains { !$0.ended } }
}

/// What to tell the user about a run that was cut off.
struct InterruptedCrossPostSummary: Equatable {
    struct PlatformLine: Equatable {
        let platform: String
        let posted: Int
        let total: Int
    }

    /// One line per platform, in the order the platforms first appear in the run.
    let lines: [PlatformLine]
    /// The jobs to replay on Retry: everything not confirmed posted.
    let remaining: [PersistedCrossPostJob]

    var message: String {
        lines.map { "\($0.posted) of \($0.total) listing\($0.total == 1 ? "" : "s") posted to \(Self.displayName($0.platform))." }
            .joined(separator: "\n")
    }

    static func displayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }

    /// `isPosted` is the source of truth (Firestore's `crossPostStatus` for that
    /// listing + platform); where it can't say (nil: no listing id, lookup failed) the
    /// job's own `ended` flag stands in. Returns nil when nothing is left to do.
    static func make(run: CrossPostRun, isPosted: (PersistedCrossPostJob) -> Bool?) -> InterruptedCrossPostSummary? {
        var order: [String] = []
        var posted: [String: Int] = [:]
        var total: [String: Int] = [:]
        var remaining: [PersistedCrossPostJob] = []
        for job in run.jobs {
            if total[job.platform] == nil { order.append(job.platform) }
            total[job.platform, default: 0] += 1
            if isPosted(job) ?? job.ended {
                posted[job.platform, default: 0] += 1
            } else {
                remaining.append(job)
            }
        }
        guard !remaining.isEmpty else { return nil }
        // Only platforms that still have something left are worth a line.
        let unfinished = Set(remaining.map(\.platform))
        let lines = order.filter(unfinished.contains).map {
            PlatformLine(platform: $0, posted: posted[$0] ?? 0, total: total[$0] ?? 0)
        }
        return InterruptedCrossPostSummary(lines: lines, remaining: remaining)
    }
}

/// Disk persistence for the current run. One run at a time: new jobs queued while a
/// run is still unfinished join it.
enum CrossPostRunStore {
    private static let key = "crossPostRun.v1"

    static func load(defaults: UserDefaults = .standard) -> CrossPostRun? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CrossPostRun.self, from: data)
    }

    static func save(_ run: CrossPostRun, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Adds jobs to the user's run (starting one if there is none, or if the stored
    /// run belongs to someone else or has nothing left in it).
    static func add(_ jobs: [PersistedCrossPostJob], userId: String, defaults: UserDefaults = .standard) {
        guard !jobs.isEmpty else { return }
        var run = load(defaults: defaults)
        if run?.userId != userId || run?.hasUnfinishedJobs != true {
            run = CrossPostRun(userId: userId, jobs: [])
        }
        run?.jobs.append(contentsOf: jobs)
        if let run { save(run, defaults: defaults) }
    }

    /// Marks jobs ended; clears the run once every job in it has ended (a run that
    /// finished normally leaves nothing behind). Returns the run as it now stands.
    @discardableResult
    static func markEnded(where matches: (PersistedCrossPostJob) -> Bool, defaults: UserDefaults = .standard) -> CrossPostRun? {
        guard var run = load(defaults: defaults) else { return nil }
        var changed = false
        for index in run.jobs.indices where !run.jobs[index].ended && matches(run.jobs[index]) {
            run.jobs[index].ended = true
            changed = true
        }
        guard changed else { return run }
        if run.hasUnfinishedJobs {
            save(run, defaults: defaults)
            return run
        }
        clear(defaults: defaults)
        return nil
    }
}

extension PersistedCrossPostJob {
    /// Snapshot of a web-autofill job. The job's own id is kept so the queue can mark
    /// exactly this entry ended.
    init(_ job: CrossPostJob) {
        self.init(
            id: job.id,
            kind: .web,
            platform: job.platform,
            title: job.title,
            listingId: job.listingId,
            description: job.description,
            price: job.price,
            // A job built from a live draft has no paths of its own; its photos are on
            // the draft, which will not exist after a relaunch.
            photoFirebasePaths: job.photoFirebasePaths.isEmpty ? (job.item?.orderedFirebasePhotoPaths ?? []) : job.photoFirebasePaths,
            buyerPaysShipping: job.buyerPaysShipping,
            condition: job.condition,
            suggestedCategory: job.suggestedCategory,
            suggestedBrand: job.suggestedBrand,
            weightLbs: job.weightLbs,
            lengthIn: job.lengthIn,
            widthIn: job.widthIn,
            heightIn: job.heightIn,
            variantProductId: job.variantProductId,
            variantId: job.variantId,
            facebookLocation: job.facebookLocation,
            suggestedFacebookCategory: job.suggestedFacebookCategory
        )
    }

    /// The job to queue on Retry. A fresh id: it is a new attempt, tracked as a new entry.
    var replayJob: CrossPostJob {
        CrossPostJob(
            platform: platform,
            title: title,
            description: description,
            price: price,
            listingId: listingId,
            photoFirebasePaths: photoFirebasePaths,
            buyerPaysShipping: buyerPaysShipping,
            condition: condition,
            suggestedCategory: suggestedCategory,
            suggestedBrand: suggestedBrand,
            weightLbs: weightLbs,
            lengthIn: lengthIn,
            widthIn: widthIn,
            heightIn: heightIn,
            variantProductId: variantProductId,
            variantId: variantId,
            facebookLocation: facebookLocation,
            suggestedFacebookCategory: suggestedFacebookCategory
        )
    }
}
