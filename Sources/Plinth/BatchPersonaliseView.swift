import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Batch personalised imports: the Import Orders section and session state, and the Saved Products editor's template
// link. The logic is in BatchPersonalise.swift.

/// Reads a linked template for the Import Orders checks and the Saved Products editor.
func batchPersonaliseLoadTemplate(path: String) -> BatchPersonaliseTemplateState {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
        return .failed("The template \(url.lastPathComponent) isn’t where it was saved. Choose it again in Saved Products.")
    }
    do { return .loaded(try loadPersonalisationTemplate(url)) }
    catch { return .failed("Plinth couldn’t read the template \(url.lastPathComponent). \(error.localizedDescription)") }
}

/// Import Orders' personalisation state for the chosen file: whether OpenSCAD is installed, the linked templates as
/// read, and the seller's choices. Memory only; reset with the file and when the sheet closes.
@MainActor final class BatchPersonaliseSession: ObservableObject {
    @Published private(set) var openSCAD: URL?
    @Published private(set) var templates: [String: BatchPersonaliseTemplateState] = [:]
    @Published var choices: [UUID: PersonalisationTextChoice] = [:]

    var inputs: BatchPersonaliseInputs {
        BatchPersonaliseInputs(openSCADAvailable: openSCAD != nil, templates: templates, choices: choices)
    }

    /// Looks for OpenSCAD in Applications and reads every template linked to a saved product (a file was chosen, or
    /// Check Again). Choices are kept.
    func refresh(products: [SavedProduct]) {
        openSCAD = installedOpenSCADExecutable()
        var loaded: [String: BatchPersonaliseTemplateState] = [:]
        for product in products {
            guard let link = savedProductTemplateLine(product)?.link, loaded[link.templatePath] == nil else { continue }
            loaded[link.templatePath] = batchPersonaliseLoadTemplate(path: link.templatePath)
        }
        templates = loaded
    }

    func reset() {
        openSCAD = nil
        templates = [:]
        choices = [:]
    }
}

let batchPersonaliseNoOpenSCADNote = "OpenSCAD isn’t installed in Applications, so these orders use the plain model. Install it from openscad.org, then press Check Again to make each buyer’s model here. Slant’s generator allows only 5 models an hour, so Import Orders doesn’t use it."

let batchPersonaliseSectionNote = "Choose which part of each buyer’s personalisation goes into the product’s template. When you create the drafts, Plinth makes each buyer’s model with OpenSCAD on this Mac, checks it, uploads it to your Slant files named by its Etsy or Shopify order number, or “Personalised model”, with a short random code so no two uploads share a name (never the buyer’s text or name), and uses it in their draft. The models aren’t added to your library, and these choices aren’t saved."

/// Import Orders' Personalise with OpenSCAD disclosure label: how many of the products with a template are set to be
/// personalised (`undecided` are still on Don't Personalise), or that OpenSCAD isn't installed.
func batchPersonaliseSectionTitle(openSCADInstalled: Bool, products: Int, undecided: Int) -> String {
    let title = "Personalise with OpenSCAD"
    guard openSCADInstalled else { return "\(title) · OpenSCAD isn’t installed" }
    guard products > 0 else { return title }
    let personalised = max(0, products - undecided)
    if personalised == 0 { return "\(title) · none chosen" }
    return personalised == products ? "\(title) · all chosen" : "\(title) · \(personalised) of \(products) chosen"
}

/// Import Orders: one row per saved product with a template, with the text it takes from each buyer's
/// personalisation. Nothing is personalised until the seller chooses.
struct OrderImportPersonaliseSection: View {
    @ObservedObject var session: BatchPersonaliseSession
    let products: [BatchPersonaliseProductEntry]
    let disabled: Bool
    let choose: (UUID, PersonalisationTextChoice?) -> Void
    let checkAgain: () -> Void

