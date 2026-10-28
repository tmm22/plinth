import SwiftUI
import UniformTypeIdentifiers

struct PreparedRequest {
    let endpoint: Endpoint
    let path: String
    let query: [String: String]
    let body: Any?
    /// Baked typed-confirm phrase for high-risk ops (`rotate` or last path segment). Empty string = fail-closed.
    let confirmPhrase: String?
    /// `POST /orders` only: the `metadata.studioDraftId` added to the body (nil when there was no room for it), kept
    /// with the attempt if Slant doesn't confirm the draft.
    var draftMarker: String? = nil
    var isDraftCreate: Bool { endpoint.id == workbenchDraftCreateEndpointID }
    var summary: String { "\(endpoint.method) \(path)\n\nQuery\n\(prettyJSON(query))\n\nBody\n\(body.map(prettyJSON) ?? "None")" }
}
struct APIWorkbenchView: View {
    @EnvironmentObject var store: StudioStore
    @State private var search = ""
    var filtered: [Endpoint] { store.endpoints.filter { search.isEmpty || "\($0.group) \($0.title) \($0.path)".localizedCaseInsensitiveContains(search) } }
    var groups: [String] { Array(Set(filtered.map(\.group))).sorted() }
    var selected: Endpoint? { store.endpoints.first { $0.id == store.selectedEndpointID } }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedEndpointID) {
                    if !search.isEmpty, filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ForEach(groups, id: \.self) { group in
                            Section(group) {
                                ForEach(filtered.filter { $0.group == group }) { endpoint in
                                    VStack(alignment: .leading, spacing: 5) { Text(endpoint.title).font(.callout).lineLimit(2); HStack(spacing: 6) { Text(endpoint.method).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(endpoint.method == "GET" ? .green : .studioAccent); Text(endpoint.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) } }.padding(.vertical, 5).tag(endpoint.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $search, prompt: "Find an operation")
                Text("\(store.endpoints.count) documented operations").font(.caption).foregroundStyle(.secondary).padding(15)
            }.frame(minWidth: 245, idealWidth: 290, maxWidth: 360)
            if let selected { EndpointView(endpoint: selected).id(selected.id).frame(minWidth: 560) }
            else { EmptyState(icon: "terminal", title: "The complete API workspace", detail: "Choose an operation to explore its parameters, edit a request, and inspect the live response. All requests go to Slant’s production API.") }
        }.onAppear { if store.selectedEndpointID == nil { store.selectedEndpointID = store.endpoints.first { $0.path == "/usage" }?.id } }
    }
}

