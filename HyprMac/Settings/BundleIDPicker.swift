// Text field + helper hint for the `launchApp` bundle-ID parameter.

import SwiftUI

/// Bundle-ID text field used by the keybind editor for `launchApp`.
struct BundleIDPicker: View {
    @Binding var bundleID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Bundle ID", text: $bundleID)
                .textFieldStyle(.roundedBorder)
            Text("e.g. com.apple.Terminal, com.googlecode.iterm2")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
