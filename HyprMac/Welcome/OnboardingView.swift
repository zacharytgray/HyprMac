import SwiftUI

// First-launch onboarding tutorial. Five paged screens introducing the
// Hypr key, focus, workspaces, quick tips, and a finish prompt.
struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var currentPage = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            // header
            VStack(spacing: 6) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                Text("Getting Started")
                    .font(.system(size: 22, weight: .bold))
                Text("Learn the basics in under a minute")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            // page content
            Group {
                switch currentPage {
                case 0: concept
                case 1: focus
                case 2: workspaces
                case 3: tips
                case 4: finish
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(currentPage)

            PaginationView(
                currentPage: $currentPage,
                totalPages: pageCount,
                showSkip: true,
                nextLabel: "Next",
                finishLabel: "Let's Go!",
                onFinish: onDismiss,
                onSkip: onDismiss
            )
        }
    }

    // MARK: - pages

    private var concept: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Caps Lock Is Your Superpower")
                .font(.system(size: 16, weight: .semibold))
            Text("Hold Caps Lock and press something. That's the whole idea — one key unlocks everything.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("We call it the Hypr key.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var focus: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Move Between Windows")
                .font(.system(size: 16, weight: .semibold))
            Text("Hold Caps Lock and press an arrow key to jump focus to a window in that direction.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("Add Shift to swap two windows instead.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var workspaces: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Workspaces")
                .font(.system(size: 16, weight: .semibold))
            Text("Caps Lock + a number (1–9) switches workspaces instantly. Add Shift to send a window there.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("Each monitor has its own active workspace.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var tips: some View {
        VStack(spacing: 10) {
            Text("Quick Tips")
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "macwindow.on.rectangle", text: "Float or unfloat a window with Caps+Shift+T")
                tipRow(icon: "arrow.triangle.2.circlepath", text: "Cycle through floating windows with Caps+F")
                tipRow(icon: "cursorarrow.click", text: "Press Caps+` (backtick) to warp the cursor to the menu bar")
                tipRow(icon: "hand.draw", text: "Drag a window onto another to swap their positions")
                tipRow(icon: "arrow.left.arrow.right", text: "Caps+J flips a window split from side-by-side to stacked")
            }
            .padding(.horizontal, 32)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var finish: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.badge.eye")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("You're All Set")
                .font(.system(size: 16, weight: .semibold))
            Text("Press Caps+K at any time to see a cheat sheet of all your keybinds.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 24)
    }
}
