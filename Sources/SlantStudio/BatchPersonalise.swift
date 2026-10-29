import Foundation

// Batch personalised imports: Import Orders can make each buyer's model from an OpenSCAD template with OpenSCAD on this
// Mac, upload it to Slant and use it in that buyer's draft in place of the saved product's plain model. Only local
// OpenSCAD is used: Slant's generator allows 5 an hour, too few for a batch. The buyer's text and the generated
// geometry stay in memory and in a temporary folder (removed after the upload, a failure or at the next launch); the
// generated model isn't added to the library, its upload is named by order number, and Activity records counts only.

// MARK: Template link (saved on a product's print item)

/// A saved product's print item made from an OpenSCAD template, one per buyer. References only: the template's
/// path on this Mac and the name of the text value that receives the buyer's personalisation.
struct SavedProductTemplateLink: Codable, Equatable {
    var templatePath = ""
    var valueName = ""
    var templateName: String { URL(fileURLWithPath: templatePath).lastPathComponent }
}

extension SavedProductTemplateLink {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        templatePath = (try? container.decodeIfPresent(String.self, forKey: .templatePath)) ?? ""
        valueName = (try? container.decodeIfPresent(String.self, forKey: .valueName)) ?? ""
    }
}

func savedProductTemplateLinkTrimmed(_ link: SavedProductTemplateLink) -> SavedProductTemplateLink {
    SavedProductTemplateLink(templatePath: link.templatePath.trimmingCharacters(in: .whitespacesAndNewlines),
                             valueName: link.valueName.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Why a product's template links can't be saved, or nil: at most one personalised item, a per-unit 3D print, with
/// a .scad template and a chosen value.
func savedProductTemplateLinkProblem(_ product: SavedProduct) -> String? {
    let linked = product.lines.enumerated().filter { $0.element.type == "PRINT" && $0.element.template != nil }
    guard !linked.isEmpty else { return nil }
    if linked.count > 1 { return "Only one item of a product can be personalised from a template." }
    let (index, line) = linked[0]
    let item = product.lines.count == 1 ? "the item" : "item \(index + 1)"
    let link = savedProductTemplateLinkTrimmed(line.template ?? SavedProductTemplateLink())
    if line.perOrder { return "A personalised item can’t be once per order. Turn off Once per order for \(item)." }
    guard !link.templatePath.isEmpty, URL(fileURLWithPath: link.templatePath).pathExtension.lowercased() == "scad" else {
        return "Choose an OpenSCAD template (.scad) for \(item), or remove its template."
    }
    if link.valueName.isEmpty { return "Choose which template value receives the buyer’s text for \(item)." }
    return nil
}

/// The product's personalised print item and its link, or nil when it has none (or the link isn't usable).
func savedProductTemplateLine(_ product: SavedProduct) -> (line: SavedProductLine, link: SavedProductTemplateLink)? {
    let linked = product.lines.filter { $0.type == "PRINT" && $0.template != nil }
    guard linked.count == 1, let line = linked.first, !line.perOrder, let link = line.template else { return nil }
    let trimmed = savedProductTemplateLinkTrimmed(link)
    guard !trimmed.templatePath.isEmpty, !trimmed.valueName.isEmpty else { return nil }
    return (line, trimmed)
}

// MARK: Personalisation fields

/// One part of a buyer's personalisation: "Name: Sam" is labelled "Name"; text without a label has none.
struct PersonalisationField: Equatable {
    let label: String?
    let value: String
}

/// Splits personalisation into its parts: one per line, and within a line at each `, Label:` (as Etsy joins
/// options). A part starting `Label:` (a letter, then up to 29 letters, digits or spaces) is labelled.
func personalisationFields(_ text: String) -> [PersonalisationField] {
    let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var fields: [PersonalisationField] = []
    for line in normalised.split(separator: "\n", omittingEmptySubsequences: true) {
        var rest = Substring(line)
        var segments: [Substring] = []
        while let next = rest.range(of: #",\s*[A-Za-z][A-Za-z0-9 ]{0,29}:"#, options: .regularExpression),
              next.lowerBound > rest.startIndex {
            segments.append(rest[..<next.lowerBound])
            rest = rest[rest.index(after: next.lowerBound)...]
        }
        segments.append(rest)
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let match = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9 ]{0,29}:"#, options: .regularExpression) {
                let label = trimmed[match.lowerBound..<trimmed.index(before: match.upperBound)].trimmingCharacters(in: .whitespaces)
                let value = trimmed[match.upperBound...].trimmingCharacters(in: .whitespaces)
                fields.append(PersonalisationField(label: label, value: value))
            } else {
                fields.append(PersonalisationField(label: nil, value: trimmed))
            }
        }
    }
    return fields
}

