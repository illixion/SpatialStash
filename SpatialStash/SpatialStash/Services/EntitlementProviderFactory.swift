/*
 Spatial Stash - Entitlement provider factory

 The only place that chooses between `NoopEntitlementProvider` and the real
 App Store commerce engine. `HypnosCommerce` is a private package — its
 Xcode package reference is added only on the `hypnos/appstore` branch,
 never on `main` — so everything below that touches it must stay inside
 `#if HYPNOS_APPSTORE`. On `main`, where that condition is never defined,
 this whole block is skipped before the compiler ever tries to resolve the
 import, exactly like the existing `HYPNOS_PRIVATE_API` guards in
 `PrivateSpatial3DiOS.swift` — that's what keeps `main` buildable with
 no access to the private repo at all.
 */

#if HYPNOS_APPSTORE
import HypnosCommerce
#endif

enum EntitlementProviderFactory {
    @MainActor
    static func make() -> any EntitlementProviding {
        #if HYPNOS_APPSTORE
        return HypnosAppStoreEntitlementProvider()
        #else
        return NoopEntitlementProvider()
        #endif
    }
}

#if HYPNOS_APPSTORE
/// Adapts `HypnosCommerce.HypnosEntitlementEngine` to `EntitlementProviding`.
/// The adapter — not `HypnosEntitlementEngine` itself — is what conforms,
/// because `HypnosCommerce` has no dependency on this app target and so has
/// no way to reference `EntitlementProviding` at all; this file is the only
/// place the two sides meet.
@MainActor
final class HypnosAppStoreEntitlementProvider: EntitlementProviding {
    private let engine = HypnosEntitlementEngine()

    var isUnlocked: Bool { engine.isUnlocked }

    var preprocessedTrialState: EntitlementTrialState {
        switch engine.trialState {
        case .notStarted: return .notStarted
        case .active(let daysRemaining): return .active(daysRemaining: daysRemaining)
        case .expired: return .expired
        }
    }

    func startPreprocessedTrialIfNeeded() async {
        await engine.startPreprocessedTrialIfNeeded()
    }

    func refresh() async {
        await engine.refresh()
    }

    func purchaseUnlock() async throws {
        try await engine.purchaseUnlock()
    }

    func restorePurchases() async throws {
        try await engine.restorePurchases()
    }
}
#endif
