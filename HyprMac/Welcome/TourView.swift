// Single Tour shell that renders both the first-run walkthrough and
// the post-update "What's New" page. Styled on-system with Hypr tokens
// (mockups 1k / 1l): solid dark chassis, cyan accents, mono wordmark.

import SwiftUI

// MARK: - shell

/// 520×440 shell shared by first-run and what's-new. Header (icon +
/// wordmark + right slot) · content page · footer. Mode picks the page
/// set and footer.
struct TourView: View {
    let mode: WelcomeMode
    let onDismiss: () -> Void

    @State private var page = 0

    private var pageCount: Int { mode == .firstRun ? 4 : 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 520, height: 440)
        .background(Color.hyprBackground)
    }

    // MARK: header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text("HYPRMAC")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.7))
            }
            Spacer()
            headerSlot
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var headerSlot: some View {
        switch mode {
        case .firstRun:
            // n / 4 mono page counter
            Text("\(page + 1) / \(pageCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.35))
        case .whatsNew:
            // cyan version chip
            Text(WelcomeContent.appVersion)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprCyan)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .strokeBorder(Color.hyprCyan.opacity(0.3), lineWidth: 1)
                )
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .firstRun:
            Group {
                switch page {
                case 0: TourHeroPage()
                case 1: TourFocusPage()
                case 2: TourWorkspacesPage()
                default: TourFinishPage()
                }
            }
            .transition(.opacity)
            .id(page)
        case .whatsNew:
            WhatsNewPage()
        }
    }

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        switch mode {
        case .firstRun:
            HStack {
                Button("Skip") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.4))

                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.hyprCyan : Color.hyprTextPrimary.opacity(0.18))
                            .frame(width: 6, height: 6)
                            .onTapGesture {
                                withAnimation(HyprMotion.glide) { page = i }
                            }
                    }
                }

                Spacer()

                CyanButton(page < pageCount - 1 ? "Next" : "Get Started") {
                    if page < pageCount - 1 {
                        withAnimation(HyprMotion.glide) { page += 1 }
                    } else {
                        onDismiss()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        case .whatsNew:
            HStack {
                Spacer()
                CyanButton("Continue") { onDismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - shared cyan filled button (dark text on cyan, radius 6)

private struct CyanButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(red: 0x0b/255, green: 0x14/255, blue: 0x17/255))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(Color.hyprCyan)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - first-run page 1: Hypr key hero + live try-it

private struct TourHeroPage: View {
    // flips once the app reports a focusDirection while this page is up
    @State private var tried = false

    var body: some View {
        VStack(spacing: 0) {
            keycap
                .padding(.bottom, 22)

            Text("Caps Lock is your superpower")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            // body copy with "Hypr key" in cyan bold
            (Text("It's the ")
                + Text("Hypr key").foregroundColor(.hyprCyan).bold()
                + Text(" now. Hold it and press a key to command your windows. Nothing else about Caps Lock changes — apps still see it as off."))
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)

            tryItPill
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
        // observe dispatched actions; flip on any focusDirection
        .onReceive(NotificationCenter.default.publisher(for: .hyprMacActionDispatched)) { note in
            if note.userInfo?["action"] as? String == "focusDirection" {
                withAnimation(HyprMotion.snap) { tried = true }
            }
        }
    }

    // 150×58 rounded key with cyan border + 3pt bottom edge + soft glow
    private var keycap: some View {
        HStack(spacing: 8) {
            Text("⇪")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprCyan)
            Text("CAPS LOCK")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.7))
        }
        .frame(width: 150, height: 58)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .strokeBorder(Color.hyprCyan.opacity(0.5), lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            // brighter 3pt bottom edge
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprCyan.opacity(0.7))
                .frame(height: 3)
                .mask(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                )
        }
        .shadow(color: Color.hyprCyan.opacity(0.22), radius: 17)
    }

    // dashed cyan capsule that swaps to a ✓ confirmed state
    private var tryItPill: some View {
        Group {
            if tried {
                HStack(spacing: 8) {
                    Text("✓")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.hyprCyan)
                    Text("Nice — you focused a window")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hyprCyan)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .strokeBorder(Color.hyprCyan.opacity(0.55), lineWidth: 1)
                )
            } else {
                HStack(spacing: 8) {
                    Text("Try it now — hold")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hyprTextPrimary.opacity(0.6))
                    MiniKey("⇪")
                    Text("and press")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hyprTextPrimary.opacity(0.6))
                    MiniKey("→")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .strokeBorder(
                            Color.hyprCyan.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            }
        }
    }
}

