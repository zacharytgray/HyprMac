// 4-way segmented picker for `Direction`.

import SwiftUI

/// 4-way segmented picker for `Direction`. Used by direction-bearing
/// keybind actions in the editor sheet.
struct DirectionPicker: View {
    @Binding var direction: Direction

    var body: some View {
        Picker("Direction", selection: $direction) {
            Text("Left").tag(Direction.left)
            Text("Right").tag(Direction.right)
            Text("Up").tag(Direction.up)
            Text("Down").tag(Direction.down)
        }
        .pickerStyle(.segmented)
    }
}