/// Labels compare ignoring case and repeated spaces.
func personalisationFieldKey(_ label: String) -> String {
    label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
}

/// Which part of each buyer's personalisation goes into the template, chosen per product in Import Orders. Held
/// only in the sheet's memory. Never guessed: nothing is personalised until the seller chooses.
enum PersonalisationTextChoice: Hashable {
    case wholeText
    /// The part with this label (`personalisationFieldKey`).
    case field(String)
}

/// The choices offered for a product's personalisations, in the order labels first appear. When every text is a
/// single part without a label, only the whole text is offered; otherwise each label, then the whole text.
struct PersonalisationTextOption: Equatable {
    let choice: PersonalisationTextChoice
    let title: String
}

func personalisationTextChoices(_ texts: [String]) -> [PersonalisationTextOption] {
    var labels: [(key: String, display: String)] = []
    var allSingle = true
    for text in texts {
        let fields = personalisationFields(text)
        if fields.count != 1 || fields.first?.label != nil { allSingle = false }
        for field in fields {
            guard let label = field.label else { continue }
            let key = personalisationFieldKey(label)
            if !labels.contains(where: { $0.key == key }) { labels.append((key, label)) }
        }
    }
    if allSingle { return [PersonalisationTextOption(choice: .wholeText, title: "Buyer’s text")] }
    return labels.map { PersonalisationTextOption(choice: .field($0.key), title: "“\($0.display)” part") }
        + [PersonalisationTextOption(choice: .wholeText, title: "Whole personalisation")]
}

enum PersonalisationValueResult: Equatable {
    case value(String)
    case problem(String)
}

/// The text the choice takes from one buyer's personalisation. A labelled part must appear exactly once.
func personalisationValue(_ text: String, choice: PersonalisationTextChoice) -> PersonalisationValueResult {
    switch choice {
    case .wholeText:
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .problem("This buyer’s personalisation is empty.") : .value(trimmed)
    case .field(let key):
        let matches = personalisationFields(text).filter { $0.label.map(personalisationFieldKey) == key }
        let label = matches.first?.label ?? key
        guard !matches.isEmpty else { return .problem("This buyer’s personalisation has no “\(label)” part.") }
        guard matches.count == 1 else { return .problem("This buyer’s personalisation has more than one “\(label)” part.") }
        let value = matches[0].value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .problem("The “\(label)” part of this buyer’s personalisation is empty.") : .value(value)
    }
}

// MARK: Which orders can be personalised

enum BatchPersonaliseTemplateState: Equatable {
    case loaded(PersonalisationTemplateFile)
    case failed(String)
}

/// The Import Orders sheet's personalisation state for one file: memory only.
struct BatchPersonaliseInputs {
    var openSCADAvailable = false
    /// Keyed by the link's template path.
    var templates: [String: BatchPersonaliseTemplateState] = [:]
    /// Keyed by saved product ID; a product without a choice isn't personalised.
    var choices: [UUID: PersonalisationTextChoice] = [:]
}

/// Most personalised models one order may need (distinct texts per product).
let batchPersonaliseMaxModelsPerOrder = 20
/// Most bytes of one order's models held in memory before they're uploaded.
let batchPersonaliseMaxOrderBytes = 256 * 1024 * 1024

/// One personalised model to make for an order: the template value set to `value`, used for `quantity` of the
/// order's line at `lineIndex` (in the check's lines).
struct BatchPersonaliseModel: Equatable {
    let productID: UUID
    let productName: String
    let lineIndex: Int
    let quantity: Int
    let value: String
    let parameter: ScadParameter
    let templateURL: URL
    /// The template as reviewed; a different file at generation time skips the order.
    let templateSource: String
}

struct BatchPersonalisePlan: Equatable {
    var models: [BatchPersonaliseModel]
    /// The draft's lines with the plain model, as the check built them.
    var baseLines: [OrderLine]
}