    var body: some View {
        // Shown inside Import Orders' "Personalise with OpenSCAD" disclosure, which carries the heading.
        VStack(alignment: .leading, spacing: 6) {
            if session.openSCAD == nil {
                Label(batchPersonaliseNoOpenSCADNote, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Check Again") { checkAgain() }
                    .controlSize(.small)
                    .disabled(disabled)
                    .help("Looks for OpenSCAD in Applications again, after you install it.")
            } else {
                Text(batchPersonaliseSectionNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(products) { entry in row(entry) }
                    }
                }
                .frame(maxHeight: products.count > 3 ? 120 : nil)
                .fixedSize(horizontal: false, vertical: products.count <= 3)
            }
        }
    }

    private func row(_ entry: BatchPersonaliseProductEntry) -> some View {
        let name = savedProductDisplayName(entry.product)
        let link = savedProductTemplateLine(entry.product)?.link
        let options = personalisationTextChoices(entry.texts)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let link {
                    Text("\(link.templateName) · sets \(link.valueName) · \(entry.texts.count == 1 ? "1 item" : "\(entry.texts.count) items")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if case .failed(let reason)? = session.templates[link.templatePath] {
                        Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            Picker("Text for \(name)", selection: Binding<PersonalisationTextChoice?>(
                get: { session.choices[entry.product.id] },
                set: { choose(entry.product.id, $0) })) {
                Text("Don’t Personalise").tag(PersonalisationTextChoice?.none)
                Divider()
                ForEach(options, id: \.choice) { option in
                    Text(option.title).tag(PersonalisationTextChoice?.some(option.choice))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Personalisation text for \(name)")
            .frame(width: 230)
            .disabled(disabled)
        }
    }
}

// MARK: - Saved Products editor

/// A print item's optional template link: choose a .scad file and the text value that receives the buyer's
/// personalisation. Only the file's location and the value's name are saved.
struct SavedProductTemplateLinkEditor: View {
    @Binding var link: SavedProductTemplateLink?
    @State private var loaded: BatchPersonaliseTemplateState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current = link {
                HStack {
                    Text("Personalised from \(current.templateName)")
                        .lineLimit(1).truncationMode(.middle)
                        .help(current.templatePath)
                    Spacer()
                    Button("Change Template…") { choose() }
                    Button("Remove Template") { link = nil }
                }
                valuePicker(current)
                Text("With OpenSCAD installed, Import Orders can make each buyer’s model from this template, with their personalisation in this value, and use it in their draft. Plinth saves only where the template is and the value’s name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Personalise from Template…") { choose() }
                    .help("Optional: when importing orders, make this item for each buyer from an OpenSCAD template")
            }
        }
        .task(id: link?.templatePath ?? "") { reload() }
    }

    @ViewBuilder
    private func valuePicker(_ current: SavedProductTemplateLink) -> some View {
        switch loaded {
        case .failed(let reason)?:
            Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .loaded(let file)?:
            let texts = file.template.parameters.filter { $0.kind == .string }
            if texts.isEmpty {
                Text("This template has no text values before its first module, so there’s nowhere for the buyer’s text to go.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Buyer’s text goes in", selection: Binding(get: { current.valueName }, set: { link?.valueName = $0 })) {
                    Text("Choose a value…").tag("")
                    ForEach(texts) { parameter in
                        Text(parameter.description.map { "\($0) (\(parameter.name))" } ?? parameter.name).tag(parameter.name)
                    }
                    if !current.valueName.isEmpty, !texts.contains(where: { $0.name == current.valueName }) {
                        Text("\(current.valueName) (not in this template)").tag(current.valueName)
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func reload() {
        guard let path = link?.templatePath, !path.isEmpty else { loaded = nil; return }
        loaded = batchPersonaliseLoadTemplate(path: path)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose the OpenSCAD template (.scad) this item is made from for each buyer."
        panel.allowedContentTypes = [UTType(filenameExtension: "scad") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        if link?.templatePath != path {
            // A new template needs its value chosen again: never carried over by name.
            link = SavedProductTemplateLink(templatePath: path, valueName: "")
        } else {
            reload()
        }
    }
}
