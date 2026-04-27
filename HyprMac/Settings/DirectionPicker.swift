import SwiftUI

// 4-way segmented picker for Direction. used by focusDirection,
// swapDirection, and moveWorkspaceToMonitor (which still accepts
// up/down for now even though the dispatcher only honors left/right).
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
