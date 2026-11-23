import AppKit
import SwiftUI

struct SetupAppearancePage: View {
    @AppStorage(LockWallpaper.autoKey) private var lockArt = false
    @AppStorage(DesktopColors.key) private var desktopColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                SetupWallpaperCard(title: "Lock-screen artwork",
                                   detail: "Album artwork while music plays. Your wallpaper returns on unlock.",
                                   desktop: false, isOn: $lockArt)
                SetupWallpaperCard(title: "Album colors",
                                   detail: "Your desktop takes the album’s colors, then returns when playback stops.",
                                   desktop: true, isOn: $desktopColors)
            }
            SetupNote(icon: .refresh, text: "Your original wallpaper is saved first and restored automatically.")
            SetupDesktopTransitions()
        }
        .onChange(of: lockArt) { _, enabled in
            Analytics.shared.trackFeature(.appearance, action: "lock_art", data: ["enabled": .bool(enabled)])
        }
        .onChange(of: desktopColors) { _, enabled in
            Analytics.shared.trackFeature(.appearance, action: "album_colors", data: ["enabled": .bool(enabled)])
        }
    }
}

/// A KLOI bento card: a bold title and its line, the switch beside them, and a preview well under both with the notch
/// at its top edge. While the option is on the notch glows orange and the preview shows the effect.
/// A schematic, not a picture of the user's own music or desktop.
private struct SetupWallpaperCard: View {
    let title: String
    let detail: String
    let desktop: Bool
    @Binding var isOn: Bool

    var body: some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 16, weight: .heavy)).tracking(-0.4).foregroundStyle(SetupTheme.text)
                        Text(detail).setupDetail().fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(SetupSwitchStyle())
                }
                SetupWallpaperWell(desktop: desktop, isOn: isOn)
            }
        }
        .animation(.easeOut(duration: 0.4), value: isOn)
    }
}

private struct SetupWallpaperWell: View {
    let desktop: Bool
    let isOn: Bool
    @Environment(\.colorScheme) private var scheme

    private let album = [Color(red: 0.24, green: 0.36, blue: 0.30), Color(red: 0.55, green: 0.62, blue: 0.52)]

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(SetupTheme.row)
            if isOn {
                LinearGradient(colors: desktop ? [album[0].opacity(scheme == .dark ? 0.7 : 0.45), album[1].opacity(0.25)]
                                               : [album[0].opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .transition(.opacity)
            }
            if desktop { desktopContent } else { lockContent }
            notch
        }
        .frame(height: 124)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(SetupTheme.ink(0.05, 0.06), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.black.opacity(0.05), lineWidth: 2).blur(radius: 2).offset(y: 1)
            .mask(RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .accessibilityHidden(true)
    }

    private var notch: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
            .fill(Color.black)
            .frame(width: isOn ? 76 : 64, height: isOn ? 15 : 12)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, SetupTheme.accent, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1).opacity(isOn ? 1 : 0)
            }
            .shadow(color: isOn ? SetupTheme.accent.opacity(0.45) : .black.opacity(0.2), radius: isOn ? 14 : 5, y: isOn ? 6 : 2)
    }

    private var lockContent: some View {
        VStack(spacing: 8) {
            Text("9:41").font(.system(size: isOn ? 15 : 24, weight: .bold, design: .rounded))
                .foregroundStyle(isOn ? SetupTheme.textSecondary : SetupTheme.textFaint)
            if isOn {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: album, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1).padding(10))
                    .frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 14)
    }

    private var desktopContent: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SetupTheme.ink(0.14, 0.18)).frame(width: 15, height: 15)
                }
            }
            .padding(5)
            .background(SetupTheme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(SetupTheme.ring, lineWidth: 1))
            .padding(.bottom, 12)
        }
    }
}
