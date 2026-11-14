import SwiftUI
import MezzanineKit

/// What to choose artwork for: the title whose poster or background it is.
struct ArtworkRequest: Identifiable {
    let id = UUID()
    /// The artwork's owner (a movie, a show, a season; episodes resolve to their show).
    let item: PlexMetadata
    var kind: ArtworkKind
}

/// Choose Poster / Choose Background: every picture Plex offers for a title (agents, uploads
/// such as Kometa's, the title's own folder), applied for Mezzanine only (the default; nothing
/// on the server changes) or on the Plex server for every app.
///
/// Keys: arrows move, Return uses the selection, Esc cancels.
struct ArtworkPicker: View {
    let request: ArtworkRequest

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ArtworkKind = .poster
    @State private var candidates: [ArtworkKind: [ArtworkCandidate]] = [:]
    @State private var selected: [ArtworkKind: String] = [:]
    @State private var loading = true
    @State private var failed: String?
    @State private var target: Target = .mezzanine
    @State private var applying = false
    /// After a server write: what changed and what it replaced (the sheet stays open so the
    /// previous picture is one click away).
    @State private var status: String?
    @State private var columns = 5
    @FocusState private var gridFocused: Bool

    enum Target: String, CaseIterable { case mezzanine, server }

    private var owner: String { request.item.ratingKey }
    private var list: [ArtworkCandidate] { candidates[kind] ?? [] }
    private var cellWidth: CGFloat { kind == .poster ? 132 : 236 }
    private var cellHeight: CGFloat { kind == .poster ? 198 : 133 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Artwork for \(Format.displayTitle(request.item))")
                    .font(Theme.Typeface.cardHeadline).foregroundStyle(Theme.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Artwork", selection: $kind) {
                    Text("Poster").tag(ArtworkKind.poster)
                    Text("Background").tag(ArtworkKind.background)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            grid

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Picker("Apply to", selection: $target) {
                    Text("Mezzanine only").tag(Target.mezzanine)
                    Text("The Plex server").tag(Target.server)
                        .accessibilityHint("Changes it for every Plex app")
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .disabled(applying)
                Text(target == .mezzanine
                     ? "Nothing on the server changes. Other Plex apps keep their artwork."
                     : "Every Plex app shows it. Tools that manage artwork, such as Kometa, may replace it on their next run.")
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
            }

            HStack {
                if library.artworkOverride(kind, for: owner) != nil {
                    Button("Remove Mezzanine’s Choice") {
                        library.setArtworkOverride(kind, for: owner, path: nil)
                        announce("Mezzanine shows Plex’s \(kind.label.lowercased()) again")
                    }
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                    .disabled(applying)
                    .help("Show the Plex server’s \(kind.label.lowercased()) again")
                }
                Spacer()
                if applying { ProgressView().controlSize(.small).accessibilityLabel("Saving to the Plex server") }
                if let line = failed ?? status {
                    Text(line).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
                Button(status == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                    .disabled(applying)
                // The default button names where it writes, so Return is never a surprise.
                Button(target == .server ? "Use \(kind.label) on Plex Server" : "Use \(kind.label)") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle()).focusEffectDisabled(false)
                    .disabled(selectedCandidate == nil || applying)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 860, height: 640)
        .presentationBackground(Theme.graphite)
        .interactiveDismissDisabled(applying)
        .task { await load() }
        .onChange(of: failed) { _, message in if let message { announce(message) } }
        .onAppear { kind = request.kind; gridFocused = true }
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 20), spacing: Theme.Space.l)],
                              alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, candidate in
                            cell(candidate, index: i).id(candidate.id)
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .onChange(of: selected[kind]) { _, id in
                    guard let id else { return }
                    withAnimation(Theme.Motion.quick) { proxy.scrollTo(id) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in
                columns = max(1, Int((w - Theme.Space.m * 2 + Theme.Space.l) / (cellWidth + Theme.Space.l)))
            }
            .onChange(of: kind) { _, _ in
                columns = max(1, Int((geo.size.width - Theme.Space.m * 2 + Theme.Space.l) / (cellWidth + Theme.Space.l)))
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised.opacity(0.6)))
        .overlay(alignment: .topLeading) { state }
        // One Tab stop: the arrows drive the selection (lift + lilac caption, no ring).
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.home) { step(-list.count); return .handled }
        .onKeyPress(.end) { step(list.count); return .handled }
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            case .up: step(-columns)
            case .down: step(columns)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind == .poster ? "Posters" : "Backgrounds")
    }

    private func cell(_ candidate: ArtworkCandidate, index: Int) -> some View {
        let isSelected = selected[kind] == candidate.id
        let inUse = isInUse(candidate)
        return Button {
            selected[kind] = candidate.id
            gridFocused = true
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                RemoteImage(url: thumbURL(candidate), pixelWidth: Int(cellWidth * 2))
                    .frame(width: cellWidth, height: cellHeight)
                    .accessibilityHidden(true)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if inUse {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.graphite.opacity(0.82)))
                                .padding(8)
                        }
                    }
                    .shadow(color: .black.opacity(isSelected ? 0.6 : 0.3), radius: isSelected ? 18 : 6, y: isSelected ? 10 : 3)
                    .scaleEffect(isSelected ? 1.04 : 1, anchor: .bottom)
                    .animation(Theme.Motion.lift, value: isSelected)
                Text(inUse ? "\(candidate.source) · In use" : candidate.source)
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(isSelected ? Theme.lilac : Theme.inkSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        // A double-click uses it for Mezzanine; a server write always goes through the named button.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selected[kind] = candidate.id
            if target == .mezzanine { Task { await apply() } }
        })
        .accessibilityLabel("\(candidate.source) \(kind.label.lowercased()), \(index + 1) of \(list.count)")
        .accessibilityValue(inUse ? "In use" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: target == .server ? "Use on Plex Server" : "Use \(kind.label)") {
            selected[kind] = candidate.id
            Task { await apply() }
        }
    }

    @ViewBuilder private var state: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small).accessibilityLabel("Loading artwork")
            } else if let failed, list.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(failed).foregroundStyle(Theme.inkSecondary)
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                }
            } else if list.isEmpty {
                Text("Plex has no other \(kind == .poster ? "posters" : "backgrounds") for this title.")
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .font(Theme.Typeface.body)
        .padding(Theme.Space.l)
    }

    // MARK: Data

    private var selectedCandidate: ArtworkCandidate? {
        guard let id = selected[kind] else { return nil }
        return list.first { $0.id == id }
    }

    /// In use: Mezzanine's own choice when there is one, else the server's.
    private func isInUse(_ candidate: ArtworkCandidate) -> Bool {
        if let local = library.artworkOverride(kind, for: owner) { return candidate.key == local }
        return candidate.selected
    }

    /// Plex's small rendition for provider pictures; server files through the photo transcoder.
    private func thumbURL(_ c: ArtworkCandidate) -> URL? {
        if let thumb = c.thumb, thumb.hasPrefix("http") { return URL(string: thumb) }
        let path = c.thumb ?? c.key
        return kind == .poster ? session.posterURL(path, pixelWidth: Int(cellWidth * 2))
                               : session.backdropURL(path, pixelWidth: Int(cellWidth * 2))
    }

    private func step(_ delta: Int) {
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selected[kind] } ?? 0
        let next = list[min(max(0, i + delta), list.count - 1)]
        selected[kind] = next.id
        announce("\(next.source)\(isInUse(next) ? ", in use" : "")")
    }

    private func load() async {
        guard let client = session.client else { failed = "Not connected to the server."; loading = false; return }
        loading = true
        failed = nil
        do {
            async let posters = client.artwork(.poster, ratingKey: owner)
            async let backgrounds = client.artwork(.background, ratingKey: owner)
            let (p, b) = try await (posters, backgrounds)
            candidates = [.poster: p, .background: b]
            for k in ArtworkKind.allCases {
                let items = candidates[k] ?? []
                let local = library.artworkOverride(k, for: owner)
                selected[k] = (items.first { $0.key == local } ?? items.first { $0.selected } ?? items.first)?.id
            }
        } catch {
            failed = (error as? PlexError)?.userMessage ?? "The artwork didn’t load."
        }
        loading = false
    }

    private func apply() async {
        guard !applying, let candidate = selectedCandidate else { return }
        switch target {
        case .mezzanine:
            library.setArtworkOverride(kind, for: owner, path: candidate.key)
            announce("\(kind.label) set for Mezzanine")
            dismiss()
        case .server:
            guard let client = session.client else { return }
            let previous = list.first { $0.selected }
            applying = true
            failed = nil
            defer { applying = false }
            do {
                try await client.setArtwork(kind, ratingKey: owner, to: candidate)
                // The server's choice now leads; drop any Mezzanine-only one and re-read the title.
                library.setArtworkOverride(kind, for: owner, path: nil)
                await library.syncAll()
                if let fresh = try? await client.artwork(kind, ratingKey: owner) { candidates[kind] = fresh }
                // Stay open: the previous picture is one click away if this was a mistake.
                status = "Set on the Plex server." + (previous.map { " Before: \($0.source)." } ?? "")
                announce(status ?? "")
            } catch {
                failed = (error as? PlexError)?.userMessage ?? "The server didn’t accept it."
            }
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

extension ArtworkKind {
    var label: String { self == .poster ? "Poster" : "Background" }
}
