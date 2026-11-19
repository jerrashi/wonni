//
//  SoldOutRun.swift
//  wonni
//
//  "Mark as sold out" as a queued run — the plain-value half.
//
//  Decided with the user 2026-10-24/29 (BACKEND.md § "Sold-out + sales tracking —
//  product decisions"): selecting one or more listings and marking them sold out
//  enqueues one job per listing on the same pill that publishing uses; the pill
//  reads "Marking sold out · 1 of 4"; tapping it opens a per-listing progress list;
//  a Mercari step runs in a web view the user can open; a job leaves the queue only
//  once every platform confirmed, and a listing whose Mercari step still fails after
//  a timeout and one retry is put BACK in stock and listed at the end.
//
//  Everything here is Codable so a run survives the app being killed (same idea as
//  CrossPostRunStore). The rules are pure and unit-tested (SoldOutPlanTests); the
//  loop that executes them is SoldOutRunner.
//

import Foundation

/// What "sold out" means on Mercari. Account-wide setting (Profile › Settings ›
/// Mercari); the cascade's `pendingMercariDeactivation` flag keeps its name either way.
enum MercariSoldOutAction: String, Codable, CaseIterable, Identifiable {
    case deactivate, delete
    var id: String { rawValue }

    static let storageKey = "mercariSoldOutAction"

    var label: String { self == .deactivate ? "Deactivate" : "Delete" }
}

/// What the listing's own Mercari page says right now.
enum MercariListingState: Equatable {
    case active, inactive, sold
    /// Mercari's "no longer for sale" page: deactivated OR deleted, the page can't tell.
    case unavailable
    /// The page could not be read. Never acted on.
    case unknown
}

/// How the Mercari step ended. Decides whether the stored Mercari id is kept.
enum MercariSoldOutOutcome: Equatable {
    case deactivated, deleted, alreadyInactive, alreadySold, alreadyGone

    /// The listing no longer exists on Mercari, so Wonni's pointers to it must go.
    /// A sold listing keeps its id: sales are matched to products by that id.
    var removedFromMercari: Bool { self == .deleted || self == .alreadyGone }
}

enum MercariSoldOutDecision: Equatable {
    case nothing(MercariSoldOutOutcome)
    case deactivate
    case delete
    /// Status unreadable: fail the step instead of guessing.
    case stop
}

struct SoldOutJob: Codable, Equatable, Identifiable {
    enum StepState: Codable, Equatable {
        case waiting
        case running(String)
        case done
        case failed(String)
        /// The seller left this platform alone (already sold out there by hand).
        case skipped

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .skipped: return true
            default: return false
            }
        }
    }

    var id: UUID
    var listingId: String
    var title: String
    var coverPhotoPath: String?
    /// Stock before the run, restored when the Mercari step fails for good.
    var previousQuantity: Int
    /// Platforms the one server call (`markSoldOutAndCascade`) covers, in display
    /// order: "wonni" first, then the API platforms the listing is live on.
    var serverPlatforms: [String]
    var mercariItemId: String?
    var mercariAction: MercariSoldOutAction
    var serverStep: StepState = .waiting
    /// `.done` from the start when the listing is not on Mercari.
    var mercariStep: StepState = .waiting
    /// The attempt finished (every step terminal) while the app was alive.
    var ended = false
    /// Why the listing was NOT marked sold out (stock restored). Nil = success or still running.
    var failure: String?
    /// Platforms left alone: chosen on the confirm sheet or added by Skip. Optional so
    /// runs persisted by older builds still decode.
    var skipPlatforms: [String]?
    /// API platforms the server call reported as failed, with eBay's/Etsy's reason.
    /// Wonni itself is sold out when these are set; Skip accepts them as they are.
    var platformErrors: [String: String]?

    var hasMercariStep: Bool { mercariItemId != nil }
    var succeeded: Bool { ended && failure == nil }
    var skips: Set<String> { Set(skipPlatforms ?? []) }
    var skipsMercari: Bool { skips.contains("mercari") }
    /// Wonni plus the API platforms this run still changes, for the "Wonni + eBay" row.
    var activeServerPlatforms: [String] { serverPlatforms.filter { !skips.contains($0) } }

    mutating func addSkip(_ platforms: [String]) {
        skipPlatforms = Array(skips.union(platforms)).sorted()
    }

    /// Resets a cut-off or failed attempt so it can run again.
    var reset: SoldOutJob {
        var copy = self
        copy.serverStep = .waiting
        copy.mercariStep = hasMercariStep ? (skipsMercari ? .skipped : .waiting) : .done
        copy.ended = false
        copy.failure = nil
        copy.platformErrors = nil
        return copy
    }
}

struct SoldOutRun: Codable, Equatable {
    var userId: String
    var jobs: [SoldOutJob]
    var hasUnfinishedJobs: Bool { jobs.contains { !$0.ended } }
}

/// The rules, with no Firebase or UI in them.
enum SoldOutPlan {
    /// How long one platform step may take before it is retried, then given up on.
    static let stepTimeout: TimeInterval = 60
    /// Attempts per step (the first try plus one automatic retry).
    static let stepAttempts = 2

    /// Statuses that mean "this listing is on that platform right now".
    static let liveStatuses: Set<String> = ["posted", "active", "pending"]

