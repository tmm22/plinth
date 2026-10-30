import Foundation

// MARK: - The seller's own address (for samples)

/// The seller's own delivery address, saved only when they choose to in Settings › Account and removable there.
/// Used only when they press Use My Address or Order a Sample to Me…. Customer addresses are never saved this way.
struct SellerAddress: Codable, Equatable {
    var name = ""
    var email = ""
    /// Two-letter country code, as the composer's country picker uses.
    var country = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var zip = ""
}

// Decoding tolerates missing keys and odd types (a hand-edited file) instead of losing the address.
extension SellerAddress {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            // A postcode typed into the file as a bare number.
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
            return ""
        }
        self.init(name: text(.name), email: text(.email), country: text(.country), line1: text(.line1),
                  line2: text(.line2), city: text(.city), state: text(.state), zip: text(.zip))
    }
}

let sellerAddressFileName = "seller-address.json"

/// Where an unreadable address file is kept before the next save can replace it.
func sellerAddressBackupURL(for url: URL) -> URL {
    url.deletingPathExtension().appendingPathExtension("unreadable.json")
}

/// The trimmed address with an upper-case country code.
func sellerAddressTrimmed(_ address: SellerAddress) -> SellerAddress {
    func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    return SellerAddress(name: clean(address.name), email: clean(address.email), country: clean(address.country).uppercased(),
                         line1: clean(address.line1), line2: clean(address.line2), city: clean(address.city),
                         state: clean(address.state), zip: clean(address.zip))
}

/// True when nothing but (possibly) the country has been filled in.
func sellerAddressIsBlank(_ address: SellerAddress) -> Bool {
    let trimmed = sellerAddressTrimmed(address)
    return [trimmed.name, trimmed.email, trimmed.line1, trimmed.line2, trimmed.city, trimmed.state, trimmed.zip].allSatisfy(\.isEmpty)
}

/// The saved address from disk, or nil when there is none. A file that can't be read is first copied beside it
/// (`seller-address.unreadable.json`) so the next save can't lose it; Remove deletes both.
func loadSellerAddress(from url: URL) -> SellerAddress? {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    guard let address = try? JSONDecoder().decode(SellerAddress.self, from: data) else {
        try? data.write(to: sellerAddressBackupURL(for: url), options: .atomic)
        return nil
    }
    return sellerAddressIsBlank(address) ? nil : sellerAddressTrimmed(address)
}

/// Why this address can't be saved yet, or nil. It must be complete enough for a draft: the same fields
/// `orderDraftPayload` requires, so Use My Address never fills in an address that can't be sent.
func sellerAddressSaveBlockedReason(_ address: SellerAddress) -> String? {
    let trimmed = sellerAddressTrimmed(address)
    if trimmed.name.isEmpty { return "Enter your name." }
    if !isEmailAddress(trimmed.email) { return "Enter an email like name@example.com." }
    if !isCountryCode(trimmed.country) || orderNonCountryRegionCodes.contains(trimmed.country) { return "Choose your country." }
    if trimmed.line1.isEmpty { return "Enter your street address." }
    if trimmed.city.isEmpty { return "Enter your city." }
    if orderStateIsRequired(trimmed.country), trimmed.state.isEmpty { return "Enter your state or province." }
    if trimmed.zip.isEmpty { return "Enter your postal code." }
    return nil
}

/// The composer's delivery fields filled from the seller's address (country through the composer's own picker rules).
func deliveryDetails(fromSellerAddress address: SellerAddress) -> DeliveryDetails {
    let trimmed = sellerAddressTrimmed(address)
    var delivery = DeliveryDetails()
    delivery.name = trimmed.name
    delivery.email = trimmed.email
    delivery.line1 = trimmed.line1
    delivery.line2 = trimmed.line2
    delivery.city = trimmed.city
    delivery.state = trimmed.state
    delivery.zip = trimmed.zip
    return deliveryApplyingCountryPick(trimmed.country, to: delivery)
}

