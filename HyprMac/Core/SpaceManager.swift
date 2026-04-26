import Cocoa

class SpaceManager {
    // display UUID -> ordered space IDs on that display
    private(set) var spacesByDisplay: [String: [CGSSpaceID]] = [:]
    // space ID -> display UUID
    private(set) var displayForSpace: [CGSSpaceID: String] = [:]
    // ordered display UUIDs (matches CGSCopyManagedDisplaySpaces order)
    private(set) var displayOrder: [String] = []

    private var lastRefreshTime: CFAbsoluteTime = 0
    private let refreshCooldown: CFAbsoluteTime = 0.5

    // refresh the display/space mapping
    func refreshSpaceMap(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force && now - lastRefreshTime < refreshCooldown && !spacesByDisplay.isEmpty {
            return
        }
        lastRefreshTime = now
        let conn = _CGSDefaultConnection()
        guard let cfArray = CGSCopyManagedDisplaySpaces(conn),
              let displaySpaces = cfArray as? [[String: Any]] else { return }

        spacesByDisplay.removeAll()
        displayForSpace.removeAll()
        displayOrder.removeAll()

        for display in displaySpaces {
            let displayID = display["Display Identifier"] as? String ?? "unknown"
            displayOrder.append(displayID)

            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            var ids: [CGSSpaceID] = []
            for space in spaces {
                // type 0 = regular desktop, skip fullscreen (4) etc.
                if let type = space["type"] as? Int, type != 0 { continue }
                if let sid = space["ManagedSpaceID"] as? CGSSpaceID {
                    ids.append(sid)
                    displayForSpace[sid] = displayID
                } else if let sid64 = space["id64"] as? CGSSpaceID {
                    ids.append(sid64)
                    displayForSpace[sid64] = displayID
                }
            }
            spacesByDisplay[displayID] = ids
        }

        hyprLog(.debug, .lifecycle, "space map: \(displayOrder.count) displays")
        for displayID in displayOrder {
            let spaces = spacesByDisplay[displayID] ?? []
            hyprLog(.debug, .lifecycle, "  display '\(displayID)': spaces \(spaces)")
        }
    }

    // get ordered list of space IDs across all displays
    // order: display 1 spaces, then display 2 spaces, etc.
    func getAllSpaceIDs() -> [CGSSpaceID] {
        refreshSpaceMap()
        var result: [CGSSpaceID] = []
        for displayID in displayOrder {
            result.append(contentsOf: spacesByDisplay[displayID] ?? [])
        }
        hyprLog(.debug, .lifecycle, "all space IDs: \(result)")
        return result
    }

    // get the currently active space ID on the focused display
    func currentSpaceID() -> CGSSpaceID? {
        let conn = _CGSDefaultConnection()
        guard let cfArray = CGSCopyManagedDisplaySpaces(conn),
              let displaySpaces = cfArray as? [[String: Any]] else {
            return nil
        }

        // return the current space of the main (focused) display
        for display in displaySpaces {
            if let current = display["Current Space"] as? [String: Any] {
                if let sid = current["ManagedSpaceID"] as? CGSSpaceID {
                    return sid
                } else if let sid64 = current["id64"] as? CGSSpaceID {
                    return sid64
                }
            }
        }
        return nil
    }

    // get all current space IDs (one per display)
    func allCurrentSpaceIDs() -> [CGSSpaceID] {
        let conn = _CGSDefaultConnection()
        guard let cfArray = CGSCopyManagedDisplaySpaces(conn),
              let displaySpaces = cfArray as? [[String: Any]] else { return [] }

        var result: [CGSSpaceID] = []
        for display in displaySpaces {
            if let current = display["Current Space"] as? [String: Any] {
                if let sid = current["ManagedSpaceID"] as? CGSSpaceID {
                    result.append(sid)
                } else if let sid64 = current["id64"] as? CGSSpaceID {
                    result.append(sid64)
                }
            }
        }
        return result
    }

    // get the space ID for a given desktop number (1-indexed)
    func spaceID(forDesktop number: Int) -> CGSSpaceID? {
        let spaces = getAllSpaceIDs()
        guard number >= 1 && number <= spaces.count else { return nil }
        return spaces[number - 1]
    }

    // get which display UUID a desktop number belongs to
    func displayID(forDesktop number: Int) -> String? {
        guard let sid = spaceID(forDesktop: number) else { return nil }
        return displayForSpace[sid]
    }

    // type 7 = kCGSSpaceAll on Sequoia
    private let kCGSAllSpacesMask: CInt = 7

    func spaceForWindow(_ windowID: CGWindowID) -> CGSSpaceID? {
        let conn = _CGSDefaultConnection()
        let winArray = [NSNumber(value: windowID)] as CFArray
        guard let cfArray = CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, winArray),
              let spaces = cfArray as? [NSNumber], let first = spaces.first else {
            return nil
        }
        return first.uint64Value
    }

    // move a window to a different space
    func moveWindow(_ windowID: CGWindowID, toSpace spaceID: CGSSpaceID) {
        let conn = _CGSDefaultConnection()
        let winArray = [NSNumber(value: windowID)] as CFArray

        // log current spaces before move
        if let cfBefore = CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, winArray),
           let before = cfBefore as? [NSNumber] {
            hyprLog(.debug, .lifecycle, "moveWindow \(windowID): before spaces=\(before.map { $0.uint64Value })")
        }

        // use atomic move API — removes from all current spaces and adds to target in one call
        CGSMoveWindowsToManagedSpace(conn, winArray, spaceID)

        // verify
        if let cfAfter = CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, winArray),
           let after = cfAfter as? [NSNumber] {
            hyprLog(.debug, .lifecycle, "moveWindow \(windowID): after spaces=\(after.map { $0.uint64Value })")
        }

        hyprLog(.debug, .lifecycle, "moved window \(windowID) to space \(spaceID)")
    }

    // initialize space tracking (call on startup)
    func setup() {
        refreshSpaceMap(force: true)
        hyprLog(.debug, .lifecycle, "space manager ready: \(displayOrder.count) displays, \(displayForSpace.count) spaces")
    }

    // switch to a desktop using the private CGS API (direct, no sentinels needed)
    func switchToDesktop(_ number: Int) -> Bool {
        refreshSpaceMap(force: true)

        guard let targetSpaceID = spaceID(forDesktop: number) else {
            hyprLog(.debug, .lifecycle, "switchToDesktop: desktop \(number) doesn't exist")
            return false
        }

        guard let targetDisplay = displayForSpace[targetSpaceID] else {
            hyprLog(.debug, .lifecycle, "switchToDesktop: no display for space \(targetSpaceID)")
            return false
        }

        let conn = _CGSDefaultConnection()
        let displayStr = targetDisplay as CFString
        CGSManagedDisplaySetCurrentSpace(conn, displayStr, targetSpaceID)

        hyprLog(.debug, .lifecycle, "switchToDesktop \(number): space=\(targetSpaceID) display=\(targetDisplay)")
        return true
    }

}
