import AppKit
import SwiftUI

// MARK: - Shared chrome

/// Raised card used for every block on this page.
///
/// The previous version tinted every surface with `codexMist.opacity(0.35)`,
/// which read as washed-out and gave no sense of depth. Using the real card
/// surface plus a hairline keeps the blocks distinct from the page background.
struct SettingsUpdateCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.75), lineWidth: 0.75)
            )
    }
}

/// Rounded icon badge used at the head of a card.
struct SettingsUpdateGlyph: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 0.75)
        )
    }
}

/// Transparent mascot artwork stays unchanged across update states.
struct SettingsApplicationIcon: View {
    var config: TomoThemeConfig? = nil

    var body: some View {
        if let config {
            TomoMarkView(config: config, size: 38)
        } else if let url = Bundle.main.url(forResource: "tomo-logo", withExtension: "webp"),
           let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 38, height: 38)
        } else {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage(size: NSSize(width: 38, height: 38)))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 38, height: 38)
        }
    }
}

/// Secondary (tertiary) action chip — one consistent shape for every minor action.
struct SettingsUpdateChip: View {
    let title: String
    let systemImage: String
    var tint: Color = .codexInk
    var isEnabled: Bool = true
    var isBusy: Bool = false
    var busyTint: Color = .accentColor
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                        .tint(busyTint)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isBusy ? busyTint : (isEnabled ? tint : Color.codexMuted.opacity(0.6)))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isBusy ? busyTint.opacity(0.08) : Color.codexMist.opacity(isHovering && isEnabled ? 1.0 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isBusy ? busyTint.opacity(0.22) : Color.codexLine.opacity(0.7), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .onHover { isHovering = $0 }
    }
}

/// Prominent filled action button.
struct SettingsUpdatePrimaryAction: View {
    let title: String
    let systemImage: String
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                        .tint(Color.codexOnPrimary)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(Color.codexOnPrimary)
            .background(
                isBusy
                    ? Color.codexPrimary.opacity(0.85)
                    : (isEnabled ? Color.codexPrimary : Color.codexPrimary.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isBusy ? 0.25 : 0.1), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
    }
}