enum BatchPersonaliseEligibility: Equatable {
    /// Nothing to personalise, or the seller hasn't chosen to (or OpenSCAD isn't installed): the order is unchanged.
    case none
    /// The seller chose to personalise it, but it can't be; the plain-model warning stays.
    case unavailable([String])
    case ready(BatchPersonalisePlan)
}

/// Whether an importable order's personalised items can all be made with OpenSCAD, and how. Each personalised item
/// (not left out) must belong to a product with a template link and a choice; identical texts of one product share
/// one model. Items of that product without personalisation keep the plain model.
func batchPersonaliseEligibility(_ order: OrderImportOrder, check: OrderImportCheck, products: [SavedProduct],
                                 inputs: BatchPersonaliseInputs) -> BatchPersonaliseEligibility {
    guard inputs.openSCADAvailable, check.blockers.isEmpty, check.body != nil else { return .none }
    var problems: [String] = []
    func problem(_ text: String) { if !problems.contains(text) { problems.append(text) } }
    var optedIn = false
    var models: [BatchPersonaliseModel] = []
    for (index, item) in order.items.enumerated() where !item.personalisation.isEmpty {
        guard index < check.itemProductIDs.count, let productID = check.itemProductIDs[index],
              let product = products.first(where: { $0.id == productID }) else { continue }
        let name = savedProductDisplayName(product)
        guard let linked = savedProductTemplateLine(product) else {
            problem("“\(name)” has personalisation but no template. Link one in Saved Products, or make it by hand.")
            continue
        }
        let line = linked.line, link = linked.link
        guard let choice = inputs.choices[productID] else {
            problem("Choose which text to use for “\(name)” under Personalise with OpenSCAD.")
            continue
        }
        optedIn = true
        let file: PersonalisationTemplateFile
        switch inputs.templates[link.templatePath] {
        case .loaded(let loaded)?: file = loaded
        case .failed(let reason)?: problem(reason); continue
        case nil: problem("Studio hasn’t read the template \(link.templateName) yet."); continue
        }
        guard let parameter = file.template.parameters.first(where: { $0.name == link.valueName }) else {
            problem("\(file.url.lastPathComponent) has no value named “\(link.valueName)”. Edit “\(name)” in Saved Products.")
            continue
        }
        guard parameter.kind == .string else {
            problem("“\(link.valueName)” in \(file.url.lastPathComponent) isn’t a text value. Edit “\(name)” in Saved Products.")
            continue
        }
        let value: String
        switch personalisationValue(item.personalisation, choice: choice) {
        case .value(let text): value = text
        case .problem(let text): problem(text); continue
        }
        if let invalid = scadValueProblem(value, for: parameter) { problem(invalid); continue }
        guard let units = orderImportQuantity(item.quantityText) else { continue }
        guard let lineIndex = check.lineSources.firstIndex(where: { $0?.productID == productID && $0?.savedLineID == line.id }) else {
            problem("Studio couldn’t find the item to personalise in this draft.")
            continue
        }
        let (quantity, overflow) = units.multipliedReportingOverflow(by: line.quantity)
        guard !overflow, quantity > 0 else { problem("This order has too many personalised items."); continue }
        if let existing = models.firstIndex(where: { $0.productID == productID && $0.value == value }) {
            let model = models[existing]
            models[existing] = BatchPersonaliseModel(productID: productID, productName: name, lineIndex: lineIndex,
                                                     quantity: model.quantity + quantity, value: value, parameter: parameter,
                                                     templateURL: file.url, templateSource: file.source)
        } else {
            models.append(BatchPersonaliseModel(productID: productID, productName: name, lineIndex: lineIndex, quantity: quantity,
                                                value: value, parameter: parameter, templateURL: file.url, templateSource: file.source))
        }
    }
    guard optedIn else { return .none }
    if models.count > batchPersonaliseMaxModelsPerOrder {
        problem("This order needs more than \(batchPersonaliseMaxModelsPerOrder) personalised models. Make them by hand.")
    }
    for lineIndex in Set(models.map(\.lineIndex)) {
        let used = models.filter { $0.lineIndex == lineIndex }.reduce(0) { $0 + $1.quantity }
        if lineIndex >= check.lines.count || used > check.lines[lineIndex].quantity {
            problem("Studio couldn’t match the personalised items to this draft’s quantities.")
        }
    }
    guard problems.isEmpty else { return .unavailable(problems) }
    return .ready(BatchPersonalisePlan(models: models, baseLines: check.lines))
}