struct EndpointView: View {
    @EnvironmentObject var store: StudioStore
    let endpoint: Endpoint
    @State private var values: [String: String] = [:]
    @State private var bodyText = ""
    @State private var responseText = ""
    @State private var responseJSON: Any?
    @State private var responseData: Data?
    @State private var responseStatus: Int?
    @State private var showSecrets = false
    @State private var validation: String?
    @State private var pending: PreparedRequest?
    @State private var confirming = false
    @State private var previewOrder: [String: Any]?
    @State private var previewLoaded = false
    @State private var previewLoading = false
    @State private var previewFailed = false
    @State private var previewGeneration = 0
    @State private var typedConfirm = ""
    @State private var mutationSucceeded = false
    @State private var mutationAttempted = false
    @State private var mutateTask: Task<Void, Never>?
    /// The confirm sheet's own note about the last send (a pay accepted but not confirmed, a refusal), shown in place
    /// of the generic unknown-result line; the window's alert would wait behind the sheet.
    @State private var mutationNote: String?
    /// After an unconfirmed draft create (any composer), a Workbench `POST /orders` that could repeat it asks for Create
    /// Anyway first (`draftCreateNeedsCreateAnyway`).
    @State private var confirmWorkbenchCreateAnyway = false
    var isChargeEndpoint: Bool { endpoint.method == "POST" && endpoint.path == "/orders/{publicOrderId}" }
    var isDeleteOrderEndpoint: Bool { endpoint.method == "DELETE" && endpoint.path == "/orders/{publicOrderId}" }
    var hasOpenSCADResult: Bool { endpoint.path == "/files/openScad" && responseData != nil && !responseText.isEmpty }
    var displayedResponseText: String { workbenchDisplayedResponse(path: endpoint.path, json: responseJSON, fallback: responseText, showSecrets: showSecrets) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text(endpoint.method).font(.system(.callout, design: .monospaced).weight(.bold)).foregroundStyle(Color.studioAccent).padding(8).background(Color.studioAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6)); Text(endpoint.title).font(.title2.weight(.semibold)) }
                Text(endpoint.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(endpoint.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if endpoint.sessionOnly {
                    Card { VStack(alignment: .leading, spacing: 12) { Label("Manage this in your Slant dashboard", systemImage: "safari").font(.headline); Text("This operation requires a signed-in website session and does not accept API-key authentication."); Link("Open Slant Dashboard", destination: URL(string: "https://slant3dapi.com")!) } }
                } else {
                    if !endpoint.parameters.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeading(title: "Parameters")
                                ForEach(endpoint.parameters, id: \.name) { parameter in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(parameter.name).font(.system(.caption, design: .monospaced).weight(.semibold))
                                            Text(parameter.required ? "Required · \(parameter.location)" : "Optional · \(parameter.location)").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if !parameter.description.isEmpty {
                                            Text(parameter.description).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        TextField(
                                            parameter.defaultValue.isEmpty ? (parameter.required ? "Required" : "Optional") : parameter.defaultValue,
                                            text: Binding(get: { values[parameter.name] ?? "" }, set: { values[parameter.name] = $0 })
                                        ).textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                        }
                    }
                    if !endpoint.bodyTemplate.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { SectionHeading(title: endpoint.path == "/files/openScad" ? "OpenSCAD request" : "Request body", caption: "Editable JSON"); Spacer(); Button("Reset") { bodyText = endpoint.bodyTemplate } }
                                TextEditor(text: $bodyText).font(.system(size: 12, design: .monospaced)).frame(minHeight: 180, idealHeight: 240).padding(7).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                                DisclosureGroup("Fields & schema") { JSONView(text: endpoint.bodySchema).frame(height: 300) }.studioDisclosureStyle()
                            }
                        }
                    }
                    if let validation { Label(validation, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    HStack {
                        Group {
                            if hasOpenSCADResult {
                                Button(endpoint.method == "GET" ? "Fetch Response" : "Review Request…") { prepare() }.buttonStyle(.bordered)
                            } else {
                                Button(endpoint.method == "GET" ? "Fetch Response" : "Review Request…") { prepare() }.buttonStyle(.borderedProminent)
                            }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(store.busy || (endpoint.requiresAuth && !store.hasKey))
                        if store.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        if let responseStatus { Text("HTTP \(responseStatus)").font(.caption.monospaced()).foregroundStyle(.green) }
                    }
                }
                if !responseText.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Response").font(.headline)
                                Spacer()
                                ControlGroup {
                                    if endpoint.path != "/files/openScad" { Toggle("Show secrets", isOn: $showSecrets).toggleStyle(.checkbox) }
                                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(displayedResponseText, forType: .string) }
                                    Button("Save…") { saveResponse() }
                                }.font(.caption)
                            }
                            JSONView(text: displayedResponseText).frame(minHeight: 220, idealHeight: 350)
                            if hasOpenSCADResult {
                                Button("Import Generated STL into Library") { importGenerated() }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }.padding(26)
        }
        .onAppear {
            bodyText = endpoint.bodyTemplate
            for parameter in endpoint.parameters { values[parameter.name] = parameter.defaultValue }
            for key in ["platformId"] where endpoint.parameters.contains(where: { $0.name == key }) { values[key] = store.platformID }
            for key in ["publicFileId", "publicFileServiceId"] where endpoint.parameters.contains(where: { $0.name == key }) { values[key] = store.fileID }
            if endpoint.path == "/files/openScad" { bodyText = prettyJSON(["scadCode": "// Dimensions in millimeters\ndifference() {\n  cube([30, 30, 20], center=true);\n  cylinder(h=24, r=8, center=true, $fn=64);\n}"]) }
        }
        .sheet(isPresented: $confirming) {
            if let pending { confirmSheet(pending) }
        }
    }
    @ViewBuilder
    func confirmSheet(_ pending: PreparedRequest) -> some View {
        let isCharge = pending.endpoint.method == "POST" && pending.endpoint.path == "/orders/{publicOrderId}"
        let isDeleteOrder = pending.endpoint.method == "DELETE" && pending.endpoint.path == "/orders/{publicOrderId}"
        let status = previewOrder.flatMap { $0["status"] as? String }
        let (chargeOK, chargeReason) = workbenchChargeAllowed(status: status, loaded: previewLoaded, order: previewOrder)
        let (cancelOK, cancelReason) = workbenchCancelAllowed(status: status, loaded: previewLoaded)
        let (typedOK, typedReason) = workbenchTypedConfirmationAllowed(bakedPhrase: pending.confirmPhrase, typed: typedConfirm)
        let usesReturn = workbenchConfirmSendUsesReturnDefault(method: pending.endpoint.method, path: pending.endpoint.path)
        let orderID = (isCharge || isDeleteOrder) ? workbenchPathParameter(pending.path, after: "/orders/") : ""
        // Locked under the typed ID, or under the IDs of the order Slant returned for it (the ID Orders lists).
        let crossSheetUnknown = !orderID.isEmpty
            && orderOutcomeLockIDs(requested: orderID, order: previewOrder).contains { store.isOutcomeUnknown(orderID: $0) }
        let (sendUnlocked, unknownReason) = workbenchMutationSendAllowed(attempted: mutationAttempted, succeeded: mutationSucceeded)
        let sendEnabled = typedOK && sendUnlocked && !crossSheetUnknown
        VStack(alignment: .leading, spacing: 18) {
            Text("Review \(pending.endpoint.title.lowercased())").font(.title2.weight(.bold))
            Text(warning).foregroundStyle(.secondary)
            if pending.isDraftCreate, store.draftCreateOutcomeUnknown {
                // The composer's unconfirmed-draft notice: sending this may make a second draft.
                Label(draftCreateUnknownNotice(store.unconfirmedDraftCreates, earlierUnlisted: store.unconfirmedDraftCreatesOverflowed),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let mutationNote {
                VStack(alignment: .leading, spacing: 8) {
                    Text(mutationNote).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if crossSheetUnknown {
                        Button("Reload Order") { startOrderPreview(pending) }.disabled(store.busy || previewLoading)
                    }
                }
            } else if crossSheetUnknown {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workbenchUnknownOutcomeBlockMessage).font(.callout).foregroundStyle(.orange)
                    Button("Reload Order") { startOrderPreview(pending) }.disabled(store.busy || previewLoading)
                }
            } else if let unknownReason {
                Text(unknownReason).font(.callout).foregroundStyle(.orange)
            }
            if isCharge || isDeleteOrder {
                if let order = previewOrder {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status: \(order["status"].map { String(describing: $0) } ?? "—")")
                        Text("Printing: \(money(order["printingCost"]))")
                        Text("Delivery: \(money(order["deliveryCost"]))")
                        Text("Total: \(orderTotalMoney(order))")
                        // As in the Orders review: advisory only, never changes whether Send is enabled.
                        if isCharge, let notice = orderUnlistedCostNotice(orderUnlistedCosts(order)) {
                            Text(notice).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Recipient: \(workbenchOrderRecipient(order))")
                    }.font(.callout).textSelection(.enabled)
                } else if previewLoading {
                    ProgressView("Loading order costs…").controlSize(.small)
                } else if previewFailed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isCharge ? "Couldn’t load this order’s costs." : "Couldn’t load this order.").font(.callout).foregroundStyle(.orange)
                        Button("Try Again") { startOrderPreview(pending) }.disabled(store.busy)
                    }
                }
            }
            if let phrase = pending.confirmPhrase {
                VStack(alignment: .leading, spacing: 6) {
                    if phrase.isEmpty {
                        Text("Enter the target id to confirm.").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(phrase == "rotate" ? "Type rotate to confirm secret rotation." : "Type \(phrase) to confirm.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(phrase, text: $typedConfirm).textFieldStyle(.roundedBorder).disabled(store.busy || mutationAttempted || mutationSucceeded)
                    }
                    if let typedReason { Text(typedReason).font(.caption).foregroundStyle(.orange) }
                }
            }
            JSONView(text: pending.summary)
            HStack {
                Button("Go Back", role: .cancel) { dismissConfirm() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                Spacer()
                if isCharge {
                    VStack(alignment: .trailing, spacing: 6) {
                        if previewLoaded || previewFailed, let chargeReason { Text(chargeReason).font(.caption).foregroundStyle(.secondary) }
                        confirmSendButton(title: "Pay & Send to Production", prominent: true, destructive: false, enabled: chargeOK && sendEnabled, usesReturn: usesReturn) {
                            guard let preview = previewOrder, sendUnlocked, !crossSheetUnknown else { return }
                            executeGuardedOrderMutation(pending, preview: preview)
                        }
                    }
                } else if isDeleteOrder {
                    VStack(alignment: .trailing, spacing: 6) {
                        if previewLoaded || previewFailed, let cancelReason { Text(cancelReason).font(.caption).foregroundStyle(.secondary) }
                        confirmSendButton(title: "Send DELETE Request", prominent: false, destructive: true, enabled: cancelOK && sendEnabled, usesReturn: usesReturn) {
                            guard let preview = previewOrder, sendUnlocked, !crossSheetUnknown else { return }
                            executeGuardedOrderMutation(pending, preview: preview)
                        }
                    }
                } else {
                    confirmSendButton(title: "Send \(pending.endpoint.method) Request", prominent: true, destructive: pending.endpoint.method == "DELETE", enabled: sendEnabled, usesReturn: usesReturn) {
                        guard sendUnlocked else { return }
                        // As the composer: Create Anyway only when the body's recipient could be an unconfirmed
                        // attempt's (`draftCreateNeedsCreateAnyway`; no readable name counts as could be).
                        if pending.isDraftCreate,
                           draftCreateNeedsConfirmation(
                               outcomeUnknown: draftCreateNeedsCreateAnyway(
                                   attempts: store.unconfirmedDraftCreates, overflowed: store.unconfirmedDraftCreatesOverflowed,
                                   recipient: orderDraftBodyRecipient(pending.body)),
                               confirmed: false) {
                            confirmWorkbenchCreateAnyway = true
                            return
                        }
                        execute(pending)
                    }
                }
            }
        }.padding(26).frame(width: 680, height: (isCharge || isDeleteOrder || pending.confirmPhrase != nil) ? 680 : 570)
        .confirmationDialog("Create another draft?", isPresented: $confirmWorkbenchCreateAnyway, titleVisibility: .visible) {
            Button("Create Anyway") {
                guard sendUnlocked, pending.isDraftCreate else { return }
                execute(pending)
            }
            Button("Don’t Create", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(draftCreateAnywayMessage(store.unconfirmedDraftCreates, earlierUnlisted: store.unconfirmedDraftCreatesOverflowed))
        }
    }
    @ViewBuilder
    func confirmSendButton(title: String, prominent: Bool, destructive: Bool, enabled: Bool, usesReturn: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if prominent && !destructive {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else if destructive {
                Button(title, role: .destructive, action: action)
            } else {
                Button(title, action: action)
            }
        }
        .disabled(store.busy || !enabled)
        .modifier(WorkbenchReturnDefaultModifier(enabled: usesReturn))
    }
    var warning: String {
        if isChargeEndpoint { return "This charges payment and submits the order for printing and shipping. Confirm the order’s current costs and delivery details before sending." }
        if endpoint.method == "DELETE" { return workbenchDeleteWarning(path: endpoint.path) }
        return "This sends the request below to the live production API. Webhook requests contact the endpoint configured for your platform."
    }
    func dismissConfirm() {
        mutateTask?.cancel()
        mutateTask = nil
        previewGeneration += 1
        previewLoading = false
        confirming = false
    }
    func prepare() {
        do {
            var path = endpoint.path
            var query: [String: String] = [:]
            for parameter in endpoint.parameters {
                let value = (values[parameter.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if parameter.required && value.isEmpty { throw StudioError("\(parameter.name) is required.") }
                if !value.isEmpty, let schemaData = parameter.schemaJSON.data(using: .utf8),
                   let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] {
                    try validateQueryParameter(name: parameter.name, value: value, schema: schema)
                }
                if parameter.location == "path" { path = path.replacingOccurrences(of: "{\(parameter.name)}", with: encodedSegment(value)) }
                else if !value.isEmpty { query[parameter.name] = value }
            }
            guard !path.contains("{") else { throw StudioError("Fill in all path parameters.") }
            if isChargeEndpoint || isDeleteOrderEndpoint {
                let orderID = workbenchPathParameter(path, after: "/orders/")
                if store.isOutcomeUnknown(orderID: orderID) {
                    validation = workbenchUnknownOutcomeBlockMessage
                    return
                }
            }
            // Slant's OpenSCAD allowance is shared with Personalise from Template (5 an hour, one at a time).
            if endpoint.path == "/files/openScad", let reason = PersonalisationSession.shared.quota.blockedReason(now: Date()) {
                validation = reason
                return
            }
            var object: Any?
            var draftMarker: String?
            if !endpoint.bodyTemplate.isEmpty {
                guard let data = bodyText.data(using: .utf8) else { throw StudioError("Enter a valid JSON body.") }
                object = try JSONSerialization.jsonObject(with: data)
                if let value = object { object = normalizedRequestBody(value, endpointID: endpoint.id) }
                if endpoint.id == workbenchDraftCreateEndpointID {
                    // The composer's marker, so Look for Draft on Slant can find this draft if Slant doesn't confirm it.
                    (object, draftMarker) = workbenchDraftBodyAddingMarker(object, marker: newStudioDraftMarker())
                }
                if let schemaData = endpoint.bodySchema.data(using: .utf8), let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any], let object {
                    try validateJSON(object, schema: schema)
                    if let metadata = (object as? [String: Any])?["metadata"] {
                        try validateOrderMetadata(metadata)
                    }
                }
            }
            let phrase = workbenchBakedConfirmPhrase(method: endpoint.method, templatePath: endpoint.path, resolvedPath: path)
            let request = PreparedRequest(endpoint: endpoint, path: path, query: query, body: object, confirmPhrase: phrase,
                                          draftMarker: draftMarker)
            validation = nil
            mutationNote = nil
            if endpoint.method == "GET" { execute(request) } else {
                pending = request
                typedConfirm = ""
                mutationSucceeded = false
                mutationAttempted = false
                previewOrder = nil
                previewLoaded = false
                previewFailed = false
                previewLoading = false
                confirming = true
                if isChargeEndpoint || isDeleteOrderEndpoint { startOrderPreview(request) }
            }
        } catch { validation = error.localizedDescription }
    }
    func startOrderPreview(_ request: PreparedRequest) {
        previewGeneration += 1
        let generation = previewGeneration
        previewOrder = nil
        previewLoaded = false
        previewFailed = false
        previewLoading = true
        loadOrderPreview(request, generation: generation)
    }
    func loadOrderPreview(_ request: PreparedRequest, generation: Int) {
        Task {
            while true {
                guard generation == previewGeneration else { return }
                if store.busy {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                let ran = await store.run("Load order for review") {
                    let response = try await store.client.request("GET", path: request.path, query: request.query)
                    guard generation == previewGeneration else { return }
                    let order = workbenchUnwrapOrder(responseObject(response))
                    let orderID = workbenchPathParameter(request.path, after: "/orders/")
                    // Only the order asked for may be reviewed, sent or used to lift a lock.
                    guard workbenchOrderMatchesRequestedID(order, requested: orderID) else {
                        throw StudioError(workbenchDifferentOrderMessage)
                    }
                    let reloadedStatus = (order["status"] as? String) ?? ""
                    previewOrder = order
                    previewLoaded = true
                    // Compare with what was recorded when the uncertain request was sent, not this sheet's last preview.
                    // The lock may be under the typed ID or the order's own IDs (an Orders review keeps it under those).
                    var lifted = false
                    for id in orderOutcomeLockIDs(requested: orderID, order: order) where store.isOutcomeUnknown(orderID: id) {
                        if unknownOutcomeResolvedByReload(context: store.unknownOutcomeContext(orderID: id), reloadedStatus: reloadedStatus) {
                            store.clearOutcomeUnknown(orderID: id)
                            lifted = true
                        }
                    }
                    // The earlier "result is unknown" note no longer holds: say what the reload showed instead.
                    // Sending stays blocked in this review (`mutationAttempted`); the status decides any next step.
                    if lifted, mutationAttempted || mutationNote != nil {
                        mutationNote = workbenchReloadResolvedNote(status: reloadedStatus)
                    }
                }
                guard generation == previewGeneration else { return }
                if !ran {
                    // Skipped because busy — stay loading and wait.
                    continue
                }
                if previewLoaded {
                    previewLoading = false
                    previewFailed = false
                    return
                }
                previewLoading = false
                previewFailed = true
                return
            }
        }
    }
    func executeGuardedOrderMutation(_ request: PreparedRequest, preview: [String: Any]) {
        responseStatus = nil; responseData = nil; responseText = ""; responseJSON = nil; showSecrets = false
        mutateTask?.cancel()
        let orderID = workbenchPathParameter(request.path, after: "/orders/")
        let isPay = request.endpoint.method == "POST"
        mutationNote = nil
        mutateTask = Task {
            var wrote = false
            var keepsLock = false
            var lockIDs = [orderID]
            var note: String?
            // Once a write was sent, the sheet explains the result itself; before that, the usual alert.
            let ran = await store.run(request.endpoint.title, handlesError: { _ in mutationAttempted || wrote || note != nil }) {
                if store.isOutcomeUnknown(orderID: orderID) {
                    throw StudioError(workbenchUnknownOutcomeBlockMessage)
                }
                let freshResponse = try await store.client.request("GET", path: request.path, query: request.query)
                guard !Task.isCancelled else { return }
                let fresh = workbenchUnwrapOrder(responseObject(freshResponse))
                guard workbenchOrderMatchesRequestedID(fresh, requested: orderID) else {
                    throw StudioError(workbenchDifferentOrderMessage)
                }
                // The lock is kept under the typed ID and the order's own IDs, so the Orders review sees it too.
                lockIDs = orderOutcomeLockIDs(requested: orderID, order: fresh)
                if lockIDs.contains(where: { store.isOutcomeUnknown(orderID: $0) }) {
                    throw StudioError(workbenchUnknownOutcomeBlockMessage)
                }
                if let message = workbenchOrderPreviewMismatchMessage(preview: preview, fresh: fresh) {
                    throw StudioError(message)
                }
                // Cross-sheet + sheet lock before the write — outcome may be unknown on timeout/5xx.
                store.markOutcomeUnknown(
                    orderID: orderID,
                    action: isPay ? .pay : .cancel,
                    reviewedStatus: fresh["status"] as? String,
                    aliases: lockIDs
                )
                mutationAttempted = true
                // Quit asks first until this write has its answer (SlantStudioApp.swift).
                let write = SlantWritesInFlight.shared.begin(isPay ? .payment : .cancellation)
                defer { SlantWritesInFlight.shared.end(write) }
                let response: APIResponse
                do {
                    response = try await store.client.request(request.endpoint.method, path: request.path, query: request.query, body: request.body)
                } catch {
                    if orderMutationErrorProvesNoEffect(error, method: request.endpoint.method) {
                        // Slant refused it (or it was never sent), so nothing is pending.
                        store.clearOutcomeUnknown(orderID: orderID)
                        mutationAttempted = false
                        note = orderConfirmRefusalMessage(isPay: isPay, error: error)
                    }
                    throw error
                }
                wrote = true
                responseData = response.data; responseStatus = response.statusCode
                responseJSON = response.json
                responseText = response.pretty
                if isPay {
                    // As the Orders review and Pay Several Drafts: a 2xx whose order still shows DRAFT, or no
                    // readable status, isn't a confirmed charge, so the lock stays until a reload shows the outcome.
                    let replied = workbenchUnwrapOrder(responseObject(response))
                    var refreshed: [String: Any]?
                    if let reread = try? await store.client.request("GET", path: request.path, query: request.query) {
                        refreshed = workbenchUnwrapOrder(responseObject(reread))
                    }
                    let judged = workbenchPayAcceptedOrder(replied: replied, refreshed: refreshed, requested: orderID)
                    if let judged { previewOrder = judged }
                    keepsLock = workbenchPayAcceptedKeepsLock(replied: replied, refreshed: refreshed, requested: orderID)
                    let outcome = batchPayOutcomeAfterSuccess(judged)
                    if keepsLock {
                        note = "Slant accepted the payment request but doesn’t show the order as placed yet, so it may still be charged. Reload the order before doing anything else."
                    } else if let message = orderPayAcceptedMessage(outcome), outcome != .placed {
                        note = message
                    }
                    // Activity records "Completed" only for a placed order.
                    if outcome != .placed { throw StudioError(orderPayActivityDetail(outcome)) }
                }
            }
            if let note { mutationNote = note }
            guard !Task.isCancelled else { return }
            if ran, wrote, !keepsLock {
                store.clearOutcomeUnknown(orderID: orderID)
                mutationSucceeded = true
                // A pay that wasn't placed stays open with its note; anything else closes as before.
                if mutationNote == nil { dismissConfirm() }
            }
        }
    }
    func execute(_ request: PreparedRequest) {
        responseStatus = nil; responseData = nil; responseText = ""; responseJSON = nil; showSecrets = false
        mutateTask?.cancel()
        mutateTask = Task {
            var wrote = false
            var draftAttempt = DraftCreateAttempt.notSent
            let isOpenSCAD = request.endpoint.path == "/files/openScad"
            let openSCAD = PersonalisationSession.shared
            var openSCADFailure: Error?
            let attemptDate = Date()
            let ran = await store.run(request.endpoint.title) {
                // Slant's OpenSCAD allowance: counted as it is sent, whatever the outcome, as in Personalise.
                if isOpenSCAD {
                    guard openSCAD.quota.begin(now: Date()) else {
                        throw StudioError(openSCAD.quota.blockedReason(now: Date()) ?? "Slant’s OpenSCAD limit was reached.")
                    }
                }
                defer { if isOpenSCAD { openSCAD.quota.finish() } }
                // Quit asks first until a draft create has its answer (SlantStudioApp.swift).
                let write = request.isDraftCreate ? SlantWritesInFlight.shared.begin(.draft) : nil
                defer { if let write { SlantWritesInFlight.shared.end(write) } }
                mutationAttempted = true
                let response: APIResponse
                do {
                    response = try await store.client.request(request.endpoint.method, path: request.path, query: request.query, body: request.body)
                } catch {
                    draftAttempt = .failed(error)
                    openSCADFailure = error
                    throw error
                }
                if request.isDraftCreate {
                    // As the composer: a draft is confirmed only by a reply naming it (`publicId` or `id`). Without
                    // one the outcome stays unknown, so this isn't a success and the sheet keeps Send locked.
                    guard orderCreatedID(mergeOrderDraftEnvelope(responseObject(response))) != nil else {
                        let unconfirmed = StudioError("Slant didn’t return an order number, so this draft may have been created.")
                        draftAttempt = .failed(unconfirmed)
                        responseData = response.data; responseStatus = response.statusCode
                        responseJSON = response.json
                        responseText = response.pretty
                        throw unconfirmed
                    }
                    draftAttempt = .succeeded
                }
                wrote = true
                guard !Task.isCancelled else { return }
                responseData = response.data; responseStatus = response.statusCode
                if isOpenSCAD {
                    responseText = "STL generated successfully · \(ByteCountFormatter.string(fromByteCount: Int64(response.data.count), countStyle: .file))\nSave the STL or import it into your model library."
                } else {
                    responseJSON = response.json
                    responseText = response.pretty
                    if request.endpoint.id == "POST /orders/batch", let count = ordersBatchReplyOrders(response.json).map(\.count) {
                        responseText = "Slant returned \(count) \(count == 1 ? "order" : "orders").\n\n" + responseText
                    }
                }
            }
            if request.isDraftCreate {
                // The composer's unconfirmed-draft guard: an unknown outcome adds this attempt, a confirmed creation
                // removes the attempts for the body's recipient (`customer.details.address.name`; an empty name only
                // clears attempts without one), a refusal (or a request never sent) leaves it as it was.
                store.noteDraftCreateAttempt(draftAttempt, recipient: orderDraftBodyRecipient(request.body), date: attemptDate,
                                             marker: request.draftMarker,
                                             platformID: ((request.body as? [String: Any])?["platformId"] as? String) ?? "")
            }
            if isOpenSCAD, case APIError.http(429, _, let retryAfter, let reset)? = openSCADFailure as? APIError {
                openSCAD.quota.noteRateLimited(until: openSCADRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date()))
            }
            guard !Task.isCancelled else { return }
            if ran, wrote {
                await clearSelectionAfterSuccessfulDelete(request)
                mutationSucceeded = true
                dismissConfirm()
            }
        }
    }
    func clearSelectionAfterSuccessfulDelete(_ request: PreparedRequest) async {
        guard request.endpoint.method == "DELETE" else { return }
        if request.endpoint.path == "/platforms/{platformId}" {
            let id = workbenchPathParameter(request.path, after: "/platforms/")
            if !id.isEmpty, store.platformID == id { store.platformID = "" }
            await store.loadCatalog(.platforms)
        } else if request.endpoint.path == "/files/{publicFileId}" {
            let id = workbenchPathParameter(request.path, after: "/files/")
            if !id.isEmpty, store.fileID == id { store.fileID = "" }
        }
    }
    func saveResponse() {
        guard let responseData else { return }
        let panel = NSSavePanel()
        let isSTL = endpoint.path == "/files/openScad"
        panel.nameFieldStringValue = isSTL ? "generated-model.stl" : "slant-response.json"
        panel.allowedContentTypes = [UTType(filenameExtension: isSTL ? "stl" : "json") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if isSTL { try responseData.write(to: url, options: .atomic) }
                else if let data = displayedResponseText.data(using: .utf8) { try data.write(to: url, options: .atomic) }
            } catch { validation = error.localizedDescription }
        }
    }
    func importGenerated() {
        guard let responseData else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("generated-\(UUID().uuidString).stl")
        do { try responseData.write(to: url); defer { try? FileManager.default.removeItem(at: url) }; store.importModel(url, origin: .workbench) } catch { validation = error.localizedDescription }
    }
}

