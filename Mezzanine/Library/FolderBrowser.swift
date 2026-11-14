import SwiftUI
import MezzanineKit

/// Browses a personal-media library (Courses) by its folders on disk:
/// course → section → lesson. Breadcrumbs go back up; arrow keys move,
/// Return opens a folder or plays a lesson, Delete or ⌘↑ goes up a level.
struct FolderBrowser: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [PlexServerClient.FolderListing.Folder] = []
    @State private var listing: PlexServerClient.FolderListing?
    @State private var error: String?
    @State private var focused: Int?
    @State private var hovered: Int?

    private var rowCount: Int { (listing?.folders.count ?? 0) + (listing?.items.count ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !path.isEmpty {
                breadcrumbs
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, Theme.Space.l)
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
                    .padding(.horizontal, Theme.Space.gutter - Theme.Space.m)
                    .padding(.top, path.isEmpty ? Theme.Space.l : 0)
                    .padding(.bottom, Theme.Space.xl)
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
            } else if rowCount == 0 {
                RoomMessage(title: "This folder is empty", detail: nil)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand { direction in
            guard rowCount > 0 else { return }
            switch direction {
            case .up: focused = max(0, (focused ?? 0) - 1)
            case .down: focused = min(rowCount - 1, (focused ?? -1) + 1)
            case .left: goUp()
            default: break
            }
        }
        .onKeyPress(.return) { activateFocused() }
        .onKeyPress(.space) { activateFocused() }
        .onKeyPress(.delete) { goUp(); return .handled }
        .task(id: path.last?.key ?? "root") { await load() }
    }

    // MARK: Parts

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            crumb(section.title, enabled: !path.isEmpty) { path = [] }
            ForEach(Array(path.enumerated()), id: \.element.id) { i, folder in
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                crumb(folder.title, enabled: i < path.count - 1) { path = Array(path.prefix(i + 1)) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    private func crumb(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(enabled ? Theme.Typeface.caption : Theme.Typeface.shelfTitle)
                .foregroundStyle(enabled ? Theme.inkSecondary : Theme.ink)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .focusEffectDisabled(false)
    }

    private func folderRow(_ folder: PlexServerClient.FolderListing.Folder, index: Int) -> some View {
        row(index: index, action: { open(folder) }) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(Theme.inkSecondary).frame(width: 40)
            Text(folder.title).font(Theme.Typeface.cardTitle).foregroundStyle(focused == index ? Theme.lilac : Theme.ink).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityLabel("Folder \(folder.title)")
    }

    private func lessonRow(_ item: PlexMetadata, index: Int) -> some View {
        row(index: index, action: { play(item) }) {
            Image(systemName: item.isWatched ? "checkmark.circle.fill" : (item.progress != nil ? "circle.lefthalf.filled" : "play.circle"))
                .font(.system(size: 18)).foregroundStyle(item.isWatched ? Theme.inkTertiary : Theme.inkSecondary).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.Typeface.cardTitle).foregroundStyle(focused == index ? Theme.lilac : Theme.ink).lineLimit(1)
                Text([item.duration.map(Format.duration), Format.timeLeft(item)].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if hovered == index || focused == index { PlayDisc { play(item) } }
        }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isWatched ? "Watched" : (item.progress.map { "\(Int($0 * 100)) percent watched" } ?? ""))
    }

    private func row<Content: View>(index: Int, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.m) { content() }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(focused == index || hovered == index ? Theme.raised : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
            .simultaneousGesture(TapGesture().onEnded { focused = index })
            .simultaneousGesture(TapGesture(count: 2).onEnded(action))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    // MARK: Actions

    private func load() async {
        guard let client = session.client else { return }
        listing = nil
        error = nil
        focused = nil
        do {
            listing = try await client.folder(section: section.key, key: path.last?.key)
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "\(error)"
        }
    }

    private func open(_ folder: PlexServerClient.FolderListing.Folder) { path.append(folder) }

    private func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func activateFocused() -> KeyPress.Result {
        guard let focused, let listing else { return .ignored }
        if focused < listing.folders.count { open(listing.folders[focused]) }
        else { play(listing.items[focused - listing.folders.count]) }
        return .handled
    }

    private func play(_ item: PlexMetadata) {
        Task { await playback.play(item, from: nil) }
    }
}
