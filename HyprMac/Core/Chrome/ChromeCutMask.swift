// A mask that leaves out the windows stacked above a floater from its
// chrome (outline, stand-in). Drawn as an image: cut shapes can overlap
// (a tile and a floater both above), and a floater's cut is rounded.

import Cocoa

enum ChromeCutMask {
    /// The mask for a view of `size` whose top-left corner sits at
    /// `topLeftCG` on screen, nil when nothing is cut. A mask already on
    /// `layer` for the same cuts is kept as it is.
    static func apply(to layer: CALayer, size: CGSize, topLeftCG: CGPoint, cuts: [ChromeCut],
                      cornerRadius: CGFloat, scale: CGFloat) {
        let key = cuts.isEmpty ? "" : "\(size)|\(topLeftCG)|\(cornerRadius)|\(scale)|"
            + cuts.map { "\($0.rect)\($0.rounded)" }.joined(separator: ";")
        if (layer.value(forKey: Self.keyName) as? String) == key, (layer.mask != nil) == !cuts.isEmpty { return }
        layer.setValue(key, forKey: Self.keyName)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !cuts.isEmpty, let image = image(size: size, topLeftCG: topLeftCG, cuts: cuts,
                                               cornerRadius: cornerRadius, scale: scale) else {
            layer.mask = nil
            return
        }
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.contents = image
        mask.contentsScale = scale
        layer.mask = mask
    }

    private static let keyName = "hyprChromeCutKey"

    /// White where the chrome draws, clear where a window above cuts it.
    static func image(size: CGSize, topLeftCG: CGPoint, cuts: [ChromeCut],
                      cornerRadius: CGFloat, scale: CGFloat) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded(.up)))
        let h = max(1, Int((size.height * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.clear)
        for cut in cuts {
            // CG screen (y down) to the view's own space (y up)
            let local = CGRect(x: cut.rect.minX - topLeftCG.x,
                               y: size.height - (cut.rect.maxY - topLeftCG.y),
                               width: cut.rect.width, height: cut.rect.height)
            let r = cut.rounded ? min(cornerRadius, local.width / 2, local.height / 2) : 0
            ctx.addPath(CGPath(roundedRect: local, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }
}
