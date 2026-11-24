import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sync: Sync
    @State private var input = ""
    @State private var editing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        if sync.sending { ProgressView() }
                        Text(sync.status)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sends on every launch. Pull down to send again (and ask Home Assistant for a summary, if set up).")
                        if let end = SigningProfile.expiration {
                            Text("App valid until \(end.formatted(date: .abbreviated, time: .shortened)).")
                        }
                    }
                }

                if let p = sync.last {
                    Section("Last sent") {
                        ForEach(Catalog.metrics) { m in
                            if let v = p.values[m.id] {   // key present = metric selected (value may be null)
                                row(m.localizedTitle, v.map(m.format))
                                if m.minMax, let mn = p.values[m.id + "_min"] ?? nil, let av = p.values[m.averageKey] ?? nil,
                                   let mx = p.values[m.id + "_max"] ?? nil {
                                    row(String(localized: "\(m.localizedTitle) today (min / avg / max)"),
                                        "\(m.format(mn)) / \(m.format(av)) / \(m.format(mx))")
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("Data to send") { MetricsView() }
                } footer: {
                    Text("\(String(sync.selected.count)) selected.")
                }

                Section {
                    Button(sync.importing ? "Importing…" : "Send 1 year of history") {
                        Task { await sync.importHistory() }
                    }
                    .disabled(sync.importing || sync.sending || !sync.urlConfigured)
                } header: {
                    Text("Home Assistant journal")
                } footer: {
                    Text("Once at the start, or after selecting new data: sends the last 12 months, day by day, to the Home Assistant journal. Sensors are not changed.")
                }

                Section("Home Assistant webhook") {
                    if !sync.urlConfigured || editing {
                        TextField("https://…/api/webhook/…", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Save") {
                            sync.saveURL(input)
                            input = ""
                            editing = false
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        LabeledContent("URL", value: String(localized: "configured"))
                        Button("Change") { editing = true }
                    }
                }
            }
            .navigationTitle("Health Hook")
            .refreshable { await sync.send(.manual, force: true) }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value ?? "—")
    }
}
