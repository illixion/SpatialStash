/*
 Hypnos - Entitlement seam

 Abstraction over "what commerce entitlements does this build have."

 The public/sideload build always uses `NoopEntitlementProvider` below —
 this repo has no StoreKit code and no paywall, so everything reports
 unlocked. The real implementation lives in the private `HypnosCommerce`
 package, linked only from the `hypnos/appstore` branch behind the
 `HYPNOS_APPSTORE` compile condition; `EntitlementProviderFactory` (in the
 same directory) is what decides which one `AppModel` gets.
 */

import Foundation

/// `@MainActor`: every real conformer talks to StoreKit/AppModel state that
/// is itself MainActor-bound, and `AppModel` — the only caller — already is
/// too. Isolating the protocol here removes any Sendable ambiguity around
/// passing `any EntitlementProviding` into a `Task`, since caller and
/// conformer share one actor throughout.
@MainActor
protocol EntitlementProviding: AnyObject {
    /// Whether the one-time non-consumable unlock has been purchased.
    /// Always reflects the store's own purchase record as of the last
    /// `refresh()` — never a locally cached bit that could go stale across
    /// a refund or a family-sharing revocation.
    var isUnlocked: Bool { get }

    /// State of the 30-day pre-processed-3D trial.
    var preprocessedTrialState: EntitlementTrialState { get }

    /// Starts the pre-processed-3D trial clock if it hasn't started yet. A
    /// no-op once purchased or once a trial has already started. Call from
    /// the first "Convert to 3D → Pre-Process" engage — never speculatively,
    /// since a real implementation only gets one trial start per install.
    func startPreprocessedTrialIfNeeded() async

    /// Refreshes `isUnlocked`/`preprocessedTrialState`. Call on launch and
    /// after `purchaseUnlock()`/`restorePurchases()`.
    func refresh() async

    /// Buys the one-time unlock. Throws on failure; a user cancellation is
    /// not an error and returns normally.
    func purchaseUnlock() async throws

    /// Restores a prior purchase (e.g. after reinstall). Throws on failure.
    func restorePurchases() async throws
}

/// `EntitlementProviding.preprocessedTrialState`.
enum EntitlementTrialState: Equatable {
    /// Never engaged pre-processed 3D — the trial clock hasn't started.
    case notStarted
    /// Trial running; `daysRemaining` is never negative.
    case active(daysRemaining: Int)
    /// The trial window has elapsed with no purchase.
    case expired
}

extension EntitlementProviding {
    /// Whether pre-processed 3D conversion (and playback of an existing
    /// pre-processed cache entry) may be used right now.
    var canUsePreprocessed3D: Bool {
        if isUnlocked { return true }
        if case .active = preprocessedTrialState { return true }
        return false
    }

    /// Per-session cap on real-time fake-3D playback, in seconds — `nil`
    /// when unlocked (unlimited). The free-tier cap (90s) resets every new
    /// playback session; see `Pseudo3DStereoEngine` for where the session
    /// boundary actually is.
    var realtimeSessionCapSeconds: TimeInterval? {
        isUnlocked ? nil : 90
    }
}

/// Ships in every build without `HYPNOS_APPSTORE` — the public/sideload
/// default. Reports full access to every feature: there is no StoreKit
/// here, so there is nothing to gate.
@MainActor
final class NoopEntitlementProvider: EntitlementProviding {
    var isUnlocked: Bool { true }
    var preprocessedTrialState: EntitlementTrialState { .active(daysRemaining: 30) }

    func startPreprocessedTrialIfNeeded() async {}
    func refresh() async {}
    func purchaseUnlock() async throws {}
    func restorePurchases() async throws {}
}
