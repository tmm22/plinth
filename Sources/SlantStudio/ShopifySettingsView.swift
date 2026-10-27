import SwiftUI

// MARK: - Settings › Account › Shopify

enum ShopifySignInKind: String, CaseIterable, Identifiable {
    case app, accessToken
    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: return "Dev Dashboard app"
        case .accessToken: return "Access token (older custom app)"
        }
    }
}

/// The credential the form describes, or the first problem with it.
func shopifyFormCredential(kind: ShopifySignInKind, clientID: String, clientSecret: String, accessToken: String) -> Result<ShopifyCredential, StudioError> {
    func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    switch kind {
    case .app:
        if let problem = shopifyCredentialFieldProblem(clientID, name: "client ID") { return .failure(StudioError(problem)) }
        if let problem = shopifyCredentialFieldProblem(clientSecret, name: "client secret") { return .failure(StudioError(problem)) }
        return .success(.app(clientID: trimmed(clientID), clientSecret: trimmed(clientSecret)))
    case .accessToken:
        if let problem = shopifyCredentialFieldProblem(accessToken, name: "access token") { return .failure(StudioError(problem)) }
        return .success(.accessToken(trimmed(accessToken)))
    }
}

/// One line about what the app may do, from Test Connection's scopes.
func shopifyScopeStatusLine(_ scopes: ShopifyScopeSummary) -> String {
    switch (scopes.canReadOrders, scopes.canFulfil) {
    case (true, true): return "Studio can import orders and send tracking."
    case (true, false): return "Studio can import orders. To send tracking too, add write_merchant_managed_fulfillment_orders."
    case (false, true): return "Studio can send tracking, but can’t read orders: add read_orders."
    case (false, false): return "The app has neither read_orders nor a fulfilment scope, so Studio can’t use it yet."
    }
}

let shopifySetupSteps = """
1. In Shopify admin, open Settings › Apps › Develop apps › Build apps in Dev Dashboard, and create an app.
2. Create a version with the scopes read_orders and, to send tracking, write_merchant_managed_fulfillment_orders. Release it.
3. Install the app on your store, then copy its client ID and secret from the app’s Settings.
"""

