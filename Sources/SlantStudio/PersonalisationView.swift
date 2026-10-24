import SwiftUI
import AppKit

/// Sections of the form: consecutive parameters sharing a Customizer group, in template order.
func personalisationSections(_ parameters: [ScadParameter]) -> [(title: String?, parameters: [ScadParameter])] {
    var sections: [(title: String?, parameters: [ScadParameter])] = []
    for parameter in parameters {
        if let last = sections.last, last.title == parameter.group {
            sections[sections.count - 1].parameters.append(parameter)
        } else {
            sections.append((parameter.group, [parameter]))
        }
    }
    return sections
}

/// The first value that can't be used, or nil when every value is fine.
func personalisationValuesProblem(_ parameters: [ScadParameter], values: [String: String]) -> String? {
    for parameter in parameters {
        if let problem = scadValueProblem(values[parameter.name] ?? parameter.defaultValue, for: parameter) { return problem }
    }
    return nil
}

let personalisationPrivacyNote = "Values aren’t kept in Studio, but the new model’s name and STL include them. With Slant’s generator, the template and values are sent to Slant."

/// How long the Personalise sheet waits before checking the Slant quota again: just after the next generation becomes
/// available, but at least a second and at most 30 seconds, so the button and captions catch up on their own.
func personalisationQuotaRefreshDelay(nextAvailable: Date?, now: Date) -> TimeInterval {
    guard let nextAvailable else { return 30 }
    return min(30, max(1, nextAvailable.timeIntervalSince(now) + 0.5))
}

/// One item's personalisation in the Import Orders preview, with Copy for pasting into Personalise from Template.
/// The text stays in the sheet's memory; copying puts it on the clipboard only when the seller asks.
struct OrderImportPersonalisationRow: View {
    let item: OrderImportItem
    let showsItemName: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                let name = showsItemName && !item.itemName.isEmpty ? " (\(item.itemName))" : ""
                Text("Personalisation\(name): “\(item.personalisation)”")
                    .font(.caption).lineLimit(3).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.personalisation, forType: .string)
                    copied = true
                }
                .buttonStyle(.link).font(.caption)
                .help("Copies the buyer’s personalisation to paste into Personalise from Template. Studio doesn’t save it.")
                .accessibilityLabel("Copy personalisation")
            }
            if orderImportPersonalisationShowsOptions(item) {
                Text("Options: \(item.options)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// The Import Orders note about personalisation, with Copy All (the list is lost once the sheet closes).
struct OrderImportPersonalisationNotice: View {
    let list: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(orderImportPersonalisationNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy All Personalisation") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(list, forType: .string)
                copied = true
            }
            .buttonStyle(.link).font(.caption)
            .help("Copies each order ID with its personalisation (no names or addresses), so you can keep the list after closing this window.")
        }
    }
}

/// Personalise from Template: fill in a .scad template's values and generate a new library model.
struct PersonalisationSheet: View {
    @EnvironmentObject var store: StudioStore

    var body: some View {
        if let file = store.personalisationTemplate {
            PersonalisationForm(file: file).id(file.id)
        }
    }
}

private struct PersonalisationForm: View {
    let file: PersonalisationTemplateFile
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var session = PersonalisationSession.shared
    @State private var values: [String: String]
    @State private var engine: PersonalisationEngine = .slant
    @State private var localExecutable: URL?
    /// False until OpenSCAD has been looked for once, when the sheet appears (not on every redraw).
    @State private var lookedForOpenSCAD = false
    /// The time the quota is judged against, moved on by a timer so a reset re-enables Generate STL.
    @State private var now = Date()
    @State private var generating = false
    @State private var job: Task<Void, Never>?
    @State private var status: String?
    @State private var problem: String?

