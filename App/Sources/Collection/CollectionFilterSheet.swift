import SwiftUI

/// Every way to narrow the collection: sets, rarity, type, domain, price band
/// and the toggles. Edits the model's filter directly so the list behind
/// updates as chips are tapped.
struct CollectionFilterSheet: View {
    let model: CollectionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Set") {
                    ForEach(model.availableSets, id: \.code) { set in
                        Toggle(isOn: setBinding(for: set.code)) {
                            HStack {
                                Text(set.code).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Theme.amber).frame(width: 40, alignment: .leading)
                                Text(set.name)
                            }
                        }
                    }
                }
                Section("Rarity") {
                    chips(CollectionModel.rarities, selection: filterBinding.rarities, color: Theme.rarity)
                }
                Section("Type") {
                    chips(model.availableTypes, selection: filterBinding.types, color: { _ in Theme.muted })
                }
                Section("Domain") {
                    chips(CollectionModel.domains, selection: filterBinding.domains, color: Theme.domain)
                }
                Section("Price, USD market") {
                    HStack {
                        TextField("Min", value: filterBinding.minimumPrice, format: .number)
                            .keyboardType(.decimalPad)
                        Text("to").foregroundStyle(Theme.muted)
                        TextField("Max", value: filterBinding.maximumPrice, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    ScrollView(.horizontal) {
                        HStack {
                            preset("Under $1", 0, 1)
                            preset("$1–5", 1, 5)
                            preset("$5–20", 5, 20)
                            preset("$20–100", 20, 100)
                            preset("$100+", 100, nil)
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                Section {
                    Toggle("Include promos", isOn: filterBinding.includesPromos)
                    Toggle("Only cards with a price", isOn: filterBinding.pricedOnly)
                    Toggle("Hide banned cards", isOn: filterBinding.hidesBanned)
                    Toggle("Search rules text too", isOn: filterBinding.searchesText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .tint(Theme.amber)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        let ownedOnly = model.filter.ownedOnly
                        let sort = model.filter.sort
                        model.filter = CollectionFilter(ownedOnly: ownedOnly, sort: sort)
                    }
                    .disabled(model.filter.activeCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .foregroundStyle(Theme.text)
        .presentationDetents([.large])
    }

    private func chips(_ values: [String], selection: Binding<Set<String>>, color: @escaping (String) -> Color) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(values, id: \.self) { value in
                let isOn = selection.wrappedValue.contains(value)
                Button {
                    if isOn { selection.wrappedValue.remove(value) } else { selection.wrappedValue.insert(value) }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color(value)).frame(width: 8, height: 8)
                        Text(value)
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(isOn ? Theme.text : Theme.surface, in: Capsule())
                    .foregroundStyle(isOn ? Theme.ground : Theme.text)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func preset(_ label: String, _ minimum: Double, _ maximum: Double?) -> some View {
        Button(label) {
            model.filter.minimumPrice = minimum
            model.filter.maximumPrice = maximum
        }
        .buttonStyle(.bordered)
        .font(.footnote)
    }

    private func setBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { model.filter.sets.contains(code) },
            set: { if $0 { model.filter.sets.insert(code) } else { model.filter.sets.remove(code) } }
        )
    }

    private var filterBinding: Binding<CollectionFilter> {
        Binding(get: { model.filter }, set: { model.filter = $0 })
    }
}

/// Wraps its children onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
                x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}
