import SwiftUI
import MezzanineKit

/// Plex Home profiles: who's watching. Each profile keeps its own index, Continue Watching,
/// watched marks and shelves (all keyed by the profile's account).
///
/// Pointer path: the sidebar's footer (avatar and name, a menu of profiles). Keyboard and
/// menu path: Mezzanine ▸ Switch Profile. Profiles with a PIN ask for it in a sheet.
enum ProfileSwitch {
    /// Switches now, or asks for the PIN first.
    @MainActor
    static func choose(_ user: PlexHomeUser, session: SessionStore, commands: AppCommandCenter) {
        guard user.uuid != session.account?.uuid else { return }
        if user.protected && !user.admin {
            commands.pinRequest = user
        } else {
            commands.go(to: .home)
            Task { try? await session.switchProfile(to: user, pin: nil) }
        }
    }
}

/// The profiles as menu items, the current one checked. Takes its stores directly: the menu
/// bar's commands have no environment objects.
struct ProfileMenuItems: View {
    let session: SessionStore
    let commands: AppCommandCenter

    var body: some View {
        ForEach(session.homeUsers) { user in
            Toggle(isOn: Binding(get: { user.uuid == session.account?.uuid },
                                 set: { _ in ProfileSwitch.choose(user, session: session, commands: commands) })) {
                Label {
                    Text(user.protected && !user.admin ? "\(user.title) (PIN)" : user.title)
                } icon: {
                    Image(nsImage: session.avatars[user.uuid] ?? Self.placeholder)
                }
            }
        }
        .task { await session.loadAvatars() }
    }

    /// A neutral disc while an avatar loads (or when a profile has none).
    private static let placeholder: NSImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }
}

/// The sidebar's footer: who's watching, and the way to switch.
struct SidebarProfileButton: View {
    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @State private var hovering = false

    private var current: PlexHomeUser? { session.homeUsers.first { $0.uuid == session.account?.uuid } }

    var body: some View {
        Menu {
            ProfileMenuItems(session: session, commands: commands)
        } label: {
            HStack(spacing: Theme.Space.s) {
                RemoteImage(url: URL(string: current?.thumb ?? session.account?.thumb ?? ""), pixelWidth: 64, placeholder: Theme.raised)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(current?.title ?? session.account?.displayName ?? "Profile")
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? Theme.raisedHover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled(false)
        .onHover { hovering = $0 }
        .disabled(commands.isPlayerOpen || commands.hasMiniPlayer)
        .help("Switch profile (Mezzanine ▸ Switch Profile)")
        .accessibilityLabel("Profile: \(current?.title ?? "unknown"). Switch profile")
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }
}

/// A protected profile's PIN.
struct ProfilePINSheet: View {
    let user: PlexHomeUser

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                RemoteImage(url: URL(string: user.thumb ?? ""), pixelWidth: 112, placeholder: Theme.raised)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switch to \(user.title)").font(Theme.Typeface.cardHeadline).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Enter \(user.title)’s PIN.").font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                }
            }
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { submit() }
                .accessibilityLabel("PIN for \(user.title)")
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.ink)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                Button("Switch") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle()).focusEffectDisabled(false)
                    .disabled(pin.count < 4 || working)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 400)
        .presentationBackground(Theme.graphite)
        .onAppear { focused = true }
    }

    private func submit() {
        guard pin.count >= 4, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await session.switchProfile(to: user, pin: pin)
                commands.go(to: .home)
                dismiss()
            } catch PlexError.unauthorized {
                error = "That PIN didn’t match."
                pin = ""
                focused = true
                AccessibilityNotification.Announcement("That PIN didn’t match.").post()
            } catch {
                self.error = (error as? PlexError)?.userMessage ?? "Couldn’t switch profile."
            }
        }
    }
}
