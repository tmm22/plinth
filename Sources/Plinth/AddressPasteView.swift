import SwiftUI
import AppKit

/// The pasteboard's plain text for Paste Address…, read only when the seller presses it (AddressPaste.swift).
/// Text that doesn't look like an address is left out (`addressPasteClipboardPrefill`), so it never shows on screen.
@MainActor
func addressPastePasteboardText(_ pasteboard: NSPasteboard = .general) -> (text: String, skippedNonAddress: Bool) {
    let types = pasteboard.types ?? []
    return addressPasteClipboardPrefill(pasteboard.availableType(from: [.string]) == nil ? nil : pasteboard.string(forType: .string),
                                        holdsFileURL: types.contains(.fileURL))
}

/// The order composer's Paste Address… popover: a text box, the details read from it for review, and Use These
/// Details, which is the only thing that changes the form. When that would replace details already in the form
/// (`needsConfirmation`), the popover asks first, with Keep Current Details as the default. The text lives in this
/// view's memory only.
struct AddressPastePopover: View {
    @State private var text: String
    @State private var parsed = PastedAddress()
    @State private var confirming = false
    /// The clipboard's text was left out because it doesn't look like an address.
    let skippedClipboard: Bool
    /// The form's details as they are now, for what the review says is kept (name, email, country).
    let current: DeliveryDetails
    let needsConfirmation: (PastedAddress) -> Bool
    let onUse: (PastedAddress) -> Void
    let onCancel: () -> Void

    var usable: Bool { pastedAddressLooksLikeAddress(parsed) }

    init(initialText: String, skippedClipboard: Bool = false, current: DeliveryDetails,
         needsConfirmation: @escaping (PastedAddress) -> Bool,
         onUse: @escaping (PastedAddress) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: initialText)
        self.skippedClipboard = skippedClipboard
        self.current = current
        self.needsConfirmation = needsConfirmation
        self.onUse = onUse
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste address").font(.headline)
            Text("Paste the buyer’s address as it appears in Etsy, Shopify or an email. Phone numbers are ignored, and nothing is saved.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Pasted address")
            if text.count > addressPasteMaxCharacters {
                Text("Only the first \(addressPasteMaxCharacters) characters are read.").font(.caption).foregroundStyle(.orange)
            }
            review
            if confirming {
                Label(pastedAddressReplaceWarning(parsed, current: current), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Replace Details") { onUse(parsed) }
                    // Return keeps what's in the form.
                    Button("Keep Current Details") { confirming = false }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    // No Return shortcut: Return types a new line in the text box.
                    Button("Use These Details") {
                        if needsConfirmation(parsed) { confirming = true } else { onUse(parsed) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!usable)
                    .help(usable ? "Fill in the delivery details from this address, for you to check" : "Paste an address first")
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { parsed = parsePastedAddressDetecting(text) }
        .onChange(of: text) { _, value in
            parsed = parsePastedAddressDetecting(value)
            confirming = false
        }
    }

    @ViewBuilder
    var review: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(skippedClipboard
                 ? "The clipboard doesn’t hold an address, so nothing was pasted. Paste the address into the box."
                 : "Nothing pasted yet.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !parsed.foundAddress {
            Text("No address found. Paste the whole address, with the street, town and postcode.")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if !usable {
            // The parsed parts aren't listed: this text may be anything that was on the clipboard.
            Text("This doesn’t look like an address. Paste the whole address, with the street, town and postcode.")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check these details").font(.subheadline.weight(.semibold))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    row("Name", parsed.name, missing: "Not found (the current name is kept)")
                    row("Email", parsed.email, missing: "Not found (the current email is kept)")
                    row("Street address", parsed.line1, missing: "Not found")
                    if !parsed.line2.isEmpty { row("Apartment, suite, etc.", parsed.line2, missing: "") }
                    row("City", parsed.city, missing: "Not found")
                    if !parsed.state.isEmpty { row("State / province", parsed.state, missing: "") }
                    row("Postal code", parsed.zip, missing: "Not found")
                    GridRow {
                        Text("Country").foregroundStyle(.secondary)
                        countryText
                    }
                }
                .font(.callout)
                if !parsed.unused.isEmpty {
                    Text("Not used: \(parsed.unused.joined(separator: "; "))")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text("Using these replaces the address in the form, including any apartment or unit number.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    var countryText: some View {
        switch pastedAddressCountryDisplay(parsed, current: current) {
        case .pasted(let code):
            Text(Locale.current.localizedString(forRegionCode: code) ?? code)
        case .unrecognised(let text):
            Text("“\(text)” isn’t recognised. Choose the country in the form.").foregroundStyle(.orange)
        case .keptFromForm(let code):
            if let warning = pastedAddressKeptCountryWarning(parsed, keptCode: code) {
                Text(warning).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(Locale.current.localizedString(forRegionCode: code) ?? code) (kept from the form)")
            }
        case .missing:
            Text("Not found. Choose the country in the form.").foregroundStyle(.orange)
        }
    }

    func row(_ label: String, _ value: String, missing: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.isEmpty ? missing : value)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(2)
        }
    }
}