private struct WorkbenchReturnDefaultModifier: ViewModifier {
    let enabled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.defaultAction) } else { content }
    }
}

/// Gating for the production charge confirm sheet. `loaded` means the read-only GET succeeded.
func workbenchChargeAllowed(status: String?, loaded: Bool) -> (Bool, String?) {
    guard loaded else { return (false, "Couldn’t load this order’s costs.") }
    guard let status, status.uppercased() == "DRAFT" else { return (false, "Only drafts can be placed.") }
    return (true, nil)
}

/// Workbench charge gate: draft + loaded + a numeric total (never treat “—” as payable).
func workbenchChargeAllowed(status: String?, loaded: Bool, order: [String: Any]?) -> (Bool, String?) {
    let base = workbenchChargeAllowed(status: status, loaded: loaded)
    guard base.0 else { return base }
    guard let order, workbenchOrderHasNumericTotal(order) else {
        return (false, "Order total isn’t available yet.")
    }
    return (true, nil)
}

/// Payable totals: an explicit numeric `total`/`totalCost`, or both printing and delivery costs.
/// Printing-only must not pass (orderTotalMoney’s fallback would otherwise look payable).
func workbenchOrderHasNumericTotal(_ order: [String: Any]) -> Bool {
    if decimalAmount(order["total"]) != nil || decimalAmount(order["totalCost"]) != nil { return true }
    return decimalAmount(order["printingCost"]) != nil && decimalAmount(order["deliveryCost"]) != nil
}

