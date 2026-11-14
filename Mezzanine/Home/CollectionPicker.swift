import SwiftUI
import MezzanineKit

/// Add Shelf ▸ Collection…: every collection of the libraries in scope, filterable by name.
struct CollectionPicker: View {
    let sections: [PlexLibrarySection]
    let pick: (PlexMetadata, String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var all: [(collection: PlexMetadata, section: PlexLibrarySection)] = []
    @State private var query = ""
    @State private var selection: String?
    @State private var loading = true

    private var shown: [(collection: PlexMetadata, section: PlexLibrarySection)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.collection.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Add a Collection").font(Theme.Typeface.cardHeadline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            TextField("Filter collections", text: $query)
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(shown, id: \.collection.ratingKey) { entry in
                    HStack(spacing: Theme.Space.m) {
                        RemoteImage(url: session.posterURL(entry.collection.thumb, pixelWidth: 72), pixelWidth: 72)
                            .frame(width: 24, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.collection.title).font(Theme.Typeface.cardTitle)
                            Text([sections.count > 1 ? entry.section.title : nil,
                                  entry.collection.childCount.map { $0 == 1 ? "1 title" : "\($0) titles" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.Typeface.cardMeta).foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.collection.ratingKey)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { choose(entry.collection.ratingKey) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.raised))
            .overlay {
                if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading collections") }
                else if shown.isEmpty { Text(all.isEmpty ? "No collections in these libraries." : "No collection matches.")
                        .foregroundStyle(Theme.inkSecondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                Button("Add Shelf") { if let selection { choose(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle()).focusEffectDisabled(false)
                    .disabled(selection == nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520, height: 560)
        .presentationBackground(Theme.graphite)
        .task { await load() }
    }

    private func choose(_ key: String) {
        guard let entry = all.first(where: { $0.collection.ratingKey == key }) else { return }
        pick(entry.collection, entry.section.key)
        dismiss()
    }

    private func load() async {
        guard let client = session.client else { return }
        var out: [(PlexMetadata, PlexLibrarySection)] = []
        for section in sections {
            let list = (try? await client.collections(section: section.key)) ?? []
            // Kometa's folder-style parents (no titles of their own) aren't useful as shelves.
            out += list.filter { ($0.childCount ?? 1) > 0 }.map { ($0, section) }
        }
        all = out.sorted { $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending }
        loading = false
    }
}
