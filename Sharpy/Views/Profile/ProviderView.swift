import SwiftUI

/// Choose an AI provider, paste a key, pick a model and test the connection.
/// Shared by onboarding and You → AI provider.
struct ProviderForm: View {
    @EnvironmentObject private var settings: AppSettings
    var onVerified: () -> Void = {}

    private enum Outcome: Equatable {
        case ok
        case failed(String)
    }

    @State private var keyDraft = ""
    @State private var testing = false
    @State private var outcome: Outcome?
    @State private var catalog: [String] = []
    @State private var loadingCatalog = false
    @State private var catalogError: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            providerSection
            keySection
            modelSection
            testSection
        }
        .onChange(of: settings.provider) { _, _ in
            keyDraft = ""
            outcome = nil
            catalog = []
            catalogError = nil
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider").font(.headline)
            ForEach(ProviderKind.allCases) { kind in
                SelectableRow(selected: settings.provider == kind) {
                    settings.provider = kind
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title).font(.headline)
                        Text(kind.blurb).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var keySection: some View {
        let saved = settings.key(for: settings.provider) ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            if settings.provider == .custom {
                Text("Address").font(.headline)
                TextField("https://example.com/v1", text: $settings.customBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(settings.provider.requiresKey ? "API key" : "API key (if the service needs one)").font(.headline)
            if !saved.isEmpty {
                HStack {
                    Label("Saved on this iPhone, ending \(saved.suffix(4))", systemImage: "key.fill")
                        .font(.subheadline)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        settings.setKey(nil, for: settings.provider)
                        outcome = nil
                    }
                    .font(.subheadline)
                }
            }
            SecureField(saved.isEmpty ? "Paste your key" : "Paste a new key to replace it", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            if let page = settings.provider.keyPage {
                Link("Get a key from \(settings.provider.title)", destination: page).font(.subheadline)
            }
            Text("Your key stays in this iPhone's Keychain and is sent only to \(host). What you use is billed to your account with them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var host: String {
        URL(string: settings.baseURL)?.host ?? "your provider"
    }

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model").font(.headline)
            if settings.provider == .anthropic {
                ForEach(ClaudeModel.all) { model in
                    SelectableRow(selected: settings.model == model.id) {
                        settings.model = model.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).font(.headline)
                            Text("\(model.note) · \(model.priceLabel)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                TextField("Model name", text: $settings.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                Text("Use a capable model that can return JSON. Sharpy reads Wikipedia itself and checks every quote, so the model doesn't need web access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                catalogView
            }
        }
    }

    @ViewBuilder
    private var catalogView: some View {
        if catalog.isEmpty {
            Button {
                Task { await loadCatalog() }
            } label: {
                HStack(spacing: 8) {
                    if loadingCatalog { ProgressView().controlSize(.small) }
                    Text(loadingCatalog ? "Loading models…" : "Browse models")
                }
            }
            .disabled(loadingCatalog)
            if let catalogError {
                Text(catalogError).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            TextField("Search \(catalog.count) models", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            let matches = catalog.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.prefix(40)
            VStack(spacing: 0) {
                ForEach(Array(matches), id: \.self) { id in
                    Button {
                        settings.model = id
                    } label: {
                        HStack {
                            Text(id).font(.subheadline).lineLimit(1)
                            Spacer()
                            if settings.model == id { Image(systemName: "checkmark").foregroundStyle(Palette.brand) }
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 8) {
                    if testing { ProgressView().tint(.white) }
                    Text(testing ? "Testing…" : "Save and test")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(testing)
            switch outcome {
            case .some(.ok):
                Label("Connected to \(settings.providerConfig?.displayName ?? settings.provider.title).",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.correct)
            case .some(.failed(let message)):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.wrong)
            case .none:
                EmptyView()
            }
        }
    }

    private func saveDraftKey() {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        settings.setKey(draft, for: settings.provider)
        keyDraft = ""
    }

    private func test() async {
        saveDraftKey()
        guard let config = settings.providerConfig else {
            outcome = .failed(missingPiece)
            return
        }
        testing = true
        defer { testing = false }
        do {
            try await LLMClient(config: config).validate()
            outcome = .ok
            onVerified()
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    private var missingPiece: String {
        if settings.provider.requiresKey && (settings.key(for: settings.provider) ?? "").isEmpty {
            return "Paste your API key first."
        }
        if URL(string: settings.baseURL)?.host == nil { return "Enter the service's address, starting with https://." }
        return "Choose a model first."
    }

    private func loadCatalog() async {
        saveDraftKey()
        guard let url = URL(string: settings.baseURL), url.host != nil else {
            catalogError = "Enter the service's address first."
            return
        }
        loadingCatalog = true
        defer { loadingCatalog = false }
        let config = ProviderConfig(kind: settings.provider, baseURL: url, model: settings.model,
                                    key: settings.key(for: settings.provider) ?? "")
        do {
            catalog = try await LLMClient(config: config).listModels()
            catalogError = catalog.isEmpty ? "This service didn't list any models. Type the model name instead." : nil
        } catch {
            catalogError = "Couldn't load the model list. Type the model name instead."
        }
    }
}

struct ProviderSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProviderForm()
                UsageSummary()
            }
            .padding(16)
        }
        .background(Palette.page)
        .navigationTitle("AI provider")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What this phone asked of the provider this month, and roughly what it cost.
struct UsageSummary: View {
    var body: some View {
        let usage = UsageStore.thisMonth()
        VStack(alignment: .leading, spacing: 10) {
            Text("This month").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Tokens sent", usage.inputTokens.formatted())
                row("Tokens received", usage.outputTokens.formatted())
                if usage.searches > 0 { row("Web searches", usage.searches.formatted()) }
                row("Estimated cost", cost(usage))
            }
            Text("Estimated from list prices; your provider's bill is the real number. To protect it, Sharpy makes at most \(UsageStore.dailyBatchCap) question sets a day.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func cost(_ usage: UsageTotals) -> String {
        let dollars = usage.dollars.formatted(.currency(code: "USD"))
        if usage.costComplete { return dollars }
        return usage.dollars > 0 ? "\(dollars) + unpriced requests" : "Not reported by this provider"
    }
}
