import XCTest
@testable import HyprMac

// the updater's windows float above the tiles and are never tiled
final class UpdateWindowsTests: XCTestCase {

    private final class UpdaterAlertController: NSWindowController {}
    private final class OtherController: NSWindowController {}

    // stands in for Bundle(for:): only the updater's controller is Sparkle's
    private let bundleID: (AnyClass) -> String? = { cls in
        cls == UpdaterAlertController.self ? UpdateWindows.sparkleBundleID : "com.zachgray.HyprMac"
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    func testAWindowWithASparkleControllerIsAnUpdateWindow() {
        let alert = window()
        let controller = UpdaterAlertController(window: alert)
        XCTAssertTrue(UpdateWindows.isUpdateWindow(alert, bundleID: bundleID))
        _ = controller
    }

    func testHyprMacsOwnWindowsAreNotUpdateWindows() {
        let settings = window()
        let controller = OtherController(window: settings)
        XCTAssertFalse(UpdateWindows.isUpdateWindow(settings, bundleID: bundleID))
        XCTAssertFalse(UpdateWindows.isUpdateWindow(window(), bundleID: bundleID))
        _ = controller
    }

    // the level Settings and the overlays use: above every tile and floater,
    // and outside the two layers discovery reads
    func testAnUpdateWindowIsLiftedToTheInterfaceLevel() {
        let alert = window()
        XCTAssertEqual(alert.level, .normal)
        UpdateWindows.float(alert, bringForward: false)
        XCTAssertEqual(alert.level, Constants.interfaceWindowLevel)
        XCTAssertGreaterThan(alert.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertFalse(WindowAdmissionFilter.quickLookLayers.contains(alert.level.rawValue))
    }

    func testAModalAlertKeepsItsHigherLevel() {
        let alert = window()
        alert.level = .modalPanel
        UpdateWindows.float(alert, bringForward: false)
        XCTAssertEqual(alert.level, .modalPanel)
    }

    func testFloatAllLiftsOnlyTheUpdaterWindows() {
        let alert = window(), settings = window()
        let controllers: [NSWindowController] = [UpdaterAlertController(window: alert),
                                                 OtherController(window: settings)]
        let found = UpdateWindows.floatAll(in: [alert, settings], bringForward: false, bundleID: bundleID)
        XCTAssertEqual(found, 1)
        XCTAssertEqual(alert.level, Constants.interfaceWindowLevel)
        XCTAssertEqual(settings.level, .normal)
        _ = controllers
    }

    // with Show in Dock on HyprMac is a regular app. discovery must still
    // skip it, or a normal-level updater window is tiled like any other
    func testDiscoveryNeverWalksHyprMacItself() {
        XCTAssertFalse(AccessibilityManager.isWalked(policy: .regular, pid: 42, bundleID: "com.zachgray.HyprMac",
                                                     excludedBundleIDs: [], ownPID: 42))
        XCTAssertTrue(AccessibilityManager.isWalked(policy: .regular, pid: 43, bundleID: "com.apple.Terminal",
                                                    excludedBundleIDs: [], ownPID: 42))
    }

    func testDiscoveryStillSkipsBackgroundAndExcludedApps() {
        XCTAssertFalse(AccessibilityManager.isWalked(policy: .accessory, pid: 43, bundleID: "com.example.agent",
                                                     excludedBundleIDs: [], ownPID: 42))
        XCTAssertFalse(AccessibilityManager.isWalked(policy: .regular, pid: 43,
                                                     bundleID: "com.apple.QuickLookDaemon",
                                                     excludedBundleIDs: ["com.apple.QuickLookDaemon"], ownPID: 42))
        XCTAssertTrue(AccessibilityManager.isWalked(policy: .regular, pid: 43, bundleID: nil,
                                                    excludedBundleIDs: ["com.apple.QuickLookDaemon"], ownPID: 42))
    }
}
