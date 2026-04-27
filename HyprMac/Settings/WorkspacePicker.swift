import SwiftUI

// 1-9 segmented picker for switchWorkspace and moveToWorkspace targets.
struct WorkspacePicker: View {
    @Binding var workspace: Int

    var body: some View {
        Picker("Workspace", selection: $workspace) {
            ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