/// The check as the preview shows it once personalisation is considered: a ready order loses the plain-model
/// warning and says what it will set; one that can't be personalised keeps the warning and says why.
func batchPersonalisedCheck(_ check: OrderImportCheck, eligibility: BatchPersonaliseEligibility) -> OrderImportCheck {
    var result = check
    switch eligibility {
    case .none:
        break
    case .unavailable(let problems):
        for problem in problems { result.notes.append("Not personalised: \(problem)") }
    case .ready(let plan):
        result.warnings.removeAll { $0 == orderImportPlainModelWarning }
        for model in plan.models {
            let text = model.value.split(whereSeparator: \.isNewline).joined(separator: " / ")
            result.notes.append("Personalised with OpenSCAD: \(model.parameter.name) = “\(text)” for \(model.quantity) × \(model.productName). Made and uploaded before the draft is created.")
        }
    }
    return result
}

/// Orders to tick after a personalisation choice: those it made clean, as they would have been ticked on loading.
func batchPersonaliseNewlyTicked(before: [String: OrderImportCheck], after: [String: OrderImportCheck]) -> Set<String> {
    Set(after.compactMap { id, check in
        before[id]?.tickedByDefault == false && check.tickedByDefault ? id : nil
    })
}

/// Orders to untick after a personalisation choice: those that would now be drafted with the plain model.
func batchPersonaliseNewlyUnticked(before: [String: OrderImportCheck], after: [String: OrderImportCheck]) -> Set<String> {
    Set(after.compactMap { id, check in
        before[id]?.warnings.contains(orderImportPlainModelWarning) == false && check.warnings.contains(orderImportPlainModelWarning) ? id : nil
    })
}

/// The saved products the Personalise with OpenSCAD section lists: those with a template that an order's
/// personalised item (not left out) matched, each with its buyers' texts, in the order they first appear.
struct BatchPersonaliseProductEntry: Identifiable {
    let product: SavedProduct
    var texts: [String]
    var id: UUID { product.id }
}

func batchPersonaliseProducts(_ orders: [OrderImportOrder], checks: [String: OrderImportCheck],
                              products: [SavedProduct]) -> [BatchPersonaliseProductEntry] {
    var result: [BatchPersonaliseProductEntry] = []
    for order in orders {
        guard let check = checks[order.id] else { continue }
        for (index, item) in order.items.enumerated() where !item.personalisation.isEmpty {
            guard index < check.itemProductIDs.count, let id = check.itemProductIDs[index],
                  let product = products.first(where: { $0.id == id }), savedProductTemplateLine(product) != nil else { continue }
            if let position = result.firstIndex(where: { $0.product.id == id }) {
                result[position].texts.append(item.personalisation)
            } else {
                result.append(BatchPersonaliseProductEntry(product: product, texts: [item.personalisation]))
            }
        }
    }
    return result
}

// MARK: Drafting

