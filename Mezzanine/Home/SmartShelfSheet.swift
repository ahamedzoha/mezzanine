import SwiftUI
import MezzanineKit

/// The smart-shelf rule sheet: a name, which libraries, rule rows (every one must hold),
/// sort and size, and a live preview the local index answers as you change anything.
struct SmartShelfSheet: View {
    /// The shelf being edited; nil makes a new one.
    let existing: ShelfSpec?
    let scope: String
    let sections: [PlexLibrarySection]
    let save: (ShelfSpec) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rule = SmartRule()
    @State private var preview: [PlexMetadata] = []
    @State private var count = 0
    @State private var genres: [String] = []
    @State private var collections: [String] = []
    /// The rules with stable identities, so removing a middle row keeps the others' state.
    @State private var rows: [RuleItem] = []
    @State private var previewTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    struct RuleItem: Identifiable, Equatable {
        let id = UUID()
        var condition: SmartCondition
    }

    private static let limits = [12, 24, 48, 96]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(existing == nil ? "New Smart Shelf" : "Edit Smart Shelf")
                .font(Theme.Typeface.cardHeadline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                GridRow {
                    label("Name")
                    TextField("Name", text: $name, prompt: Text(rule.summary))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .focused($nameFocused)
                }
                GridRow {
                    label("From")
                    HStack(spacing: Theme.Space.s) {
                        Picker("Libraries", selection: Binding(get: { rule.sections.first ?? "" },
                                                               set: { rule.sections = $0.isEmpty ? [] : [$0] })) {
                            Text("All libraries").tag("")
                            ForEach(sections) { Text($0.title).tag($0.key) }
                        }
                        Picker("Show", selection: $rule.kinds) {
                            Text("Movies and shows").tag([String]())
                            Text("Movies").tag(["movie"])
                            Text("Shows").tag(["show"])
                            Text("Episodes").tag(["episode"])
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Titles that match all of these")
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                ScrollView {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                            RuleRow(number: i + 1,
                                    condition: Binding(get: { item.condition },
                                                       set: { new in if let j = rows.firstIndex(where: { $0.id == item.id }) { rows[j].condition = new } }),
                                    genres: genres, collections: collections,
                                    remove: { rows.removeAll { $0.id == item.id } },
                                    addAfter: {
                                        if let j = rows.firstIndex(where: { $0.id == item.id }) {
                                            rows.insert(RuleItem(condition: .watch(.unwatched)), at: j + 1)
                                        }
                                    })
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                if rows.isEmpty {
                    Button { rows.append(RuleItem(condition: .watch(.unwatched))) } label: {
                        Label("Add a Rule", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
                }
            }

            HStack(spacing: Theme.Space.l) {
                Picker("Sort by", selection: $rule.sort) {
                    ForEach(LibraryQuery.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Picker("Show up to", selection: $rule.limit) {
                    ForEach(Self.limits, id: \.self) { Text("\($0) titles").tag($0) }
                }
                .fixedSize()
            }

            Rectangle().fill(Theme.rule).frame(height: 1)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(countLine)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .contentTransition(.numericText())
                    .accessibilityLabel(count == 1 ? "1 title matches" : "\(count) titles match")
                    .accessibilityAddTraits(.updatesFrequently)
                HStack(spacing: Theme.Space.s) {
                    ForEach(preview, id: \.ratingKey) { item in
                        RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 128), pixelWidth: 128)
                            .frame(width: 52, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .help(item.title)
                    }
                    if preview.isEmpty {
                        Text("Nothing in your library matches yet.")
                            .font(Theme.Typeface.body).foregroundStyle(Theme.inkTertiary)
                            .frame(height: 78, alignment: .leading)
                    }
                }
                .accessibilityHidden(true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
                Button(existing == nil ? "Add Shelf" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .focusEffectDisabled(false)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 680)
        .presentationBackground(Theme.graphite)
        .onAppear(perform: start)
        .onChange(of: rows) { _, new in rule.conditions = new.map(\.condition) }
        .onChange(of: rule) { _, _ in
            // Debounced: typing a name or a year shouldn't query on every keystroke.
            previewTask?.cancel()
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                refreshPreview()
            }
        }
        .onChange(of: rule.sections) { _, _ in loadOptions() }
    }

    /// "38 titles", or "24 of 1,145 titles" when the shelf's size cuts it short.
    private var countLine: String {
        let total = count.formatted()
        if rule.limit > 0, count > rule.limit { return "\(rule.limit) of \(total) titles" }
        return count == 1 ? "1 title" : "\(total) titles"
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary).gridColumnAlignment(.trailing)
    }

    private func start() {
        if let existing, let r = existing.smartRule {
            rule = r
            name = existing.title == r.summary ? "" : existing.title
        } else {
            rule = SmartRule(sections: scope == HomeLayout.mainScope ? [] : [scope], conditions: [.watch(.unwatched)])
        }
        rows = rule.conditions.map { RuleItem(condition: $0) }
        loadOptions()
        refreshPreview()
        #if DEBUG
        // Captures: the field's suggestion pop-up blocks window snapshots.
        if UserDefaults.standard.bool(forKey: "SheetNoAutoFocus") { return }
        #endif
        nameFocused = true
    }

    /// Genres and collections of the libraries the shelf draws from.
    private func loadOptions() {
        guard let index = library.index else { return }
        genres = (try? index.genres(sections: rule.sections)) ?? []
        collections = (try? index.collectionNames(sections: rule.sections)) ?? []
    }

    private func refreshPreview() {
        guard let index = library.index else { return }
        count = (try? index.count(rule)) ?? 0
        preview = ((try? index.items(rule, limit: 10)) ?? []).compactMap { $0.metadata() }
    }

    private func commit() {
        var spec = existing ?? ShelfSpec(source: .smart(rule))
        spec.source = .smart(rule)
        spec.title = name.trimmingCharacters(in: .whitespaces)
        save(spec)
        dismiss()
    }
}

/// One rule: a field, its value, and − / + to remove it or add one after it.
private struct RuleRow: View {
    let number: Int
    @Binding var condition: SmartCondition
    let genres: [String]
    let collections: [String]
    let remove: () -> Void
    let addAfter: () -> Void

    private static let decades = Array(stride(from: 2020, through: 1920, by: -10))
    private static let addedDays = [7, 30, 90, 180, 365]
    private static let ratings: [Double] = [6, 7, 7.5, 8, 8.5, 9]

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Picker("Field", selection: Binding(get: { condition.field },
                                               set: { if $0 != condition.field { condition = $0.defaultCondition } })) {
                ForEach(SmartCondition.Field.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            value
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .help("Remove this rule")
                .accessibilityLabel("Remove rule \(number), \(condition.label)")
            Button(action: addAfter) { Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .help("Add a rule after this one")
                .accessibilityLabel("Add a rule after rule \(number)")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.raised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rule \(number): \(condition.field.label)")
    }

    @ViewBuilder private var value: some View {
        switch condition {
        case .genre(let g, let excluded):
            Picker("Match", selection: Binding(get: { excluded }, set: { condition = .genre(g, excluded: $0) })) {
                Text("is").tag(false)
                Text("is not").tag(true)
            }
            .labelsHidden().fixedSize()
            Picker("Genre", selection: Binding(get: { g }, set: { condition = .genre($0, excluded: excluded) })) {
                ForEach(options(genres, including: g), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .decade(let d):
            Picker("Decade", selection: Binding(get: { d }, set: { condition = .decade($0) })) {
                ForEach(Self.decades, id: \.self) { Text("the \(String($0))s").tag($0) }
            }
            .labelsHidden().fixedSize()
        case .years(let a, let b):
            Text("between").foregroundStyle(Theme.inkSecondary)
            TextField("From", value: Binding(get: { a }, set: { condition = .years(from: $0, to: b) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 64)
            Text("and").foregroundStyle(Theme.inkSecondary)
            TextField("To", value: Binding(get: { b }, set: { condition = .years(from: a, to: $0) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 64)
        case .watch(let w):
            Picker("State", selection: Binding(get: { w }, set: { condition = .watch($0) })) {
                ForEach(SmartCondition.WatchState.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .addedWithin(let days):
            Picker("Added", selection: Binding(get: { days }, set: { condition = .addedWithin(days: $0) })) {
                ForEach(Self.addedDays, id: \.self) { Text($0 == 365 ? "in the last year" : "in the last \($0) days").tag($0) }
            }
            .labelsHidden().fixedSize()
        case .minRating(let r):
            Picker("Rating", selection: Binding(get: { r }, set: { condition = .minRating($0) })) {
                ForEach(Self.ratings, id: \.self) { Text(String(format: "%g or higher", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .resolution(let r):
            Picker("Resolution", selection: Binding(get: { r }, set: { condition = .resolution($0) })) {
                ForEach(ResolutionLabel.all, id: \.self) { Text(ResolutionLabel.label($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .hdr:
            Text("is HDR or Dolby Vision").foregroundStyle(Theme.inkSecondary)
        case .minChannels(let c):
            Picker("Audio", selection: Binding(get: { c }, set: { condition = .minChannels($0) })) {
                Text("5.1 or more").tag(6)
                Text("7.1").tag(8)
            }
            .labelsHidden().fixedSize()
        case .collection(let c):
            Picker("Collection", selection: Binding(get: { c }, set: { condition = .collection($0) })) {
                if c.isEmpty { Text("Choose…").tag("") }
                ForEach(options(collections, including: c), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .person(let p):
            TextField("Name, as on the server", text: Binding(get: { p }, set: { condition = .person($0) }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        }
    }

    /// The list, with the current value kept even when this library doesn't have it.
    private func options(_ list: [String], including value: String) -> [String] {
        value.isEmpty || list.contains(value) ? list : [value] + list
    }
}