/// Optional: the seller's own Shopify store, for Import Orders › Fetch from Shopify and Send Tracking to Shopify….
/// The credentials go to their own Keychain item; nothing is sent anywhere but the store's myshopify.com address.
struct ShopifySettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = ShopifyConnection.shared
    @State private var shopField = ""
    @State private var kind: ShopifySignInKind = .app
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var accessToken = ""
    @State private var status: String?
    @State private var problem: String?
    @State private var testing = false
    @State private var confirmDisconnect = false

    var body: some View {
        Section {
            if let shop = connection.shop {
                LabeledContent("Store", value: shop)
                HStack {
                    Button("Test Connection") { testSaved() }
                        .disabled(connection.busy || testing)
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                        .disabled(connection.connectionChangeBlockedReason != nil || testing)
                        .help(connection.connectionChangeBlockedReason ?? "Remove the Shopify details from this Mac")
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                }
                if connection.openTrackingSheets > 0 {
                    Text("Send Tracking to Shopify is open, so the store can’t be changed until it’s closed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                TextField("Store address", text: $shopField, prompt: Text("your-store.myshopify.com"))
                if !shopField.trimmingCharacters(in: .whitespaces).isEmpty, shopifyShopDomain(shopField) == nil {
                    Text("Enter the store’s myshopify.com address, such as your-store.myshopify.com.").font(.caption).foregroundStyle(.orange)
                }
                Picker("Sign in with", selection: $kind) {
                    ForEach(ShopifySignInKind.allCases) { Text($0.title).tag($0) }
                }
                if kind == .app {
                    TextField("Client ID", text: $clientID, prompt: Text("Required"))
                    SecureField("Client secret", text: $clientSecret, prompt: Text("Required"))
                } else {
                    SecureField("Admin API access token", text: $accessToken, prompt: Text("shpat_…"))
                }
                HStack {
                    Button("Connect & Test") { connect() }
                        .disabled(shopifyShopDomain(shopField) == nil || connection.connectionChangeBlockedReason != nil || testing)
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                }
            }
            if let status {
                Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Shopify (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if connection.shop == nil {
                    Text(shopifySetupSteps)
                    Text("Shopify shares customers’ names and addresses with custom apps on its Grow plan or higher.")
                }
                Text("Import Orders › Fetch from Shopify and Tracking for Your Shop › Send Tracking to Shopify use these details. They are kept in the macOS Keychain on this Mac, and Studio contacts only your store’s myshopify.com address.")
                Link("Shopify’s Guide to Dev Dashboard Apps", destination: URL(string: "https://help.shopify.com/en/manual/apps/app-types/custom-apps")!)
            }
            .settingsFooterLayout()
        }
        .confirmationDialog("Disconnect Shopify?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Keep Connected", role: .cancel) {}
        } message: {
            Text("This removes the Shopify details from the Keychain on this Mac. Your store and its app are unchanged.")
        }
    }

    /// Tests the typed details and saves them only when Shopify accepts them.
    private func connect() {
        status = nil
        problem = nil
        guard let shop = shopifyShopDomain(shopField) else {
            problem = "Enter the store’s myshopify.com address."
            return
        }
        let credential: ShopifyCredential
        switch shopifyFormCredential(kind: kind, clientID: clientID, clientSecret: clientSecret, accessToken: accessToken) {
        case .success(let value): credential = value
        case .failure(let error): problem = error.message; return
        }
        guard let client = ShopifyClient(shop: shop, credential: credential) else { problem = "Enter the store’s myshopify.com address."; return }
        run(client) { result in
            do {
                try connection.save(shop: shop, credential: credential, client: client)
            } catch {
                client.invalidate()
                problem = "Couldn’t save the Shopify details: \(shopifyRedacted(error.localizedDescription, secrets: credential.secrets))"
                return
            }
            clientID = ""; clientSecret = ""; accessToken = ""; shopField = ""
            show(result)
            store.activities.insert(Activity(title: "Connect Shopify", detail: "Connected", success: true), at: 0)
        } failure: {
            client.invalidate()
        }
    }

    private func testSaved() {
        status = nil
        problem = nil
        do {
            let client = try connection.currentClient()
            run(client) { result in show(result) } failure: {}
        } catch {
            problem = shopifyRedacted(error.localizedDescription)
        }
    }

    /// The store, its plan and scopes; on a plan that withholds customers' names and addresses, a warning too.
    private func show(_ result: ShopifyConnectionTest) {
        status = shopifyConnectionStatusLine(result)
        problem = result.customerDataLikelyWithheld ? shopifyCustomerDataPlanAdvice : nil
    }

    /// The read-only shop query. Marks the connection busy, so a fetch or send can't start alongside.
    private func run(_ client: ShopifyClient, success: @escaping (ShopifyConnectionTest) -> Void, failure: @escaping () -> Void) {
        guard !connection.busy, !testing else { return }
        testing = true
        connection.busy = true
        Task { @MainActor in
            defer { testing = false; connection.busy = false }
            do {
                let data = try await client.query(shopifyTestQuery, estimatedCost: 5)
                success(try shopifyConnectionTest(data, expectedShop: client.shop))
            } catch {
                problem = shopifyRedacted(error.localizedDescription)
                failure()
            }
        }
    }

    private func disconnect() {
        if let reason = connection.connectionChangeBlockedReason { problem = reason; return }
        do {
            try connection.disconnect()
            status = nil
            problem = nil
            store.activities.insert(Activity(title: "Disconnect Shopify", detail: "Disconnected", success: true), at: 0)
        } catch {
            problem = "Couldn’t remove the Shopify details: \(error.localizedDescription)"
        }
    }
}
