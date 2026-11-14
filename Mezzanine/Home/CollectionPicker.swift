import SwiftUI
import MezzanineKit

/// Add Shelf ▸ Collection…: every collection of the libraries in scope, filterable by name.
/// Typing filters and keeps the first match selected; ↓/↑ move through the list from the field;
/// Return (or a double-click) adds it.
struct CollectionPicker: View {
    let sections: [PlexLibrarySection]
    /// Collections already on this page (left out of the list).
    let existing: Set<String>
    let pick: (PlexMetadata, String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var all: [Entry] = []
    @State private var query = ""
    @State private var selection: String?
    @State private var loading = true
    @State private var failed: String?
    @FocusState private var fieldFocused: Bool

    struct Entry: Identifiable {
        let collection: PlexMetadata
        let section: PlexLibrarySection
        var id: String { collection.ratingKey }
    }

    private var shown: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.collection.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Add a Collection").font(Theme.Typeface.cardHeadline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            TextField("Filter collections", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onKeyPress(keys: [.downArrow, .upArrow]) { press in
                    step(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                .onSubmit { if let selection { choose(selection) } }
            List(selection: $selection) {
                ForEach(shown) { entry in
                    HStack(spacing: Theme.Space.m) {
                        RemoteImage(url: session.posterURL(entry.collection.thumb, pixelWidth: 72), pixelWidth: 72)
                            .frame(width: 24, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.collection.title).font(Theme.Typeface.cardTitle)
                            Text(caption(entry)).font(Theme.Typeface.cardMeta).foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.id)
                    .accessibilityElement(children: .combine)
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { choose(id) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.raised))
            .overlay(alignment: .topLeading) { state }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                Button("Add Shelf") { if let selection { choose(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle()).focusEffectDisabled(false)
                    .disabled(!shown.contains { $0.id == selection })
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520, height: 560)
        .presentationBackground(Theme.graphite)
        .task { await load() }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selection = shown.first?.id }
    }

    /// Loading, failure and empty states, on the list's own gutter (never centred).
    @ViewBuilder private var state: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small).accessibilityLabel("Loading collections")
            } else if let failed {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(failed).foregroundStyle(Theme.inkSecondary)
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                }
            } else if shown.isEmpty {
                Text(all.isEmpty ? "Every collection here is already a shelf." : "No collection matches “\(query)”.")
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .font(Theme.Typeface.body)
        .padding(Theme.Space.l)
    }

    private func caption(_ entry: Entry) -> String {
        [sections.count > 1 ? entry.section.title : nil,
         entry.collection.childCount.map { $0 == 1 ? "1 title" : "\($0) titles" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func step(_ delta: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : list.count)
        selection = list[min(max(0, i + delta), list.count - 1)].id
    }

    private func choose(_ key: String) {
        guard let entry = all.first(where: { $0.id == key }) else { return }
        pick(entry.collection, entry.section.key)
        dismiss()
    }

    private func load() async {
        guard let client = session.client else {
            loading = false
            failed = "Not connected to the server yet."
            return
        }
        loading = true
        failed = nil
        var out: [Entry] = []
        do {
            for section in sections {
                let list = try await client.collections(section: section.key)
                // Kometa's folder-style parents (no titles of their own) aren't useful as shelves.
                out += list.filter { ($0.childCount ?? 1) > 0 && !existing.contains($0.ratingKey) }
                    .map { Entry(collection: $0, section: section) }
            }
            all = out.sorted { $0.collection.title.localizedCaseInsensitiveCompare($1.collection.title) == .orderedAscending }
            selection = shown.first?.id
        } catch {
            failed = (error as? PlexError)?.userMessage ?? "The collections didn’t load."
        }
        loading = false
    }
}