/// After a mutating send is attempted, keep Send locked for the life of the sheet if the outcome is uncertain.
func workbenchMutationSendAllowed(attempted: Bool, succeeded: Bool) -> (Bool, String?) {
    if succeeded { return (false, nil) }
    if attempted {
        return (false, "The result is unknown. Check Orders (or reload this order) before trying again.")
    }
    return (true, nil)
}

/// Replaces the review's unknown-outcome note once a reload shows the recorded action's outcome and lifts the lock.
func workbenchReloadResolvedNote(status: String) -> String {
    "The reload shows the outcome: Slant now lists this order as “\(orderStatusTitle(status))”."
}

/// Cross-sheet lock copy when `StudioStore.isOutcomeUnknown` is set for this order.
let workbenchUnknownOutcomeBlockMessage =
    "A previous attempt for this order has an unknown result. Reload the order; if its status hasn’t changed, check it in your Slant dashboard before trying again."

/// Gating for DELETE /orders/{publicOrderId}. Uses the same cancellation eligibility as OrdersView.
func workbenchCancelAllowed(status: String?, loaded: Bool) -> (Bool, String?) {
    guard loaded else { return (false, "Couldn’t load this order.") }
    if let reason = orderCancellationBlockedReason(status ?? "") { return (false, reason) }
    return (true, nil)
}