/// True when the delivery fields hold something typed or copied (the country alone, a default, doesn't count).
func deliveryHasEnteredDetails(_ delivery: DeliveryDetails) -> Bool {
    [delivery.name, delivery.email, delivery.line1, delivery.line2, delivery.city, delivery.state, delivery.zip]
        .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Use My Address never silently replaces details already in the form: it asks first unless the form is empty or
/// already holds exactly this address. A country the seller picked counts as entered when the address would change
/// it; the Mac-region default alone never does.
func useMyAddressNeedsConfirmation(current: DeliveryDetails, replacement: DeliveryDetails, countryPicked: Bool = false) -> Bool {
    guard current != replacement else { return false }
    if deliveryHasEnteredDetails(current) { return true }
    return countryPicked && orderCountryPickerValue(current) != orderCountryPickerValue(replacement)
}

/// One line for Settings and the composer, such as "Ada Lovelace, London, GB".
func sellerAddressSummary(_ address: SellerAddress) -> String {
    let trimmed = sellerAddressTrimmed(address)
    return [trimmed.name, trimmed.city, trimmed.country].filter { !$0.isEmpty }.joined(separator: ", ")
}

/// Why Order a Sample to Me… can't open the composer, or nil. A missing address is handled separately (it explains
/// and opens Settings).
func sampleOrderBlockedReason(fileID: String?, draftBlockedReason: String?, composerOpen: Bool, busy: Bool) -> String? {
    if (fileID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Upload this model first." }
    if let draftBlockedReason { return draftBlockedReason }
    if composerOpen { return "Finish or close the open order draft first." }
    if busy { return "Working…" }
    return nil
}

/// The composer prefill for a sample: the model, the chosen material (or the default one), quantity 1 and the
/// seller's address. Nothing is created: the user reviews it and presses Create Draft, then pays through the review.
func sampleOrderPrefill(fileID: String, filamentID: String, defaultFilamentID: String?, address: SellerAddress) -> OrderComposerPrefill {
    let material = filamentID.isEmpty ? (defaultFilamentID ?? "") : filamentID
    var prefill = OrderComposerPrefill(lines: [OrderLine(reference: fileID, filamentID: material, quantity: 1)],
                                       delivery: deliveryDetails(fromSellerAddress: address))
    prefill.usesSellerAddress = true
    return prefill
}

/// The files Remove deletes. `required`: the address and its unreadable copy in the folder in use (a failure is
/// reported). `bestEffort`: the same two files in Slant Studio's folder, passed only by the packaged Plinth app, which
/// copied them there from (failures ignored), so "It is deleted from this Mac" stays true. Nothing else in that folder
/// is ever touched, and a file already listed as required isn't listed again.
func sellerAddressFilesToRemove(supportDirectory: URL, slantStudioDirectory: URL?) -> (required: [URL], bestEffort: [URL]) {
    func files(in folder: URL) -> [URL] {
        let address = folder.appendingPathComponent(sellerAddressFileName)
        return [address, sellerAddressBackupURL(for: address)]
    }
    let required = files(in: supportDirectory)
    guard let slantStudioDirectory else { return (required, []) }
    let requiredPaths = Set(required.map { $0.standardizedFileURL.path })
    let bestEffort = files(in: slantStudioDirectory).filter { !requiredPaths.contains($0.standardizedFileURL.path) }
    return (required, bestEffort)
}

extension StudioStore {
    static var sellerAddressURL: URL { supportDirectory.appendingPathComponent(sellerAddressFileName) }

    /// Saves the seller's own address on this Mac. Never recorded in Activity or logs.
    func saveSellerAddress(_ address: SellerAddress) throws {
        if let reason = sellerAddressSaveBlockedReason(address) { throw StudioError(reason) }
        let trimmed = sellerAddressTrimmed(address)
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(trimmed).write(to: Self.sellerAddressURL, options: .atomic)
        try? FileManager.default.removeItem(at: sellerAddressBackupURL(for: Self.sellerAddressURL))
        sellerAddress = trimmed
    }

    /// Deletes the saved address (and any unreadable copy of it) from this Mac, including the copy the app kept under
    /// its old name (`sellerAddressFilesToRemove`).
    func removeSellerAddress() throws {
        let files = sellerAddressFilesToRemove(supportDirectory: Self.supportDirectory,
                                               slantStudioDirectory: AppSupportLocation.slantStudioDirectory)
        // The old app's copies first and ignoring failures, so they go even when the current copy can't be removed.
        for url in files.bestEffort where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        for url in files.required where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        sellerAddress = nil
    }

    /// Order a Sample to Me…: opens the normal composer prefilled for review. Without a saved address it explains
    /// and offers Settings instead. Does nothing under a sheet, alert or dialog.
    func orderSampleToMe(fileID: String?) {
        guard !isPresentingSheet, !appIsPresentingModalUI() else { return }
        if let reason = sampleOrderBlockedReason(fileID: fileID, draftBlockedReason: orderDraftBlockedReason,
                                                 composerOpen: showOrderComposer, busy: busy) {
            showError(reason)
            return
        }
        guard let address = sellerAddress, let fileID else {
            showSellerAddressNeeded = true
            return
        }
        openOrderComposer(prefill: sampleOrderPrefill(fileID: fileID, filamentID: filamentID,
                                                      defaultFilamentID: defaultFilamentID, address: address))
    }
}
