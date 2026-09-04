// Process-local bridge from App Intents into HyprMac's activation coordinator.

import Foundation

/// Keeps App Intents independent from AppKit launching and window-management
/// details. The app installs its long-lived `ApplicationActivating` service as
/// early as possible during launch; the bridge deliberately owns it weakly.
@MainActor
enum AppIntentApplicationActivationBridge {
    private struct PendingActivation {
        var handle: ApplicationActivationHandle?
        let continuation: CheckedContinuation<ApplicationActivationResult, Never>
    }

    private static weak var service: (any ApplicationActivating)?
    private static var serviceIsReady = false
    private static var pendingActivations: [UUID: PendingActivation] = [:]

    static func install(_ service: any ApplicationActivating, ready: Bool = true) {
        self.service = service
        serviceIsReady = ready
    }

    static func markReady(_ candidate: any ApplicationActivating) {
        guard let installedService = service, installedService === candidate else { return }
        serviceIsReady = true
    }

    static func remove(_ candidate: any ApplicationActivating) {
        guard let installedService = service, installedService === candidate else { return }
        service = nil
        serviceIsReady = false
        cancelAllPendingActivations()
    }

    /// Await the callback API while retaining its cancellation handle.
    static func activate(bundleIdentifier: String) async throws -> ApplicationActivationResult {
        let service = try await readyService()
        // A stop/replacement can run while the readiness await resumes.
        guard self.service === service, serviceIsReady else {
            throw AppIntentActivationBridgeError.serviceUnavailable
        }
        guard !Task.isCancelled else { return .cancelled }

        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Register before calling the service: valid implementations
                // may complete synchronously (for example, `.unavailable`).
                pendingActivations[requestID] = PendingActivation(
                    handle: nil,
                    continuation: continuation
                )
                let handle = service.activate(
                    bundleID: bundleIdentifier,
                    source: .spotlight
                ) { result in
                    Task { @MainActor in
                        finish(requestID: requestID, result: result)
                    }
                }
                if pendingActivations[requestID] != nil {
                    pendingActivations[requestID]?.handle = handle
                }
            }
        } onCancel: {
            Task { @MainActor in
                cancel(requestID: requestID)
            }
        }
    }

    /// A background App Intent can arrive before launch has installed the
    /// manager or completed its first window snapshot. Yield the main actor
    /// while waiting; never launch an app against partially initialized state.
    private static func readyService() async throws -> any ApplicationActivating {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        while true {
            try Task.checkCancellation()
            if serviceIsReady, let service { return service }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AppIntentActivationBridgeError.serviceUnavailable
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func finish(requestID: UUID, result: ApplicationActivationResult) {
        guard let pending = pendingActivations.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(returning: result)
    }

    private static func cancel(requestID: UUID) {
        guard let pending = pendingActivations.removeValue(forKey: requestID) else { return }
        pending.handle?.cancel()
        pending.continuation.resume(returning: .cancelled)
    }

    private static func cancelAllPendingActivations() {
        let pending = Array(pendingActivations.values)
        pendingActivations.removeAll()
        for activation in pending {
            activation.handle?.cancel()
            activation.continuation.resume(returning: .cancelled)
        }
    }
}

enum AppIntentActivationBridgeError: LocalizedError {
    case serviceUnavailable

    var errorDescription: String? {
        "HyprMac's window activation service is not ready. Open HyprMac and try again."
    }
}