/// Whether the confirm-sheet send button may bind Return (`.defaultAction`).
/// Confirm-sheet sends are never Return-default (GET uses Fetch outside the sheet).
func workbenchConfirmSendUsesReturnDefault(method: String, path: String) -> Bool {
    _ = (method, path)
    return false
}

/// The order in a Workbench reply, read exactly as the Orders review reads it (`mergeOrderDraftEnvelope`): a draft
/// envelope's `totals` (and items and customer) are kept, so the unlisted-cost notice and the pre-send comparison both
/// see any cost Slant lists there, and compare like with like.
func workbenchUnwrapOrder(_ object: [String: Any]) -> [String: Any] {
    mergeOrderDraftEnvelope(object)
}

func workbenchOrderRecipient(_ order: [String: Any]) -> String {
    guard let address = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any] else { return "—" }
    let parts = [address["name"], address["line1"], address["line2"], address["city"], address["state"], address["zip"], address["country"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
    return parts.isEmpty ? "—" : parts.joined(separator: ", ")
}

func workbenchDisplayedResponse(path: String, json: Any?, fallback: String, showSecrets: Bool) -> String {
    if path == "/files/openScad" { return fallback }
    guard let json else { return fallback }
    return prettyJSON(showSecrets ? json : hidingSecrets(json))
}

/// True when preview and fresh share the same status, printing/delivery/total costs and any other cost fields.
func workbenchOrderPreviewMatches(_ preview: [String: Any], _ fresh: [String: Any]) -> Bool {
    let previewStatus = (preview["status"] as? String)?.uppercased() ?? ""
    let freshStatus = (fresh["status"] as? String)?.uppercased() ?? ""
    guard previewStatus == freshStatus else { return false }
    guard workbenchOrderHasNumericTotal(preview), workbenchOrderHasNumericTotal(fresh) else { return false }
    return workbenchCostEqual(preview["printingCost"], fresh["printingCost"])
        && workbenchCostEqual(preview["deliveryCost"], fresh["deliveryCost"])
        && orderTotalMoney(preview) == orderTotalMoney(fresh)
        // A tax or fee field that appeared or changed since the review (`orderUnlistedCosts`).
        && orderUnlistedCostSignature(preview) == orderUnlistedCostSignature(fresh)
}

func workbenchOrderPreviewMismatchMessage(preview: [String: Any], fresh: [String: Any]) -> String? {
    workbenchOrderPreviewMatches(preview, fresh) ? nil : "This order changed since you reviewed it. Go back and review again."
}

func workbenchCostEqual(_ left: Any?, _ right: Any?) -> Bool {
    switch (decimalAmount(left), decimalAmount(right)) {
    case (nil, nil): return true
    case let (l?, r?): return l == r
    default: return false
    }
}

/// Path parameter after a fixed prefix; empty when missing (fail-closed for typed confirm).
func workbenchPathParameter(_ path: String, after prefix: String) -> String {
    guard path.hasPrefix(prefix) else { return "" }
    return String(path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init) ?? ""
}

/// Baked confirm phrase at prepare time. High-risk deletes always return a String (empty = fail-closed).
func workbenchBakedConfirmPhrase(method: String, templatePath: String, resolvedPath: String) -> String? {
    if method == "PATCH", templatePath == "/platforms/{platformId}/webhook-secret" { return "rotate" }
    if method == "DELETE", templatePath == "/platforms/{platformId}" {
        return workbenchPathParameter(resolvedPath, after: "/platforms/")
    }
    if method == "DELETE", templatePath == "/files/{publicFileId}" {
        return workbenchPathParameter(resolvedPath, after: "/files/")
    }
    return nil
}

/// Fail-closed typed confirm against the baked phrase (never against live parameter fields).
func workbenchTypedConfirmationAllowed(bakedPhrase: String?, typed: String) -> (Bool, String?) {
    guard let bakedPhrase else { return (true, nil) }
    if bakedPhrase.isEmpty { return (false, "Enter the target id to confirm.") }
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed == bakedPhrase, nil)
}

