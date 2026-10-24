import SwiftUI

// MARK: - One-time consent to send photos to a service
//
// Before the first photo goes to Anthropic, Meshy or Tripo3D, Studio says what will be sent and asks once per
// service. Only a yes/no and the date it was given are kept, in preferences; never the image, the details typed or
// anything about a customer. Settings › Design Tools › Photo sharing shows each answer and can reset it.

enum ImageSharingService: String, CaseIterable, Identifiable, Sendable {
    case anthropic, meshy, tripo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .meshy: return "Meshy"
        case .tripo: return "Tripo3D"
        }
    }

    /// What goes to this service, as a phrase that follows "Studio sends <service>".
    var sentDescription: String {
        switch self {
        case .anthropic:
            return "the photo you choose, the details you type (such as measurements and notes) and pictures Studio renders of the models it makes"
        case .meshy, .tripo:
            return self == .meshy
                ? "the photos you choose (and, if you use its free printability check, the size you typed)"
                : "the photos you choose"
        }
    }
}

struct ImageSharingConsentText: Equatable {
    let title: String
    let message: String
    let allowButton: String
    let cancelButton: String
}

/// The confirmation wording: names the service and exactly what is sent.
func imageSharingConsentText(_ service: ImageSharingService) -> ImageSharingConsentText {
    ImageSharingConsentText(
        title: "Send photos to \(service.displayName)?",
        message: "To do this, Studio sends \(service.displayName) \(service.sentDescription). "
            + "Photos are resized and their location, camera and other hidden details are removed first. "
            + "\(service.displayName) handles what it receives under its own terms and privacy policy. "
            + "Don’t include customers’ names, addresses or other personal details. "
            + "Studio asks once; you can reset this in Settings › Design Tools › Photo sharing.",
        allowButton: "Allow and Send",
        cancelButton: "Don’t Send")
}

/// "Allowed on 24 Oct 2026" or "Not allowed yet".
func imageSharingConsentStatusLine(granted: Bool, date: Date?, calendar: Calendar = .current, locale: Locale = .current) -> String {
    guard granted else { return "Not allowed yet" }
    guard let date else { return "Allowed" }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
    return "Allowed on \(formatter.string(from: date))"
}

/// The saved answers. `shared` uses the standard preferences; tests pass their own suite.
@MainActor final class ImageSharingConsentStore: ObservableObject {
    static let shared = ImageSharingConsentStore()

    private let defaults: UserDefaults
    /// Bumped on every change so views showing the answers refresh.
    @Published private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func grantedKey(_ service: ImageSharingService) -> String { "imageSharingConsent.\(service.rawValue)" }
    static func dateKey(_ service: ImageSharingService) -> String { "imageSharingConsent.\(service.rawValue).date" }

    func hasConsented(_ service: ImageSharingService) -> Bool {
        defaults.bool(forKey: Self.grantedKey(service))
    }

    func consentDate(_ service: ImageSharingService) -> Date? {
        guard hasConsented(service), let seconds = defaults.object(forKey: Self.dateKey(service)) as? Double, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func grant(_ service: ImageSharingService, now: Date = Date()) {
        defaults.set(true, forKey: Self.grantedKey(service))
        defaults.set(now.timeIntervalSince1970, forKey: Self.dateKey(service))
        revision += 1
    }

    func reset(_ service: ImageSharingService) {
        defaults.removeObject(forKey: Self.grantedKey(service))
        defaults.removeObject(forKey: Self.dateKey(service))
        revision += 1
    }
}

// MARK: Asking before the first send

/// A pending send waiting for consent. `send` runs only after Allow and Send.
struct ImageSharingConsentRequest: Identifiable {
    let id = UUID()
    let service: ImageSharingService
    let send: @MainActor () -> Void
}

extension View {
    /// Asks for consent when `request` is set; Allow and Send saves the answer and runs the request's `send`.
    /// Don't Send is the default button and Escape cancels, so Return never shares a photo.
    ///
    ///     if ImageSharingConsentStore.shared.hasConsented(.anthropic) { start() }
    ///     else { consentRequest = ImageSharingConsentRequest(service: .anthropic) { start() } }
    ///     …
    ///     .imageSharingConsent($consentRequest)
    @MainActor func imageSharingConsent(_ request: Binding<ImageSharingConsentRequest?>,
                                        store: ImageSharingConsentStore? = nil) -> some View {
        modifier(ImageSharingConsentModifier(request: request, store: store ?? .shared))
    }
}

/// Runs `send` at once when the service already has consent; otherwise sets `request` so the modifier asks first.
@MainActor func runWithImageSharingConsent(_ service: ImageSharingService, request: Binding<ImageSharingConsentRequest?>,
                                           store: ImageSharingConsentStore? = nil, send: @escaping @MainActor () -> Void) {
    if (store ?? .shared).hasConsented(service) {
        send()
    } else {
        request.wrappedValue = ImageSharingConsentRequest(service: service, send: send)
    }
}

private struct ImageSharingConsentModifier: ViewModifier {
    @Binding var request: ImageSharingConsentRequest?
    let store: ImageSharingConsentStore

    func body(content: Content) -> some View {
        let text = request.map { imageSharingConsentText($0.service) }
        content.confirmationDialog(text?.title ?? "", isPresented: Binding(
            get: { request != nil },
            set: { if !$0 { request = nil } }
        ), titleVisibility: .visible, presenting: request) { pending in
            Button(text?.allowButton ?? "Allow and Send") {
                store.grant(pending.service)
                request = nil
                pending.send()
            }
            Button(text?.cancelButton ?? "Don’t Send", role: .cancel) { request = nil }
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text(text?.message ?? "")
        }
    }
}

// MARK: Settings

/// Settings › Design Tools › Photo sharing: each service's answer, with Reset.
struct ImageSharingConsentSettingsSection: View {
    @ObservedObject private var consents = ImageSharingConsentStore.shared

    var body: some View {
        Section {
            ForEach(ImageSharingService.allCases) { service in
                LabeledContent(service.displayName) {
                    HStack {
                        Text(imageSharingConsentStatusLine(granted: consents.hasConsented(service), date: consents.consentDate(service)))
                            .foregroundStyle(.secondary)
                        if consents.hasConsented(service) {
                            Button("Reset") { consents.reset(service) }
                                .help("Ask again before the next photo goes to \(service.displayName)")
                        }
                    }
                }
                // Reads the revision so the rows refresh after a grant or reset.
                .id("\(service.rawValue)-\(consents.revision)")
            }
        } header: {
            Text("Photo sharing")
        } footer: {
            Text("Studio asks once per service before sending it a photo. Only your answer and its date are kept on this Mac; Studio doesn’t keep the photos or details you send.")
                .settingsFooterLayout()
        }
    }
}