    // Builds the job for a listing. Platforms come off `crossPostStatus`; Mercari is
    // a step of its own because it has no API.
    // swiftlint:disable:next function_parameter_count
    static func makeJob(
        listingId: String,
        title: String?,
        coverPhotoPath: String?,
        quantity: Int?,
        crossPostStatus: [String: String]?,
        crossPostListingIds: [String: String]?,
        action: MercariSoldOutAction,
        skip: Set<String> = []
    ) -> SoldOutJob {
        let live = (crossPostStatus ?? [:])
            .filter { liveStatuses.contains($0.value) }
            .map(\.key)
        let apiPlatforms = ["ebay", "etsy", "tiktok"].filter(live.contains)
        let mercariId = crossPostListingIds?["mercari"].flatMap { $0.isEmpty ? nil : $0 }
        var job = SoldOutJob(
            id: UUID(),
            listingId: listingId,
            title: (title?.isEmpty == false ? title : nil) ?? "Untitled listing",
            coverPhotoPath: coverPhotoPath,
            previousQuantity: max(quantity ?? 1, 1),
            serverPlatforms: ["wonni"] + apiPlatforms,
            mercariItemId: mercariId,
            mercariAction: action
        )
        let relevant = skip.intersection(Set(apiPlatforms + (mercariId == nil ? [] : ["mercari"])))
        if !relevant.isEmpty { job.skipPlatforms = relevant.sorted() }
        if mercariId == nil { job.mercariStep = .done } else if relevant.contains("mercari") { job.mercariStep = .skipped }
        return job
    }

    /// Platforms the confirm sheet offers a toggle for: every one at least one of the
    /// selected listings is on, in display order. Wonni is always on and not listed.
    static func togglePlatforms(_ jobs: [SoldOutJob]) -> [String] {
        let present = Set(jobs.flatMap { $0.serverPlatforms + ($0.hasMercariStep ? ["mercari"] : []) })
        return ["ebay", "etsy", "tiktok", "mercari"].filter(present.contains)
    }

    /// The "Wonni + eBay" row title.
    static func serverRowTitle(_ job: SoldOutJob) -> String {
        job.activeServerPlatforms.map(displayName).joined(separator: " + ")
    }

    /// One line for a server step whose API platforms failed: "eBay: <reason>".
    static func platformFailureText(_ errors: [String: String]) -> String {
        errors.sorted { $0.key < $1.key }
            .map { "\(displayName($0.key)): \($0.value)" }
            .joined(separator: " · ")
    }

    /// The Mercari step's decision table: the listing's live status, then the seller's
    /// sold-out preference (Profile › Settings › Mercari).
    static func mercariDecision(state: MercariListingState, preference: MercariSoldOutAction) -> MercariSoldOutDecision {
        switch state {
        case .active:
            switch preference {
            case .deactivate: return .deactivate
            case .delete: return .delete
            }
        case .inactive:
            switch preference {
            case .deactivate: return .nothing(.alreadyInactive)
            case .delete: return .delete
            }
        case .unavailable:
            switch preference {
            case .deactivate: return .nothing(.alreadyInactive)
            // May still exist as an inactive listing; the delete path checks first.
            case .delete: return .delete
            }
        case .sold:
            // Mercari keeps sold listings as order records; there is nothing to take down.
            return .nothing(.alreadySold)
        case .unknown:
            return .stop
        }
    }

    static func displayName(_ platform: String) -> String {
        switch platform {
        case "wonni": return "Wonni"
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "tiktok": return "TikTok"
        case "mercari": return "Mercari"
        default: return platform.capitalized
        }
    }

    /// Pill label: the listing being worked on, out of the total ("1 of 4" while the
    /// first runs, "4 of 4" while the last runs).
    static func pillLabel(jobs: [SoldOutJob]) -> String {
        let total = jobs.count
        let done = jobs.filter(\.ended).count
        let current = min(done + 1, max(total, 1))
        return "Marking sold out · \(current) of \(total)"
    }

    /// Pill detail: what the current step is doing.
    static func pillDetail(jobs: [SoldOutJob]) -> String? {
        guard let job = jobs.first(where: { !$0.ended }) else { return nil }
        if case .running(let step) = job.mercariStep { return "\(step): \(job.title)" }
        if case .running(let step) = job.serverStep { return "\(step): \(job.title)" }
        return "Queued: \(job.title)"
    }

    static func progress(jobs: [SoldOutJob]) -> Double {
        guard !jobs.isEmpty else { return 0 }
        return Double(jobs.filter(\.ended).count) / Double(jobs.count)
    }

    /// The end-of-run message for listings that could not be marked sold out.
    static func failureSummary(_ failed: [SoldOutJob]) -> String? {
        guard !failed.isEmpty else { return nil }
        return failed.count == 1
            ? "1 listing was not marked sold out and is still in stock."
            : "\(failed.count) listings were not marked sold out and are still in stock."
    }

    /// Error-pill label once a run ends with failures.
    static func failurePillLabel(_ failedCount: Int) -> String {
        "\(failedCount) not marked sold out"
    }
}

/// Disk persistence for the current run. One run at a time: jobs queued while a run
/// is unfinished join it.
enum SoldOutRunStore {
    private static let key = "soldOutRun.v1"

    static func load(defaults: UserDefaults = .standard) -> SoldOutRun? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SoldOutRun.self, from: data)
    }

    static func save(_ run: SoldOutRun, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Writes the runner's current jobs; clears the store once every job has ended
    /// (a run that finished leaves nothing behind for the next launch).
    static func sync(jobs: [SoldOutJob], userId: String, defaults: UserDefaults = .standard) {
        let run = SoldOutRun(userId: userId, jobs: jobs)
        if run.hasUnfinishedJobs {
            save(run, defaults: defaults)
        } else {
            clear(defaults: defaults)
        }
    }
}
