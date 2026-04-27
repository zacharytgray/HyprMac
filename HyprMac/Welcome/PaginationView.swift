import SwiftUI

// bottom-of-page footer shared by Onboarding and Welcome modes.
// dots in the middle, optional Skip on the left, Next/finish on the right.
// tapping a dot animates to that page; the rightmost button changes label
// on the final page (and skips the Next path entirely).
struct PaginationView: View {
    @Binding var currentPage: Int
    let totalPages: Int
    let showSkip: Bool
    let nextLabel: String
    let finishLabel: String
    let onFinish: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack {
            if showSkip && currentPage < totalPages - 1 {
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Circle()
                        .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { currentPage = i }
                        }
                }
            }

            Spacer()

            if currentPage < totalPages - 1 {
                Button(nextLabel) {
                    withAnimation(.easeInOut(duration: 0.2)) { currentPage += 1 }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(finishLabel) { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }
}
