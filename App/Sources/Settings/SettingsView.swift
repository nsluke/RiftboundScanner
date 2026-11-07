import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            serverSection
            connectionSection
            learningSection
            storageSection
            aboutSection
        }
        .navigationTitle("Settings")
        .task { await model.load() }
    }

    private var serverSection: some View {
        Section {
            if model.isLoaded {
                TextField("Fallback address", text: $model.manualEndpointText, prompt: Text("192.168.1.155:8096"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Fallback server address")
                SecureField("Write token", text: $model.token, prompt: Text("Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Server write token")
                if !model.endpointIsValid {
                    Label("Enter a host or address such as 192.168.1.155:8096.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let problem = model.saveProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("Save") { Task { await model.save() } }
                    .disabled(!model.endpointIsValid)
            } else {
                ProgressView("Loading settings…")
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The app looks for riftbound.lan, then riftbound.local, then this address, over Wi-Fi or your home VPN. The token is kept in the Keychain and sent only when the server asks for one.")
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            switch model.connection {
            case .idle:
                Text("Not tested yet.")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView("Testing…")
            case .loaded(let connection):
                ConnectionDetails(connection: connection)
            case .failed(let error):
                Label(error.message, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.testConnection() }
            } label: {
                Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(isTesting)
        }
    }

    private var isTesting: Bool {
        if case .loading = model.connection { return true }
        return false
    }

    /// The confident tier as the server measures it (ADR-002, decision 9):
    /// the Wilson lower bound over random audits, with the audit rate in force.
    @ViewBuilder
    private var learningSection: some View {
        Section {
            switch model.learning {
            case .idle, .loading:
                ProgressView("Loading precision…")
            case .failed(let error):
                Label(error == .notFound ? String(localized: "The server does not report learning stats yet.") : error.message, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Precision unavailable: \(error.message)")
            case .loaded(let stats):
                LearningCard(stats: stats, rule: model.rule)
            }
            Button {
                Task { await model.refreshLearning() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshingLearning)
        } header: {
            Text("Learning")
        } footer: {
            Text("Scans accepted without a look are audited at random; the bound is the precision the audits so far guarantee at 95 % confidence. Spot-checks are recorded but never counted.")
        }
    }

    private var isRefreshingLearning: Bool {
        if case .loading = model.learning { return true }
        return false
    }

    @ViewBuilder
    private var storageSection: some View {
        if let storage = model.storage {
            Section {
                LabeledContent("Sync state", value: storage.syncBytes.formatted(.byteCount(style: .file)))
                LabeledContent("Learning", value: storage.learningBytes.formatted(.byteCount(style: .file)))
                LabeledContent("Catalog cache", value: storage.catalogBytes.formatted(.byteCount(style: .file)))
            } header: {
                Text("Storage")
            } footer: {
                Text("Kept out of backups; everything here is rebuilt from the server or from your scans.")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: model.appVersion)
            LabeledContent("Card index", value: "\(model.index.entryCount) printings, built \(model.index.builtAt.formatted(date: .abbreviated, time: .omitted))")
        }
    }
}

/// The `/health` fields of a server that answered, with the schema warning
/// when it is older than the app needs.
struct ConnectionDetails: View {
    let connection: SettingsModel.Connection

    var body: some View {
        let health = connection.health
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.endpoint.url.host() ?? connection.endpoint.url.absoluteString)
                    .font(.headline)
                Text(endpointKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: connection.isSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(connection.isSupported ? Color.green : Color.orange)
        }
        .accessibilityElement(children: .combine)
        if !connection.isSupported {
            Text("Server needs updating: schema version \(health.userVersion ?? 0), the app needs \(HealthReport.minimumUserVersion). Run the deploy script on the Pi.")
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityLabel("Server needs updating")
        }
        if let cards = health.cards {
            LabeledContent("Cards", value: cards.formatted())
        }
        if let catalogVersion = health.catalogVersion {
            LabeledContent("Catalog version", value: String(catalogVersion.prefix(12)))
        }
        if let userVersion = health.userVersion {
            LabeledContent("Schema", value: "v\(userVersion)" + (health.apiVersion.map { ", API \($0)" } ?? ""))
        }
        if let version = health.version {
            LabeledContent("Server", value: version)
        }
        if let lastBackupAt = health.lastBackupAt {
            LabeledContent("Last backup", value: lastBackupAt)
        }
        if let freeDiskMB = health.freeDiskMB {
            LabeledContent("Free disk", value: "\(Int(freeDiskMB)) MB")
        }
        if let rssMB = health.rssMB {
            LabeledContent("Memory", value: "\(Int(rssMB)) MB")
        }
        if let scansStored = health.scansStored {
            LabeledContent("Scans stored", value: scansStored.formatted())
        }
        if let exemplars = health.exemplars {
            LabeledContent("Exemplars", value: exemplars.formatted())
        }
        if let warnings = health.catalogWarnings, !warnings.isEmpty {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var endpointKind: String {
        switch connection.endpoint.kind {
        case .lan: String(localized: "riftbound.lan (UniFi name, works over the VPN)")
        case .local: String(localized: "riftbound.local (mDNS, home Wi-Fi)")
        case .manual: String(localized: "Fallback address")
        }
    }
}

/// The precision bound and audit counts from `/api/learning/stats`.
struct LearningCard: View {
    let stats: LearningStats
    let rule: ConfidenceRule

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
        }
        .accessibilityElement(children: .combine)
        LabeledContent("Audit rate", value: rule.auditRate.formatted(.percent.precision(.fractionLength(0))))
        if let spotChecks = stats.spotChecks {
            LabeledContent("Spot-checks", value: "\(spotChecks.formatted()), not counted")
        }
        if let exemplars = stats.exemplars {
            LabeledContent("Exemplars", value: exemplars.formatted())
        }
        if let humanLabels = stats.humanLabels {
            LabeledContent("Human labels", value: "\(humanLabels.formatted())" + (stats.sittings.map { " over \($0) sittings" } ?? ""))
        }
    }

    /// "precision >= 98.1 % (95 %)", as the ADR words it.
    static func precisionText(_ stats: LearningStats) -> String? {
        guard let bound = stats.wilsonLowerBound else { return nil }
        let level = (stats.confidenceLevel ?? 0.95).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Precision ≥ \(bound.formatted(.percent.precision(.fractionLength(1)))) (\(level))")
    }

    private var headline: String {
        Self.precisionText(stats) ?? String(localized: "No audits yet")
    }

    private var detail: String {
        if stats.wilsonLowerBound == nil {
            return String(localized: "The bound appears once a confident scan has been audited.")
        }
        var parts = [String(localized: "\(stats.randomAudits) random audits")]
        if let wrong = stats.randomAuditsWrong {
            parts.append(String(localized: "\(wrong) wrong"))
        }
        if let unresolved = stats.unresolvedWrongAudits, unresolved > 0 {
            parts.append(String(localized: "\(unresolved) unresolved"))
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        switch stats.isHealthy {
        case true: "checkmark.shield.fill"
        case false: "exclamationmark.shield.fill"
        case nil: "shield"
        }
    }

    private var symbolColor: Color {
        switch stats.isHealthy {
        case true: .green
        case false: .orange
        case nil: .secondary
        }
    }
}
