// A tree's shape to and from its saved form. Reads nodes and builds fresh ones;
// a live tree is only ever changed by `TilingEngine`.

import CoreGraphics

enum LayoutTreeCodec {
    static func serialize(_ node: BSPNode, keeping fallbacks: Set<ObjectIdentifier>,
                          ref: (HyprWindow) -> SavedWindowRef?) -> LayoutNode? {
        if let window = node.window {
            return ref(window).map(LayoutNode.leaf)
        }
        guard let left = node.left, let right = node.right else { return nil }
        switch (serialize(left, keeping: fallbacks, ref: ref), serialize(right, keeping: fallbacks, ref: ref)) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            return only
        case (let l?, let r?):
            // an axis smart insert pinned is this screen's, and the rect
            // gives it back; only togglesplit goes into the snapshot, and a
            // fallback axis the rect would not give back
            let leftOut = node.splitOverrideIsAutomatic && !fallbacks.contains(ObjectIdentifier(node))
            return .split(override: leftOut ? nil : node.splitOverride,
                          ratio: node.splitRatio,
                          userSet: node.userSetRatio, left: l, right: r)
        }
    }

    static func build(_ node: LayoutNode, resolve: (SavedWindowRef) -> HyprWindow?) -> BSPNode? {
        switch node {
        case .leaf(let ref):
            return resolve(ref).map { BSPNode(window: $0) }
        case let .split(override, ratio, userSet, left, right):
            switch (build(left, resolve: resolve), build(right, resolve: resolve)) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                return only
            case (let l?, let r?):
                let n = BSPNode()
                n.left = l
                n.right = r
                l.parent = n
                r.parent = n
                n.splitOverride = override
                n.splitRatio = ratio
                n.userSetRatio = userSet
                return n
            }
        }
    }
}
