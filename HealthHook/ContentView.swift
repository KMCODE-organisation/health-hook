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
                        Text("Sends when Apple Health gets new data, even when the app is closed (at most every few minutes; not while the iPhone is locked). Pull down to send now and ask Home Assistant for a summary, if set up.")
                        if let end = SigningProfile.expiration {
                            Text("App valid until \(end.formatted(date: .abbreviated, time: .shortened)).")
                        }
                    }
                }

                if let values = sync.last {
                    Section("Last sent") {
                        ForEach(Catalog.metrics) { m in
                            if let v = values[m.id] {   // key present = metric selected (value may be null)
                                row(m.localizedTitle, v.map(m.format))
                                if m.minMax, let mn = values[m.id + "_min"] ?? nil, let av = values[m.averageKey] ?? nil,
                                   let mx = values[m.id + "_max"] ?? nil {
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
            .alert("Use this Home Assistant?", isPresented: Binding(
                get: { sync.proposedURL != nil },
                set: { if !$0 { sync.dismissProposal() } }
            ), presenting: sync.proposedURL) { url in
                Button("Use it") { sync.saveURL(url) }
                Button("Cancel", role: .cancel) { sync.dismissProposal() }
            } message: { url in
                Text("Your Health data will be sent to \(URL(string: url)?.host() ?? url). Only accept a link that comes from your own Home Assistant.")
            }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value ?? "—")
    }
}