/// The draft's lines with each personalised model in place: the plain line keeps what isn't personalised (removed
/// when nothing is left) and each model follows it as its own line. Nil when the IDs don't match the models or the
/// quantities don't fit.
func batchPersonaliseDraftLines(_ base: [OrderLine], models: [BatchPersonaliseModel], fileIDs: [String]) -> [OrderLine]? {
    guard models.count == fileIDs.count, !models.isEmpty,
          fileIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          models.allSatisfy({ $0.lineIndex >= 0 && $0.lineIndex < base.count && $0.quantity > 0 }) else { return nil }
    var result: [OrderLine] = []
    for (index, line) in base.enumerated() {
        let here = models.indices.filter { models[$0].lineIndex == index }
        guard !here.isEmpty else { result.append(line); continue }
        let used = here.reduce(0) { $0 + models[$1].quantity }
        guard used <= line.quantity else { return nil }
        if line.quantity > used {
            var plain = line
            plain.quantity = line.quantity - used
            result.append(plain)
        }
        for modelIndex in here {
            var personalised = OrderLine()
            personalised.type = line.type
            personalised.reference = fileIDs[modelIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            personalised.filamentID = line.filamentID
            personalised.quantity = models[modelIndex].quantity
            personalised.imageURL = line.imageURL
            personalised.name = line.name
            personalised.sku = line.sku
            personalised.optionsJSON = line.optionsJSON
            result.append(personalised)
        }
    }
    return result
}

/// The name a personalised model is uploaded under: never the buyer's text or name. The marketplace order number is
/// included only in the forms those marketplaces use — Etsy's plain digits, Shopify's "#1234" — so nothing with
/// letters (which could spell a name) goes into the file name. Studio's template takes any order ID the seller typed,
/// so its uploads always get the neutral name. The upload itself adds a random token (`batchPersonaliseUniqueUploadName`).
func batchPersonaliseUploadName(source: OrderImportFormat, sourceOrderID: String, index: Int, count: Int) -> String {
    let id = sourceOrderID.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern: String?
    switch source {
    case .etsy: pattern = #"^[0-9]{1,20}$"#
    case .shopify: pattern = #"^#?[0-9]{1,20}$"#
    case .template: pattern = nil
    }
    let usesNumber = pattern.map { id.range(of: $0, options: .regularExpression) != nil } ?? false
    let base = usesNumber ? "\(source.marketplace) order \(id) personalised" : "Personalised model"
    return count > 1 ? "\(base) \(index + 1) of \(count)" : base
}

/// Short random tokens for personalised upload names, never repeated in a session. Slant keeps one file per owner and
/// name (an upload under an earlier name reused that file, 30 Oct 2026), so two orders sharing "Personalised model", or
/// a re-imported order, would otherwise write over each other's models and every such draft would print the last one.
final class BatchPersonaliseUploadTokens: @unchecked Sendable {
    static let shared = BatchPersonaliseUploadTokens()
    private let lock = NSLock()
    private var used: Set<String> = []

    /// Six lower-case hex characters from a fresh UUID, unused this session.
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        while true {
            let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
            if used.insert(token).inserted { return token }
        }
    }
}

/// The name actually sent for a personalised upload: Studio's neutral name and a fresh token, made at send time so no
/// two uploads (in a batch, the session, or an order imported again) share a name ("Etsy order 123 personalised 1 of 2
/// · 7f3a9c"). The token is random, never derived from the buyer's text or the order.
func batchPersonaliseUniqueUploadName(_ name: String, token: String = BatchPersonaliseUploadTokens.shared.next()) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(trimmed.isEmpty ? "Personalised model" : trimmed) · \(token)"
}

// MARK: Outcomes

enum BatchPersonaliseUploadOutcome: Equatable {
    case uploaded(fileID: String)
    /// Slant definitely didn't keep the file (a 4xx other than 408/409, or a failure before sending).
    case refused(String)
    /// The file may have been uploaded.
    case unknown(String)
}

let batchPersonaliseUnknownUploadAdvice = "Its draft wasn’t created. The model may be in your Slant files."

/// A confirmed upload must name its file through `uploadedFileID` (a non-empty string `publicFileServiceId`,
/// `publicId` or `id`; never a name or a bare number), the same rule as Models' upload.
func batchPersonaliseUploadOutcome(response object: [String: Any]) -> BatchPersonaliseUploadOutcome {
    guard let id = uploadedFileID(object) else {
        return .unknown("Slant didn’t return the personalised model’s file ID. \(batchPersonaliseUnknownUploadAdvice)")
    }
    return .uploaded(fileID: id)
}

/// Refused only when the error proves Slant didn't act; timeouts, transport errors, 5xx, 408, 409 and replies Studio
/// can't read leave the outcome unknown.
func batchPersonaliseUploadOutcome(error: Error) -> BatchPersonaliseUploadOutcome {
    if orderMutationErrorProvesNoEffect(error) {
        if case APIError.http(429, _, _, _)? = error as? APIError {
            return .refused("Slant’s rate limit was reached, so the personalised model wasn’t uploaded and this draft wasn’t created.")
        }
        return .refused("Slant didn’t accept the personalised model, so this draft wasn’t created. \(friendlyAPIMessage(error))")
    }
    let reason: String
    if case APIError.http(let status, _, _, _)? = error as? APIError {
        reason = "Slant replied with an error (HTTP \(status)) while uploading the personalised model."
    } else if let urlError = error as? URLError, urlError.code == .timedOut {
        reason = "Slant didn’t reply in time while uploading the personalised model."
    } else {
        reason = "The personalised model’s upload didn’t complete."
    }
    return .unknown("\(reason) \(batchPersonaliseUnknownUploadAdvice)")
}