func workbenchDeleteWarning(path: String) -> String {
    switch path {
    case "/orders/{publicOrderId}":
        return "Cancels the order and refunds it. If it already shipped, Slant only refunds it."
    case "/platforms/{platformId}":
        return "Disables this platform."
    case "/files/{publicFileId}":
        return "Deletes this uploaded model."
    default:
        return "This changes production data. Review the target ID carefully."
    }
}

/// Live `POST /orders/batch` accepts only `publicIds` and refuses the original OpenAPI's `public_ids` with 400 “No
/// public IDs provided” (docs/API_REFERENCE.md). The bundled spec now asks for `publicIds`; a body typed with the old
/// spelling is sent with the one Slant accepts.
func normalizedRequestBody(_ value: Any, endpointID: String) -> Any {
    guard endpointID == "POST /orders/batch", var object = value as? [String: Any],
          object["publicIds"] == nil, let legacy = object.removeValue(forKey: "public_ids") else { return value }
    object["publicIds"] = legacy
    return object
}

/// The orders in a `POST /orders/batch` reply: live Slant returns `data: [order]`; the original spec described
/// `data: [{order}]`, which is accepted too. Nil when the reply has no `data` array.
func ordersBatchReplyOrders(_ json: Any?) -> [[String: Any]]? {
    guard let rows = (json as? [String: Any])?["data"] as? [Any] else { return nil }
    return rows.compactMap { row in
        guard let object = row as? [String: Any] else { return nil }
        return object["order"] as? [String: Any] ?? object
    }
}

