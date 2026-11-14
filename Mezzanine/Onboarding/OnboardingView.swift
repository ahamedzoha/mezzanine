import SwiftUI
import MezzanineKit

/// First run (and signed-out): one quiet column of setup beside a wall of
/// your own posters that fills as the library is read.
///
/// Steps: sign in → server (only with more than one) → profile (only with a
/// Plex Home of more than one) → library warm-up → Home. Pointer-first: every
/// step is one visible control; Return also works.
struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var serverConfirmed = false
    @State private var profileConfirmed = false
    @State private var wall: [PlexMetadata] = []

    enum Step: Equatable { case signIn, server, profile, library }

    private var step: Step {
        guard session.phase == .ready else { return .signIn }
        if !serverConfirmed && session.servers.count > 1 { return .server }
        if !profileConfirmed && session.homeUsers.count > 1 { return .profile }
        return .library
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                column
                    .frame(width: max(380, geo.size.width * 0.4))
                    .background(Theme.graphite)
                PosterWall(items: wall, lit: step == .library && allRead)
                    .overlay(alignment: .leading) {
                        // The wall dissolves into the column (the column itself stays solid).
                        LinearGradient(colors: [Theme.graphite, Theme.graphite.opacity(0)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 120)
                    }
                    .clipped()
                    .ignoresSafeArea()
            }
        }
        .background { RoomLight(palette: playback.roomPalette, intensity: wall.isEmpty ? 0.4 : 1) }
        .task(id: library.revision) {
            guard session.phase == .ready else { return }
            let items = await library.wallItems(limit: 160)
            if items.count != wall.count { withAnimation(.easeOut(duration: 0.3)) { wall = items } }
        }
        .task(id: wall.count) { await cycleRoomLight() }
        .onChange(of: step) { _, _ in AccessibilityNotification.ScreenChanged(nil).post() }
        .task(id: session.phase) {
            if session.phase == .ready { await session.loadHomeUsers() }
        }
        #if DEBUG
        // -OnboardingStep library jumps past server and profile (screenshots).
        .onAppear {
            if UserDefaults.standard.string(forKey: "OnboardingStep") == "library" {
                serverConfirmed = true
                profileConfirmed = true
            }
        }
        #endif
    }

    // MARK: Column

    /// The wordmark sits at a fixed height; each step's content grows below it,
    /// so nothing jumps as steps change.
    private var column: some View {
        GeometryReader { geo in
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Spacer().frame(height: max(Theme.Space.xxl, geo.size.height * 0.38))
            Text("MEZZANINE")
                .font(TitleFont.font(size: 76))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Group {
                switch step {
                case .signIn: SignInStep()
                case .server: ServerStep { serverConfirmed = true }
                case .profile: ProfileStep { profileConfirmed = true }
                case .library: LibraryStep(allRead: allRead) { finish() }
                }
            }
            .transition(.opacity)
            .animation(Theme.Motion.light, value: step)
            Spacer(minLength: Theme.Space.xxl)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var allRead: Bool {
        let titles = library.sectionTitles
        return !titles.isEmpty && titles.allSatisfy { library.finishedSections.contains($0) }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.5)) { onboardingComplete = true }
    }

    /// The room takes the light of a newly arrived poster every few seconds.
    private func cycleRoomLight() async {
        // Reduce Motion: one steady light, no drifting.
        if reduceMotion {
            if let item = wall.first, let palette = RoomPalette(item.ultraBlur) { playback.roomPalette = palette }
            return
        }
        while !Task.isCancelled {
            if let item = wall.prefix(40).randomElement(), let palette = RoomPalette(item.ultraBlur) {
                playback.roomPalette = palette
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }
}

// MARK: - Steps

private struct StepText: View {
    let line: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(line).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}

private struct SignInStep: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            switch session.phase {
            case .signedOut:
                StepText(line: "Your Plex library, on your Mac.",
                         detail: "Sign in with Plex. Your browser opens to approve Mezzanine, then this window carries on by itself.")
                Button("Sign In with Plex") { session.signIn() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .awaitingApproval(let code):
                StepText(line: "Approve Mezzanine in your browser.",
                         detail: "This window carries on by itself once you do.")
                HStack(spacing: Theme.Space.s) {
                    Text("Or go to").foregroundStyle(Theme.inkSecondary)
                    Link("plex.tv/link", destination: URL(string: "https://plex.tv/link")!)
                    Text("and enter").foregroundStyle(Theme.inkSecondary)
                    Text(code)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                }
                .font(Theme.Typeface.body)
                HStack(spacing: Theme.Space.m) {
                    Button("Open Plex Again") { session.reopenApproval() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel") { session.cancelSignIn() }
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    ProgressView().controlSize(.small).accessibilityLabel("Waiting for approval")
                }
            case .connecting:
                StepText(line: "Finding your server…", detail: "Trying its local address first.")
                ProgressView().controlSize(.small).accessibilityLabel("Connecting")
            case .failed(let message):
                StepText(line: "Couldn’t connect.", detail: message)
                HStack(spacing: Theme.Space.m) {
                    Button("Try Again") { Task { await session.restore() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    if session.isLocalNetworkDenied {
                        Button("Open Local Network Settings") { SessionStore.openLocalNetworkSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Sign Out") { session.signOut() }.buttonStyle(SecondaryButtonStyle())
                }
            case .ready:
                EmptyView()
            }
        }
    }
}

private struct ServerStep: View {
    @Environment(SessionStore.self) private var session
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepText(line: "Which server?", detail: "Mezzanine connected to the fastest one. You can switch any time in Settings.")
            VStack(spacing: 2) {
                ForEach(session.servers) { server in
                    let current = server.clientIdentifier == session.currentServer?.clientIdentifier
                    Button {
                        Task { await session.select(server) }
                    } label: {
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: current ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(current ? Theme.lilac : Theme.inkTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                                Text(caption(server, current: current)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(current ? Theme.raised : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(current ? "Connected" : "Connects to this server")
                }
            }
            .frame(maxWidth: 440)
            Button("Continue", action: done)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func caption(_ server: PlexServerResource, current: Bool) -> String {
        var parts = [server.owned ? "Yours" : "Shared with you"]
        if current, let c = session.connection {
            parts.append(c.connection.route == .local ? "on this network" : (c.connection.route == .relay ? "through Plex relay" : "over the internet"))
            parts.append("\(Int(c.latency.components.attoseconds / 1_000_000_000_000_000 + c.latency.components.seconds * 1000)) ms")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProfileStep: View {
    @Environment(SessionStore.self) private var session
    let done: () -> Void
    @State private var pinFor: PlexHomeUser?
    @State private var pin = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepText(line: "Who’s watching?", detail: "Each profile keeps its own Continue Watching and watched marks.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Space.m)], alignment: .leading, spacing: Theme.Space.m) {
                ForEach(session.homeUsers) { user in
                    Button { choose(user) } label: {
                        VStack(spacing: Theme.Space.s) {
                            RemoteImage(url: URL(string: user.thumb ?? ""), pixelWidth: 160, placeholder: Theme.raised)
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                                .overlay(alignment: .bottomTrailing) {
                                    if user.protected {
                                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Theme.graphite).padding(5).background(Circle().fill(Theme.ink))
                                    }
                                }
                            Text(user.title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                        .frame(width: 96)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(false)
                    .disabled(working)
                    .accessibilityLabel(user.protected ? "\(user.title), needs a PIN" : user.title)
                }
            }
            .frame(maxWidth: 440)
            if let user = pinFor {
                HStack(spacing: Theme.Space.m) {
                    SecureField("PIN for \(user.title)", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .focused($pinFocused)
                        .onSubmit { submitPIN(user) }
                    Button("Continue") { submitPIN(user) }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(pin.count < 4 || working)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private func choose(_ user: PlexHomeUser) {
        error = nil
        if user.protected && !user.admin {
            pinFor = user
            pin = ""
            pinFocused = true
            return
        }
        Task { await switchTo(user, pin: nil) }
    }

    private func submitPIN(_ user: PlexHomeUser) {
        Task { await switchTo(user, pin: pin) }
    }

    private func switchTo(_ user: PlexHomeUser, pin: String?) async {
        working = true
        defer { working = false }
        do {
            try await session.switchProfile(to: user, pin: pin)
            done()
        } catch PlexError.unauthorized {
            error = "That PIN didn’t match."
            self.pin = ""
            pinFocused = true
            AccessibilityNotification.Announcement("That PIN didn’t match.").post()
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t switch profile."
        }
    }
}

private struct LibraryStep: View {
    @Environment(LibraryStore.self) private var library
    let allRead: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepText(line: allRead ? "Your library is ready." : "Reading your library…",
                     detail: allRead ? "Everything lives on this Mac now, so browsing and search are instant."
                                     : "You can start watching now; the rest keeps reading in the background.")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(library.sectionTitles, id: \.self) { title in
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: library.finishedSections.contains(title) ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(library.finishedSections.contains(title) ? Theme.ink : Theme.inkTertiary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(count(title)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                    }
                    .frame(maxWidth: 440)
                    .accessibilityElement(children: .combine)
                }
            }
            Button("Open Mezzanine", action: open)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func count(_ title: String) -> String {
        guard let p = library.progress[title] else { return "Waiting" }
        if library.finishedSections.contains(title) { return library.summary(sectionTitle: title) ?? p.total.formatted(.number) }
        return p.total > 0 ? "\(p.done.formatted(.number)) of \(p.total.formatted(.number))" : "Reading"
    }
}

// MARK: - Wall

/// A wall of the library's posters, edge to edge. Cells resolve in a
/// diagonal sweep as titles arrive; dimmed until the library is read.
struct PosterWall: View {
    let items: [PlexMetadata]
    let lit: Bool

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = 0

    private let cell = CGSize(width: 124, height: 186)
    private let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let cols = Int(ceil((geo.size.width + gap) / (cell.width + gap))) + 1
            let rows = Int(ceil((geo.size.height + gap) / (cell.height + gap))) + 1
            // Diagonal order: cells nearer the top-left resolve first.
            let order = (0..<(cols * rows)).sorted { a, b in
                let da = a / cols + a % cols, db = b / cols + b % cols
                return da == db ? a < b : da < db
            }
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = rank[r * cols + c] ?? 0
                            WallCell(item: i < min(revealed, items.count) ? items[i % max(1, items.count)] : nil, size: cell)
                        }
                    }
                }
            }
            .offset(x: -cell.width * 0.3, y: -cell.height * 0.25)
            .opacity(lit ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.8), value: lit)
        }
        .accessibilityHidden(true)
        .task(id: items.count) {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) { revealed = items.count }
                return
            }
            while revealed < items.count && !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.35)) { revealed += 1 }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }
}

private struct WallCell: View {
    let item: PlexMetadata?
    let size: CGSize
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sharp = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous).fill(Theme.raised.opacity(0.6))
            if let item {
                // Each poster resolves blur-to-sharp as it arrives.
                RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: Int(size.width * 2)),
                            pixelWidth: Int(size.width * 2), placeholder: .clear)
                    .blur(radius: sharp || reduceMotion ? 0 : 10)
                    .opacity(sharp ? 1 : 0)
                    .onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.6)) { sharp = true } }
                    .task(id: item.ratingKey) { await library.resolveCleanPoster(for: item) }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
    }
}