/// How making and uploading an order's personalised models ended.
enum BatchPersonaliseStepOutcome {
    /// Every model was made, checked and uploaded: their file IDs, in plan order.
    case ready([String])
    /// A model couldn't be made or checked; nothing more was uploaded for this order.
    case notMade(String)
    /// Slant definitely refused an upload.
    case refused(String, Error?)
    /// An upload's outcome is unknown.
    case unknown(String)
    /// Stop requested, the rate-limit wait was too long, or the account changed; the order wasn't sent.
    case stopped(String)
}

/// After an order's personalised models: an unknown upload always stops the batch, like an unconfirmed draft. A
/// model that couldn't be made, or a refused upload, skips the order and counts as a refusal in a row.
func batchPersonaliseNextStep(after outcome: BatchPersonaliseStepOutcome, consecutiveRefusals: Int,
                              maxConsecutiveRefusals: Int = orderImportMaxConsecutiveRefusals) -> OrderImportNextStep {
    switch outcome {
    case .ready:
        return .next
    case .unknown:
        return .stop("Stopped: Slant didn’t confirm a personalised model’s upload, so its draft wasn’t created and nothing more was sent. Check your Slant files before importing that order again.")
    case .stopped(let reason):
        return .stop(reason)
    case .refused(let reason, let error):
        return orderImportNextStep(after: .refused(reason), error: error, consecutiveRefusals: consecutiveRefusals,
                                   maxConsecutiveRefusals: maxConsecutiveRefusals)
    case .notMade(let reason):
        return orderImportNextStep(after: .refused(reason), error: nil, consecutiveRefusals: consecutiveRefusals,
                                   maxConsecutiveRefusals: maxConsecutiveRefusals)
    }
}

/// The confirmation's sentence about personalised drafts, or nil.
func batchPersonaliseConfirmText(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    let lead = count == 1 ? "1 draft uses a personalised model" : "\(count) drafts use personalised models"
    return " \(lead): Studio makes each with OpenSCAD on this Mac, checks it and uploads it to your Slant files (named by order number) before creating its draft. An order whose model can’t be made is skipped."
}

// MARK: Making and uploading

/// What a personalised order's runner needs: the plan, the upload names and how to build the draft body (only
/// through `orderDraftPayload`) from the final lines.
struct BatchPersonaliseJob {
    let plan: BatchPersonalisePlan
    let uploadNames: [String]
    let makeBody: ([OrderLine]) throws -> [String: Any]
}

/// The Import Orders runner's side of making and uploading: progress, its shared pacing, its stop and account checks,
/// and what each upload request did (for pacing and rate limits).
struct BatchPersonaliseRunHooks {
    var status: (String) -> Void
    /// Waits as the runner paces requests; a reason to stop, or nil.
    var pace: () async -> String?
    /// A reason to stop because the account or platform changed, or nil.
    var accountProblem: () -> String?
    var isStopRequested: () -> Bool
    var uploadSent: (Result<APIResponse, Error>) -> Void
}

let batchPersonaliseStoppedMessage = "Stopped. The rest weren’t sent."

