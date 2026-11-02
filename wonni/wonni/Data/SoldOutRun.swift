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

struct SoldOutJob: Codable, Equatable, Identifiable {
    enum StepState: Codable, Equatable {
        case waiting
        case running(String)
        case done
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .done, .failed: return true
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

    var hasMercariStep: Bool { mercariItemId != nil }
    var succeeded: Bool { ended && failure == nil }

    /// Resets a cut-off or failed attempt so it can run again.
    var reset: SoldOutJob {
        var copy = self
        copy.serverStep = .waiting
        copy.mercariStep = hasMercariStep ? .waiting : .done
        copy.ended = false
        copy.failure = nil
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
        action: MercariSoldOutAction
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
        if mercariId == nil { job.mercariStep = .done }
        return job
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

    /// The confirm dialog before anything is queued. Names the Mercari action the run
    /// will take (read from the account setting); under Delete that line is the
    /// once-per-run "Delete out-of-stock listings on Mercari?" confirmation.
    struct Confirmation: Equatable {
        let title: String
        let message: String
        let button: String
    }

    static func confirmation(count: Int, mercariCount: Int, action: MercariSoldOutAction) -> Confirmation {
        let noun = count == 1 ? "listing" : "listings"
        let title = count == 1 ? "Mark as sold out?" : "Mark \(count) \(noun) as sold out?"
        var message = "Quantity goes to 0 on Wonni, eBay and Etsy."
        var button = "Mark Sold Out"
        if mercariCount > 0 {
            let those = mercariCount == count ? (count == 1 ? "It is" : "All \(count) are") : "\(mercariCount) \(mercariCount == 1 ? "is" : "are")"
            switch action {
            case .deactivate:
                message += " \(those) on Mercari and will be deactivated there (change in Settings)."
            case .delete:
                message += " \(those) on Mercari. Delete out-of-stock listings on Mercari? This cannot be undone there (change in Settings)."
                button = "Mark Sold Out & Delete on Mercari"
            }
        }
        return Confirmation(title: title, message: message, button: button)
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
