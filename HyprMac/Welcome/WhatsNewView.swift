// Post-update "What's New" panel.

import SwiftUI

/// Single-page "What's New" panel rendering
/// `WhatsNewFeatures.current` (curated per release — see CLAUDE.md
/// "Release Feature List").
struct WhatsNewView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("What's New in HyprMac")
                    .font(.system(size: 22, weight: .bold))
                Text("v\(WelcomeContent.appVersion)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WhatsNewFeatures.current, id: \.title) { feature in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 14))
                                .foregroundColor(.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(feature.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Continue") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
    }
}