/// Makes every model of the order with local OpenSCAD (no shell, timeout, stop, bounded output), checks each as an
/// STL with a closed surface within Slant's size limit, then uploads them one at a time through `APIClient.upload`.
/// All models are made before anything is uploaded, so a failure to make one never leaves an upload behind. Uploads
/// are never retried. Each STL is written to a `SlantStudio-Personalised-` folder that is removed straight after its
/// upload; nothing is added to the library.
@MainActor
func batchPersonaliseMakeAndUpload(_ job: BatchPersonaliseJob, client: APIClient, platformID: String, ownerID: String,
                                   hooks: BatchPersonaliseRunHooks, openSCAD: URL? = nil) async -> BatchPersonaliseStepOutcome {
    guard let executable = openSCAD ?? installedOpenSCADExecutable() else {
        return .notMade("OpenSCAD is no longer installed in Applications, so this buyer’s model wasn’t made.")
    }
    let count = job.plan.models.count
    var made: [Data] = []
    for (index, model) in job.plan.models.enumerated() {
        if hooks.isStopRequested() { return .stopped(batchPersonaliseStoppedMessage) }
        hooks.status(count == 1 ? "Making the personalised model…" : "Making personalised model \(index + 1) of \(count)…")
        // OpenSCAD reads the file itself, so it must still be the template that was reviewed.
        guard (try? loadPersonalisationTemplate(model.templateURL))?.source == model.templateSource else {
            return .notMade("The template \(model.templateURL.lastPathComponent) changed or moved since the file was checked. Choose the file again to review it.")
        }
        let assignments = [ScadAssignment(name: model.parameter.name, literal: scadLiteral(model.value, kind: .string))]
        let url = model.templateURL
        let generation = Task.detached(priority: .userInitiated) {
            try await runOpenSCADProcess(executable: executable, templateURL: url, assignments: assignments)
        }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if hooks.isStopRequested() { generation.cancel(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let output: Data
        do {
            output = try await generation.value
            watcher.cancel()
        } catch {
            watcher.cancel()
            if hooks.isStopRequested() { return .stopped(batchPersonaliseStoppedMessage) }
            return .notMade(error.localizedDescription)
        }
        let checked = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
            Result { try batchPersonaliseCheckedSTL(output) }
        }.value
        switch checked {
        case .success(let data):
            guard made.reduce(data.count, { $0 + $1.count }) <= batchPersonaliseMaxOrderBytes else {
                return .notMade("This order’s personalised models are larger than \(batchPersonaliseMaxOrderBytes / (1024 * 1024)) MB together. Make them by hand.")
            }
            made.append(data)
        case .failure(let error): return .notMade(error.localizedDescription)
        }
    }
    var fileIDs: [String] = []
    for (index, data) in made.enumerated() {
        if let reason = await hooks.pace() { return .stopped(reason) }
        if let reason = hooks.accountProblem() { return .stopped(reason) }
        hooks.status(count == 1 ? "Uploading the personalised model…" : "Uploading personalised model \(index + 1) of \(count)…")
        // A fresh token per upload, so this upload never reuses (and writes over) another file of the same name.
        let name = batchPersonaliseUniqueUploadName(index < job.uploadNames.count ? job.uploadNames[index] : "Personalised model")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(personalisationTempFolderPrefixes[1])\(UUID().uuidString)")
        let file = folder.appendingPathComponent("model.stl")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .notMade("Studio couldn’t write the personalised model to a temporary file. \(error.localizedDescription)")
        }
        let outcome: BatchPersonaliseUploadOutcome
        var failure: Error?
        do {
            let response = try await client.upload(file: file, name: name, platformId: platformID, ownerId: ownerID) { _ in }
            hooks.uploadSent(.success(response))
            outcome = batchPersonaliseUploadOutcome(response: responseObject(response))
        } catch {
            failure = error
            hooks.uploadSent(.failure(error))
            outcome = batchPersonaliseUploadOutcome(error: error)
        }
        try? FileManager.default.removeItem(at: folder)
        switch outcome {
        case .uploaded(let fileID):
            fileIDs.append(fileID)
        case .refused(let reason):
            let earlier = fileIDs.isEmpty ? "" : " Its other personalised models were uploaded to your Slant files."
            return .refused(reason + earlier, failure)
        case .unknown(let reason):
            return .unknown(reason)
        }
    }
    return .ready(fileIDs)
}

/// Checks generated bytes like Personalise from Template (a usable STL, returned as binary STL), and also that the
/// surface is closed and the file fits Slant's upload limit, because no one previews these models before upload.
func batchPersonaliseCheckedSTL(_ output: Data) throws -> Data {
    let data = try personalisedSTLData(output)
    if let problem = uploadSizeProblem(fileBytes: data.count) { throw StudioError(problem) }
    let mesh = try STLMesh.parse(data)
    guard let health = analyzeMeshHealth(mesh), health.isClosed else {
        throw StudioError("The generated model’s surface isn’t closed, so it wasn’t uploaded. Check the template with this buyer’s text in Personalise from Template.")
    }
    return data
}
