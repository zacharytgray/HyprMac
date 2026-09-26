// Segmented picker for `switchWorkspace`, `moveToWorkspace` and
// `moveToWorkspaceAndFollow`.

import SwiftUI

/// Segmented workspace picker.
struct WorkspacePicker: View {
    @Binding var workspace: Int

    var body: some View {
        Picker("Workspace", selection: $workspace) {
            ForEach(Constants.workspaceRange, id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
