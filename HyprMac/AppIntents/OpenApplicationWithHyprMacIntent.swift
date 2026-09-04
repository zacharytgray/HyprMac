// Spotlight and Shortcuts action for opening an application through HyprMac.

import AppIntents
import Foundation

/// A generic action whose application parameter is supplied by the dynamic
/// installed-app query. Spotlight can run this action directly on macOS 26.
@available(macOS 15.0, *)
struct OpenApplicationWithHyprMacIntent: AppIntent, PredictableIntent {
    static let title: LocalizedStringResource = "Open App with HyprMac"
    static let description = IntentDescription(
        "Reveal and position an installed application's window with HyprMac.",
        categoryName: "Window Management",
        searchKeywords: ["open", "launch", "focus", "app", "window"]
    )

    @Parameter(
        title: "Application",
        description: "The application for HyprMac to open or reveal.",
        requestValueDialog: "Which application should HyprMac open?"
    )
    var application: InstalledApplicationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$application) with HyprMac")
    }

    /// Keep HyprMac's accessory app in the background. `supportedModes` is
    /// only present in the macOS 26 SDK, while this project intentionally
    /// remains buildable with Xcode 16; the established compatibility
    /// property has the same background-only behavior on both SDKs.
    static var openAppWhenRun: Bool { false }

    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: \.$application) { application in
            DisplayRepresentation(title: "Open \(application.displayName) with HyprMac")
        }
    }

    init() {}

    init(application: InstalledApplicationEntity) {
        self.application = application
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await AppIntentApplicationActivationBridge.activate(
            bundleIdentifier: application.id
        )

        switch result {
        case .activated, .openedWithoutWindow:
            return .result(dialog: "Opened \(application.displayName) with HyprMac.")
        case .unavailable:
            throw OpenApplicationIntentError.applicationUnavailable(application.displayName)
        case .timedOut:
            throw OpenApplicationIntentError.timedOut(application.displayName)
        case .failed(let message):
            throw OpenApplicationIntentError.activationFailed(application.displayName, message)
        case .cancelled:
            throw CancellationError()
        }
    }
}

private enum OpenApplicationIntentError: LocalizedError {
    case applicationUnavailable(String)
    case timedOut(String)
    case activationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable(let name):
            return "\(name) is no longer available to HyprMac."
        case .timedOut(let name):
            return "HyprMac did not find a manageable window for \(name) in time."
        case .activationFailed(let name, let reason):
            return "HyprMac could not open \(name): \(reason)"
        }
    }
}