/// The Workbench's draft create, which gets the composer's marker and unconfirmed-draft guard.
let workbenchDraftCreateEndpointID = "POST /orders"

let workbenchDifferentOrderMessage = "Slant returned a different order. Check the order ID and review again."

/// Whether an order Slant returned is the one the Workbench asked for: its `publicId` or `id` equals the typed ID
/// (as sent, percent-decoded), ignoring case only, since Slant itself routed the typed ID to that order.
func workbenchOrderMatchesRequestedID(_ order: [String: Any], requested: String) -> Bool {
    let typed = (requested.removingPercentEncoding ?? requested).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !typed.isEmpty else { return false }
    if orderBelongs(order, to: typed) { return true }
    return [order["publicId"] as? String, order["id"] as? String].contains { candidate in
        guard let candidate else { return false }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(typed) == .orderedSame
    }
}

/// After a 2xx Workbench pay: the order to judge it by, as the Orders review does (`orderPayAcceptedOrder`): the
/// re-read when it is the requested order, else the reply when it is; nil when neither is.
func workbenchPayAcceptedOrder(replied: [String: Any]?, refreshed: [String: Any]?, requested: String) -> [String: Any]? {
    if let refreshed, workbenchOrderMatchesRequestedID(refreshed, requested: requested) { return refreshed }
    if let replied, workbenchOrderMatchesRequestedID(replied, requested: requested) { return replied }
    return nil
}