// small cyan key chip used inside the try-it pill
private struct MiniKey: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.hyprCyan)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(Color.hyprCyan.opacity(0.35), lineWidth: 1)
            )
    }
}

// MARK: - first-run page 2: Focus

private struct TourFocusPage: View {
    var body: some View {
        TourInfoPage(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            title: "Move between windows",
            copy: attributed,
            bullets: [
                ("arrow.left.arrow.right", "⇪ + an arrow jumps focus to the window in that direction."),
                ("cursorarrow.motionlines", "Focus follows the mouse — hover a window to focus it."),
                ("rectangle.dashed", "A cyan border and corner brackets mark what's focused."),
            ]
        )
    }

    private var attributed: Text {
        Text("Focus is how you say ")
            + Text("this window").foregroundColor(.hyprCyan).bold()
            + Text(". Everything you type goes to whatever is focused.")
    }
}

// MARK: - first-run page 3: Workspaces

private struct TourWorkspacesPage: View {
    var body: some View {
        TourInfoPage(
            icon: "square.stack.3d.up",
            title: "Workspaces",
            copy: attributed,
            bullets: [
                ("number", "⇪ 1–9 switches workspaces. ⇪ ⇧ 1–9 sends a window there."),
                ("menubar.rectangle", "The menu bar shows each one: ● active  ○ occupied  · empty."),
                ("diamond", "◇ marks a workspace holding floating windows — magenta."),
            ],
            magentaBulletIndex: 2
        )
    }

    private var attributed: Text {
        Text("Nine ")
            + Text("workspaces").foregroundColor(.hyprCyan).bold()
            + Text(" per setup. Each monitor shows one at a time.")
    }
}

// MARK: - first-run page 4: Finish → Hypr+K

private struct TourFinishPage: View {
    var body: some View {
        VStack(spacing: 0) {
            HeroGlyph(icon: "keyboard")
                .padding(.bottom, 20)

            Text("That's the core of it")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            HStack(spacing: 6) {
                Text("Press")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                KeyChip("⇪")
                KeyChip("K")
                Text("anytime")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
            }
            .padding(.top, 10)

            Text("The whole keymap lives there — searchable, always one keystroke away.")
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
    }
}

// MARK: - shared info page (hero glyph + title + body + bullet rows)

private struct TourInfoPage: View {
    let icon: String
    let title: String
    let copy: Text
    let bullets: [(icon: String, text: String)]
    var magentaBulletIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            HeroGlyph(icon: icon)
                .padding(.bottom, 18)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            copy
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { idx, row in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(magentaBulletIndex == idx ? Color.hyprMagenta : Color.hyprCyan)
                            .frame(width: 18)
                        Text(row.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.hyprTextPrimary.opacity(0.75))
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 380)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 44)
    }
}

// MARK: - cyan-tinted rounded-square hero glyph

private struct HeroGlyph: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.hyprCyan)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .strokeBorder(Color.hyprCyan.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - what's-new page (mockup 1l)

private struct WhatsNewPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's new")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(WhatsNewFeatures.current, id: \.title) { feature in
                        changelogRow(feature)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private func changelogRow(_ feature: WhatsNewFeature) -> some View {
        let tint: Color = feature.tint == .magenta ? .hyprMagenta : .hyprCyan
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.hyprTextPrimary)
                Text(feature.description)
                    .font(.system(size: 11))
                    .lineSpacing(3)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.hyprSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.hyprTextPrimary.opacity(0.08), lineWidth: 1)
        )
    }
}
