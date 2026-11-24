import SwiftUI

/// Choice of the Health data sent to the webhook. Selected = key always sent (`null` without data);
/// unselected = key absent (Home Assistant keeps the last value).
struct MetricsView: View {
    @EnvironmentObject private var sync: Sync

    var body: some View {
        List {
            ForEach(Category.allCases) { category in
                Section(category.title) {
                    ForEach(Catalog.metrics.filter { $0.category == category }) { m in
                        Toggle(isOn: Binding(
                            get: { sync.selected.contains(m.id) },
                            set: { sync.toggle(m.id, on: $0) }
                        )) {
                            VStack(alignment: .leading) {
                                Text(m.localizedTitle)
                                Text(verbatim: m.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Data to send")
        .toolbar {
            Menu("Selection", systemImage: "checklist") {
                Button("Select all") { sync.select(Set(Catalog.metrics.map(\.id))) }
                Button("Deselect all") { sync.select([]) }
                Button("Defaults") { sync.select(Catalog.defaults) }
            }
        }
    }
}
