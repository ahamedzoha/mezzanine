import SwiftUI
import MezzanineKit

/// Browses a personal-media library (Courses) by its folders on disk:
/// course → section → lesson. One click opens a folder; a lesson plays from
/// its play button or Return. ← at the top level returns to the sidebar;
/// ⌘↑ (Go ▸ Enclosing Folder), Delete or ← inside a folder goes up.
struct FolderBrowser: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [PlexServerClient.FolderListing.Folder] = []
    @State private var listing: PlexServerClient.FolderListing?
    /// The folder path `listing` belongs to (it lags `path` while the next folder loads).
    @State private var listingPath: [PlexServerClient.FolderListing.Folder] = []
    @State private var loading = false
    @State private var error: String?
    @State private var focused: Int?
    @State private var hovered: Int?
    /// Lesson and folder counts per folder key, filled as rows appear.
    @State private var counts: [String: (folders: Int, lessons: Int)] = [:]
    /// The folder to refocus after going up (Finder does the same).
    @State private var returnTo: String?

    private var rowCount: Int { (listing?.folders.count ?? 0) + (listing?.items.count ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !path.isEmpty {
                breadcrumbs
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.s)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let listing {
                            ForEach(Array(listing.folders.enumerated()), id: \.element.id) { i, folder in
                                folderRow(folder, index: i).id(i)
                            }
                            ForEach(Array(listing.items.enumerated()), id: \.element.ratingKey) { j, item in
                                lessonRow(item, index: listing.folders.count + j).id(listing.folders.count + j)
                            }
                        }
                    }
                    // One list per folder: rows from the last folder never linger in this one.
                    .id(listingPath.last?.key ?? "root")
                    .padding(.horizontal, Theme.Space.gutter - Theme.Space.m)
                    .padding(.top, path.isEmpty ? Theme.Space.xl : 0)
                    .padding(.bottom, Theme.Space.xl)
                    .opacity(loading ? 0.5 : 1)
                }
                .onChange(of: focused) { _, i in
                    guard let i else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(i) }
                }
            }
        }
        .overlay {
            if listing == nil {
                if let error { RoomMessage(title: "Couldn’t open this folder", detail: error, retry: { Task { await load() } }) }
                else { RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Loading") } }
            } else if rowCount == 0 && !loading {
                RoomMessage(title: "This folder is empty", detail: nil)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand { direction in
            guard rowCount > 0 else { if direction == .left { leftEdge() }; return }
            switch direction {
            case .up: focused = max(0, (focused ?? 0) - 1)
            case .down: focused = min(rowCount - 1, (focused ?? -1) + 1)
            case .left: leftEdge()
            case .right: _ = activateFocused(foldersOnly: true)
            default: break
            }
        }
        .onKeyPress(.return) { activateFocused(foldersOnly: false) }
        .onKeyPress(.space) { activateFocused(foldersOnly: false) }
        .onKeyPress(.delete) { goUp(); return .handled }
        .onChange(of: commands.enclosingFolderRequests) { _, _ in goUp() }
        .task(id: path.last?.key ?? "root") { await load() }
        #if DEBUG
        // -FolderClicks "2,0": opens the 3rd folder, then the 1st inside it (walkthrough captures).
        .task {
            guard let clicks = UserDefaults.standard.string(forKey: "FolderClicks") else { return }
            for token in clicks.split(separator: ",") {
                try? await Task.sleep(for: .seconds(2))
                if let i = Int(token), let folders = listing?.folders, folders.indices.contains(i) { open(folders[i]) }
            }
            try? await Task.sleep(for: .seconds(2))
            print("FOLDERS path=\(path.map(\.title)) listing=\(listingPath.map(\.title)) rows=\(rowCount)")
        }
        #endif
    }

    // MARK: Parts

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            crumb(section.title) { path = [] }
            ForEach(Array(path.enumerated()), id: \.element.id) { i, folder in
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
                if i == path.count - 1 {
                    Text(folder.title)
                        .font(Theme.Typeface.shelfTitle)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    crumb(folder.title) { path = Array(path.prefix(i + 1)) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(false)
        .help("Go to \(title)")
    }

    private func folderRow(_ folder: PlexServerClient.FolderListing.Folder, index: Int) -> some View {
        Button { open(folder) } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(Theme.inkSecondary).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.title).font(Theme.Typeface.cardTitle).foregroundStyle(focused == index ? Theme.lilac : Theme.ink).lineLimit(1)
                    if let meta = folderMeta(folder) {
                        Text(meta).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .rowChrome(highlighted: focused == index || hovered == index)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .task { await count(folder) }
        .accessibilityLabel("Folder \(folder.title)")
        .accessibilityValue(folderMeta(folder) ?? "")
        .accessibilityAddTraits(focused == index ? .isSelected : [])
    }

    private func lessonRow(_ item: PlexMetadata, index: Int) -> some View {
        let meta = [item.duration.map(Format.duration), Format.timeLeft(item)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: item.isWatched ? "checkmark.circle.fill" : (item.progress != nil ? "circle.lefthalf.filled" : "play.circle"))
                .font(.system(size: 18)).foregroundStyle(item.isWatched ? Theme.inkTertiary : Theme.inkSecondary).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.Typeface.cardTitle).foregroundStyle(focused == index ? Theme.lilac : Theme.ink).lineLimit(1)
                Text(meta).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if hovered == index || focused == index { PlayDisc { play(item) } }
        }
        .rowChrome(highlighted: focused == index || hovered == index)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .simultaneousGesture(TapGesture().onEnded { focused = index })
        .simultaneousGesture(TapGesture(count: 2).onEnded { play(item) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(focused == index ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(item.title)
        .accessibilityValue([item.isWatched ? "Watched" : item.progress.map { "\(Int($0 * 100)) percent watched" }, meta]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction { play(item) }
    }

    private func folderMeta(_ folder: PlexServerClient.FolderListing.Folder) -> String? {
        guard let c = counts[folder.key] else { return nil }
        var parts: [String] = []
        if c.folders > 0 { parts.append(c.folders == 1 ? "1 section" : "\(c.folders) sections") }
        if c.lessons > 0 { parts.append(c.lessons == 1 ? "1 video" : "\(c.lessons) videos") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func load() async {
        guard let client = session.client else { return }
        // Keep the current rows on screen while the next folder loads.
        loading = listing != nil
        error = nil
        let requested = path
        do {
            let next = try await client.folder(section: section.key, key: requested.last?.key)
            // A newer folder was opened while this one loaded: its listing wins.
            guard !Task.isCancelled, requested.map(\.key) == path.map(\.key) else { return }
            listing = next
            listingPath = requested
            if let returnTo, let i = next.folders.firstIndex(where: { $0.key == returnTo }) { focused = i } else { focused = nil }
            returnTo = nil
        } catch is CancellationError {
            return
        } catch {
            // Only the folder on screen reports its failure.
            guard requested.map(\.key) == path.map(\.key) else { return }
            self.error = (error as? PlexError)?.userMessage ?? "The server couldn’t list this folder."
            listing = nil
        }
        loading = false
    }

    private func count(_ folder: PlexServerClient.FolderListing.Folder) async {
        guard counts[folder.key] == nil, let client = session.client,
              let inside = try? await client.folder(section: section.key, key: folder.key) else { return }
        counts[folder.key] = (inside.folders.count, inside.items.count)
    }

    /// Opens a folder from the list on screen: its path is that list's, even while another
    /// folder is still loading (a click there must not stack siblings in the path).
    private func open(_ folder: PlexServerClient.FolderListing.Folder) { path = listingPath + [folder] }

    private func goUp() {
        guard let leaving = path.popLast() else { return }
        returnTo = leaving.key
    }

    /// ← inside a folder goes up; at the top it returns to the sidebar.
    private func leftEdge() {
        if path.isEmpty { commands.focusSidebar() } else { goUp() }
    }

    private func activateFocused(foldersOnly: Bool) -> KeyPress.Result {
        guard let focused, let listing else { return .ignored }
        if focused < listing.folders.count { open(listing.folders[focused]) }
        else if !foldersOnly { play(listing.items[focused - listing.folders.count]) }
        else { return .ignored }
        return .handled
    }

    private func play(_ item: PlexMetadata) {
        Task { await playback.play(item, from: nil) }
    }
}

private extension View {
    func rowChrome(highlighted: Bool) -> some View {
        self
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(highlighted ? Theme.raised : .clear))
            .contentShape(Rectangle())
    }
}