    init(file: PersonalisationTemplateFile) {
        self.file = file
        _values = State(initialValue: Dictionary(file.template.parameters.map { ($0.name, $0.defaultValue) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Looks for OpenSCAD in Applications. The first look also picks the default engine; Check Again keeps the choice.
    private func lookForOpenSCAD() {
        localExecutable = installedOpenSCADExecutable()
        if !lookedForOpenSCAD {
            engine = personalisationDefaultEngine(localAvailable: localExecutable != nil)
            lookedForOpenSCAD = true
        }
    }

    private var parameters: [ScadParameter] { file.template.parameters }

    private func blockedReason(now: Date) -> String? {
        personalisationEngineBlockedReason(engine, localAvailable: localExecutable != nil, hasKey: store.hasKey,
                                           template: file.template, sourceBytes: file.source.utf8.count,
                                           quota: session.quota, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Personalise from template").font(.title2.weight(.bold))
                Text("Fill in the OpenSCAD template’s values, such as a buyer’s name, and generate an STL. It’s saved as a new model in your library.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            Form {
                templateSection
                ForEach(Array(personalisationSections(parameters).enumerated()), id: \.offset) { _, section in
                    Section(section.title ?? "Values") {
                        ForEach(section.parameters) { parameter in field(parameter) }
                    }
                }
                engineSection
            }
            .formStyle(.grouped)
            .disabled(generating)
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 480, idealHeight: 660)
        .interactiveDismissDisabled(generating)
        .onAppear { if !lookedForOpenSCAD { lookForOpenSCAD() } }
        .task {
            while !Task.isCancelled {
                let delay = personalisationQuotaRefreshDelay(nextAvailable: session.quota.nextAvailable(now: Date()), now: Date())
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                now = Date()
            }
        }
        .onChange(of: session.quota) { now = Date() }
        .onChange(of: engine) { now = Date() }
        .onDisappear { job?.cancel() }
    }

    private var templateSection: some View {
        Section {
            LabeledContent("Template", value: file.url.lastPathComponent)
            if parameters.isEmpty {
                Label("Studio found no values to fill in. It reads top-level text, number and on/off values set before the first module, as OpenSCAD’s Customizer does, and skips any in a /* [Hidden] */ section.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if file.template.usesOtherFiles {
                Label("This template uses other files (include or use). OpenSCAD on this Mac reads them from the template’s folder; Slant can’t.",
                      systemImage: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Another Template…") { store.chooseAndOpenPersonalisationTemplate() }
        }
    }

    @ViewBuilder
    private func field(_ parameter: ScadParameter) -> some View {
        let label = parameter.description ?? parameter.name
        let binding = Binding(get: { values[parameter.name] ?? parameter.defaultValue },
                              set: { values[parameter.name] = $0; status = nil; problem = nil })
        Group {
            if parameter.kind == .boolean {
                Toggle(label, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
            } else if !parameter.choices.isEmpty {
                Picker(label, selection: Binding(
                    get: { parameter.choices.first { scadValuesMatch($0.value, binding.wrappedValue, kind: parameter.kind) }?.value ?? binding.wrappedValue },
                    set: { binding.wrappedValue = $0 })) {
                    ForEach(parameter.choices, id: \.value) { choice in Text(choice.label).tag(choice.value) }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(label, text: binding, prompt: Text(parameter.defaultValue))
                        .accessibilityLabel(label)
                    if let caption = fieldCaption(parameter) {
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .help(parameter.name)
    }

    private func fieldCaption(_ parameter: ScadParameter) -> String? {
        if let range = parameter.range { return "From \(range.lowerBound.formatted()) to \(range.upperBound.formatted())" }
        if let length = parameter.maxLength { return "Up to \(length) characters" }
        return nil
    }

    private var engineSection: some View {
        Section {
            Picker("Generate with", selection: $engine) {
                ForEach(PersonalisationEngine.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text(engineCaption(now: now)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = blockedReason(now: now) {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if engine == .local, localExecutable == nil, lookedForOpenSCAD {
                    Button("Check Again") { lookForOpenSCAD() }
                        .help("Looks for OpenSCAD in Applications again, after you install it.")
                }
            }
        } footer: {
            Text(personalisationPrivacyNote).settingsFooterLayout()
        }
    }

    private func engineCaption(now: Date) -> String {
        switch engine {
        case .local:
            return "Runs OpenSCAD on this Mac. Nothing is sent to Slant, and there’s no hourly limit."
        case .slant:
            let remaining = session.quota.remaining(now: now)
            return "Sends the template and these values to Slant, which returns the STL. Slant allows \(OpenSCADQuota.generationsPerHour) generations an hour, one at a time: \(remaining) left by Studio’s count this session (it can’t see generations made elsewhere with your key). Every request counts, and Studio never retries one."
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else if let status {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.callout).lineLimit(2)
            } else if generating {
                ProgressView().controlSize(.small)
                Text(engine == .local ? "Generating with OpenSCAD…" : "Generating on Slant…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if generating, engine == .local {
                Button("Stop") { job?.cancel() }
            }
            Button("Done") { job?.cancel(); store.personalisationTemplate = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(generating && engine == .slant)
            // No Return shortcut: a Slant generation uses up its hourly allowance, so it always takes a click.
            Button("Generate STL") { generate() }
                .buttonStyle(.borderedProminent)
                .disabled(generating || parameters.isEmpty || blockedReason(now: now) != nil)
        }
        .padding(20)
    }

    private func generate() {
        guard !generating else { return }
        status = nil
        if let reason = blockedReason(now: Date()) { problem = reason; return }
        if let invalid = personalisationValuesProblem(parameters, values: values) { problem = invalid; return }
        problem = nil
        let assignments = scadAssignments(parameters, values: values)
        let name = personalisedModelName(templateName: file.name, parameters: parameters, values: values)
        let chosen = engine
        generating = true
        job = Task { @MainActor in
            defer { generating = false; job = nil }
            do {
                let data: Data
                switch chosen {
                case .local:
                    guard let executable = localExecutable else { return }
                    // OpenSCAD reads the file itself, so make sure it still matches the values shown here.
                    guard (try? loadPersonalisationTemplate(file.url))?.source == file.source else {
                        problem = "The template changed or moved since you opened it. Use Choose Another Template… to open it again."
                        return
                    }
                    data = try await runOpenSCADProcess(executable: executable, templateURL: file.url, assignments: assignments)
                case .slant:
                    data = try await store.generateOpenSCADOnSlant(source: scadSourceWithAssignments(file.source, assignments: assignments))
                }
                try Task.checkCancellation()
                if let failure = await store.savePersonalisedModel(data, name: name) {
                    problem = failure
                } else {
                    status = "Saved “\(name)” to your library."
                }
            } catch is CancellationError {
                problem = "Generation stopped."
            } catch {
                problem = error is APIError || error is URLError ? friendlyAPIMessage(error) : error.localizedDescription
            }
        }
    }
}
