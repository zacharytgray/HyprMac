import Cocoa

class CursorManager {
    func warpToCenter(of window: HyprWindow) {
        mainThreadOnly()
        guard let center = window.center else { return }
        CGWarpMouseCursorPosition(center)
        // briefly disassociate mouse to prevent delta accumulation
        CGAssociateMouseAndMouseCursorPosition(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