/// Whether a 2xx Workbench pay keeps the shared lock: the order still shows DRAFT, or no readable status (including
/// no readable order at all), so the charge may still happen (`batchPayAcceptedOutcomeStaysLocked`).
func workbenchPayAcceptedKeepsLock(replied: [String: Any]?, refreshed: [String: Any]?, requested: String) -> Bool {
    batchPayAcceptedOutcomeStaysLocked(workbenchPayAcceptedOrder(replied: replied, refreshed: refreshed, requested: requested))
}

func validateJSON(_ value: Any, schema: [String: Any], path: String = "body") throws {
    if let object = value as? [String: Any] {
        for name in schema["required"] as? [String] ?? [] {
            guard let field = object[name], !(field is NSNull) else { throw StudioError("\(path).\(name) is required.") }
            if let string = field as? String, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StudioError("\(path).\(name) is required.") }
        }
        if let maxProperties = schema["maxProperties"] as? Int, object.count > maxProperties {
            throw StudioError("\(path) must have at most \(maxProperties) fields.")
        }
        for (key, child) in schema["properties"] as? [String: [String: Any]] ?? [:] {
            if let field = object[key] { try validateJSON(field, schema: child, path: "\(path).\(key)") }
        }
    } else if let array = value as? [Any], let child = schema["items"] as? [String: Any] {
        for (index, item) in array.enumerated() { try validateJSON(item, schema: child, path: "\(path)[\(index)]") }
    }
    if let string = value as? String {
        if let minLength = schemaInt(schema["minLength"]), string.count < minLength {
            throw StudioError("\(path) must be at least \(minLength) characters.")
        }
        if let maxLength = schemaInt(schema["maxLength"]), string.count > maxLength {
            throw StudioError("\(path) must be at most \(maxLength) characters.")
        }
        if let pattern = schema["pattern"] as? String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { throw StudioError("\(path) has an invalid pattern constraint.") }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            guard regex.firstMatch(in: string, range: range) != nil else { throw StudioError("\(path) does not match the required pattern.") }
        }
        if let options = schema["enum"] as? [String], !options.contains(string) {
            throw StudioError("\(path) must be one of: \(options.joined(separator: ", ")).")
        }
    }
    if let minimum = schemaDouble(schema["minimum"]), let number = value as? NSNumber, number.doubleValue < minimum { throw StudioError("\(path) must be at least \(minimum).") }
    if let maximum = schemaDouble(schema["maximum"]), let number = value as? NSNumber, number.doubleValue > maximum { throw StudioError("\(path) must be at most \(maximum).") }
}

func schemaInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let int = value as? Int { return int }
    return nil
}

func schemaDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    return nil
}

func validateQueryParameter(name: String, value: String, schema: [String: Any]) throws {
    if let options = schema["enum"] as? [String], !options.contains(value) {
        throw StudioError("\(name) must be one of: \(options.joined(separator: ", ")).")
    }
    if schema["type"] as? String == "integer" || schema["type"] as? String == "number" {
        guard let number = Double(value) else { throw StudioError("\(name) must be a number.") }
        if let minimum = schemaDouble(schema["minimum"]), number < minimum { throw StudioError("\(name) must be at least \(minimum).") }
        if let maximum = schemaDouble(schema["maximum"]), number > maximum { throw StudioError("\(name) must be at most \(maximum).") }
    }
    if let minLength = schemaInt(schema["minLength"]), value.count < minLength {
        throw StudioError("\(name) must be at least \(minLength) characters.")
    }
    if let maxLength = schemaInt(schema["maxLength"]), value.count > maxLength {
        throw StudioError("\(name) must be at most \(maxLength) characters.")
    }
    if let pattern = schema["pattern"] as? String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { throw StudioError("\(name) has an invalid pattern constraint.") }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard regex.firstMatch(in: value, range: range) != nil else { throw StudioError("\(name) does not match the required pattern.") }
    }
}

/// Docs: order metadata ≤10 fields and depth ≤3.
func validateOrderMetadata(_ value: Any, path: String = "body.metadata", depth: Int = 1) throws {
    guard let object = value as? [String: Any] else { throw StudioError("\(path) must be an object.") }
    if depth == 1, object.count > 10 { throw StudioError("\(path) must have at most 10 fields.") }
    guard depth <= 3 else { throw StudioError("\(path) exceeds the maximum metadata depth of 3.") }
    for (key, child) in object {
        if child is [String: Any] {
            try validateOrderMetadata(child, path: "\(path).\(key)", depth: depth + 1)
        } else if let array = child as? [Any] {
            for (index, item) in array.enumerated() where item is [String: Any] {
                try validateOrderMetadata(item, path: "\(path).\(key)[\(index)]", depth: depth + 1)
            }
        }
    }
}
