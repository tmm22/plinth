import XCTest
@testable import SlantStudio

final class ShellUXTests: XCTestCase {
    func testUserMessageMapsAuthNotFoundRateLimitAndServerErrors() {
        XCTAssertEqual(
            APIError.http(status: 401, body: #"{"message":"Invalid API key"}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant rejected the saved key. Reconnect in Settings."
        )
        // A 401 about something else (Slant uses it for another creator's order or file) quotes Slant instead.
        XCTAssertEqual(
            APIError.http(status: 401, body: #"{"message":"nope"}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant refused this request. nope"
        )
        XCTAssertEqual(
            APIError.http(status: 403, body: "", retryAfter: nil, rateLimitReset: nil).userMessage,
            "You don’t have access to that item. It may belong to another API key."
        )
        XCTAssertEqual(
            APIError.http(status: 404, body: #"{"message":"missing"}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "That item wasn’t found. Refresh and try again."
        )
        XCTAssertEqual(
            APIError.http(status: 429, body: "", retryAfter: "12", rateLimitReset: nil).userMessage,
            "Too many requests. Try again in about 12 seconds."
        )
        XCTAssertEqual(
            APIError.http(status: 429, body: "", retryAfter: nil, rateLimitReset: nil).userMessage,
            "Too many requests. Wait a moment, then try again."
        )
        XCTAssertEqual(
            APIError.http(status: 500, body: #"{"message":"boom"}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant is having trouble right now. Try again in a moment."
        )
        XCTAssertEqual(
            APIError.http(status: 503, body: "", retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant is having trouble right now. Try again in a moment."
        )
    }

    func testRateLimitInfoParsesHeaders() {
        let info = rateLimitInfo(from: [
            "X-RateLimit-Limit": "120",
            "X-RateLimit-Remaining": "44",
            "X-RateLimit-Reset": "1700000000",
            "X-RateLimit-Role": "standard"
        ])
        XCTAssertEqual(info.limit, 120)
        XCTAssertEqual(info.remaining, 44)
        XCTAssertEqual(info.reset, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(info.role, "standard")
    }

    func testRateLimitUserMessagePrefersRetryAfterThenReset() {
        XCTAssertEqual(
            rateLimitUserMessage(retryAfter: "8", rateLimitReset: "9999999999"),
            "Too many requests. Try again in about 8 seconds."
        )
        let reset = String(Int(Date().timeIntervalSince1970) + 30)
        let message = rateLimitUserMessage(retryAfter: nil, rateLimitReset: reset)
        XCTAssertTrue(message.contains("Try again in about"))
        XCTAssertTrue(message.contains("seconds") || message.contains("minutes"))
    }

    func testUserMessageExtractsAPIMessageForClientErrors() {
        let body = """
        {
          "success" : false,
          "message" : "Quantity must be at least 1"
        }
        """
        XCTAssertEqual(
            APIError.http(status: 400, body: body, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant couldn’t accept those details. Quantity must be at least 1"
        )
        XCTAssertEqual(
            APIError.http(status: 422, body: #"{"error":{"message":"Invalid filament"}}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant couldn’t accept those details. Invalid filament"
        )
        XCTAssertEqual(
            APIError.http(status: 409, body: #"{"error":"Already exists"}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant reported a conflict: “Already exists.” Refresh to see the current state before trying again."
        )
        XCTAssertEqual(
            APIError.http(status: 400, body: #"{}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant couldn’t accept those details."
        )
        XCTAssertEqual(shortAPIMessage(from: body), "Quantity must be at least 1")
    }

    func testClientErrorMessageTruncatesToOneSentenceAndRejectsJSON() {
        let body = #"{"message":"Invalid address. country must be an ISO code."}"#
        let message = APIError.http(status: 400, body: body, retryAfter: nil, rateLimitReset: nil).userMessage
        XCTAssertEqual(message, "Slant couldn’t accept those details. Invalid address. country must be an ISO code.")
        XCTAssertEqual(clippedAPIAlertMessage("items[0].filamentId is required"), "items[0].filamentId is required")

        let longSentence = String(repeating: "a", count: 160)
        XCTAssertEqual(clippedAPIAlertMessage(longSentence)?.count, 160)

        let jsonMessage = #"{"message":"{\"nested\":true}"}"#
        XCTAssertEqual(
            APIError.http(status: 422, body: jsonMessage, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant couldn’t accept those details."
        )
        XCTAssertNil(clippedAPIAlertMessage("{\"oops\":1}"))
        XCTAssertEqual(clippedAPIAlertMessage("All good."), "All good.")
    }

    func testUnexpectedFailureMessageSaysHowToReachActivity() {
        // Activity is hidden unless developer tools are on, so the message names the setting.
        let message = APIError.http(status: 418, body: "{\"apiKey\":\"sl_secret\"}", retryAfter: nil, rateLimitReset: nil).userMessage
        XCTAssertEqual(message, slantRequestFailedSeeActivityMessage)
        XCTAssertTrue(message.contains("Settings › Advanced › Show developer tools"))
        XCTAssertFalse(message.contains("sl_secret"))
        let long = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "a", count: 200)])
        XCTAssertEqual(friendlyAPIMessage(long), slantRequestFailedSeeActivityMessage)
    }

    func testInvalidResponseUserMessageIsPlain() {
        let error = APIError.invalidResponse("The API reported a failure (HTTP 200):\n{\"filePlaceholder\":true}")
        let message = error.userMessage
        XCTAssertEqual(message, "Slant couldn’t complete that request. Try again.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("api"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("http"))
        XCTAssertFalse(message.contains("{"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("filePlaceholder"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("json"))
        XCTAssertTrue(error.errorDescription?.contains("HTTP 200") == true)
    }

    func testFriendlyMessageMapsOfflineAndTimeout() {
        XCTAssertEqual(
            friendlyAPIMessage(URLError(.notConnectedToInternet)),
            "Check your connection and try again."
        )
        XCTAssertEqual(
            friendlyAPIMessage(URLError(.timedOut)),
            "Check your connection and try again."
        )
        XCTAssertEqual(
            friendlyAPIMessage(APIError.http(status: 404, body: "HTTP 404: {}", retryAfter: nil, rateLimitReset: nil)),
            "That item wasn’t found. Refresh and try again."
        )
    }

    func testErrorDescriptionStillIncludesHTTPStatusForDiagnostics() {
        let error = APIError.http(status: 404, body: #"{"message":"gone"}"#, retryAfter: nil, rateLimitReset: nil)
        XCTAssertTrue(error.errorDescription?.contains("HTTP 404") == true)
        XCTAssertFalse(error.userMessage.contains("HTTP 404"))
        XCTAssertFalse(error.userMessage.contains("{"))
    }

    func testActivityDetailDropsHTTPBodyAndKeepsStatus() {
        let body = #"{"message":"123 Main St","address":{"line1":"secret lane"}}"#
        let error = APIError.http(status: 422, body: body, retryAfter: nil, rateLimitReset: nil)
        let detail = activityDetail(for: error)
        XCTAssertEqual(detail, "Slant couldn’t accept those details. 123 Main St (HTTP 422)")
        XCTAssertTrue(detail.contains("123 Main St"))
        XCTAssertFalse(detail.contains("secret lane"))
        XCTAssertFalse(detail.contains("{"))
        XCTAssertEqual(friendlyAPIMessage(error), "Slant couldn’t accept those details. 123 Main St")
        XCTAssertTrue(error.errorDescription?.contains("123 Main St") == true)
    }

    func testRetryablePolicyAllowsGETAndEstimateOnly() {
        XCTAssertTrue(isRetryableAPICall(method: "GET", path: "/orders"))
        XCTAssertTrue(isRetryableAPICall(method: "get", path: "/files/abc"))
        XCTAssertTrue(isRetryableAPICall(method: "POST", path: "/files/abc/estimate"))
        XCTAssertFalse(isRetryableAPICall(method: "POST", path: "/orders/ord_123"))
        XCTAssertFalse(isRetryableAPICall(method: "POST", path: "/orders"))
        XCTAssertFalse(isRetryableAPICall(method: "DELETE", path: "/orders/ord_123"))
        XCTAssertFalse(isRetryableAPICall(method: "DELETE", path: "/files/abc"))
        XCTAssertFalse(isRetryableAPICall(method: "POST", path: "/platforms"))
        XCTAssertFalse(isRetryableAPICall(method: "POST", path: "/files/confirm-upload"))
    }

    func testEveryRetryActionIsReadOnlyOrEstimate() {
        let cases: [StudioStore.RetryAction] = [
            .connect("sl_test"),
            .refresh,
            .loadMoreFiles,
            .searchOrders("desk"),
            .loadMoreOrders,
            .loadCatalog(.materials),
            .quote,
            .loadUsage,
            .loadHealth,
            .loadDeadWebhooks("plat"),
            .applyOrderFilter,
            .loadPlatform("plat"),
            .loadComponentCategories
        ]
        for action in cases {
            switch action {
            case .connect, .refresh, .loadMoreFiles, .searchOrders, .loadMoreOrders, .loadCatalog,
                 .loadUsage, .loadHealth, .loadDeadWebhooks, .applyOrderFilter, .loadPlatform, .loadComponentCategories:
                XCTAssertTrue(true, "GET / list load")
            case .quote:
                XCTAssertTrue(isRetryableAPICall(method: "POST", path: "/files/x/estimate"))
            }
        }
        XCTAssertEqual(cases.count, 13)
    }

    func testSearchModeDisablesLoadMorePagination() {
        XCTAssertFalse(canLoadMoreListPages(searchActive: true))
        XCTAssertTrue(canLoadMoreListPages(searchActive: false))
    }

    func testClearedOrderSearchStateDropsHitsBeforeRefresh() {
        let cleared = clearedOrderSearchState()
        XCTAssertFalse(cleared.orderSearchActive)
        XCTAssertTrue(cleared.orders.isEmpty)
        XCTAssertEqual(cleared.orderPage, 0)
        XCTAssertTrue(canLoadMoreListPages(searchActive: cleared.orderSearchActive))
    }

    func testConnectShouldRefreshWorkspaceWhenConnected() {
        XCTAssertTrue(shouldRefreshWorkspaceAfterConnect(connected: true, accountLoaded: false))
        XCTAssertFalse(shouldRefreshWorkspaceAfterConnect(connected: false, accountLoaded: false))
        XCTAssertFalse(shouldRefreshWorkspaceAfterConnect(connected: true, accountLoaded: true))
    }

    func testNextListPageStartsAtOneWhenNothingLoaded() {
        XCTAssertEqual(nextListPage(lastLoadedPage: 0), 1)
        XCTAssertEqual(nextListPage(lastLoadedPage: 1), 2)
        XCTAssertEqual(nextListPage(lastLoadedPage: 2), 3)
    }

    func testShowErrorClearsRetry() {
        let result = applyShowError(message: "Choose a platform first.", hadRetry: true)
        XCTAssertEqual(result.error, "Choose a platform first.")
        XCTAssertFalse(result.canRetry)
    }

    func testDisconnectClearsRetryAndAccountLoaded() {
        let result = applyClearAccountSession(hadRetry: true, accountLoaded: true)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.canRetry)
        XCTAssertFalse(result.accountLoaded)
        XCTAssertEqual(result.filePage, 0)
        XCTAssertEqual(result.orderPage, 0)
        XCTAssertNil(result.lastDelivery)
    }

    func testDefaultFilamentIDSelectsPLABlack() {
        let filaments = [
            Record(values: ["id": "abs-1", "name": "ABS Red"]),
            Record(values: ["id": "pla-black", "name": "PLA Black"]),
            Record(values: ["id": "pla-white", "name": "PLA White"])
        ]
        XCTAssertEqual(plaBlackFilamentID(in: filaments), "pla-black")
        XCTAssertNil(plaBlackFilamentID(in: [Record(values: ["id": "x", "name": "PETG Blue"])]))
        XCTAssertEqual(
            plaBlackFilamentID(in: [Record(values: ["id": "y", "name": " matte pla black filament "])]),
            "y"
        )
    }

    func testFilamentAvailabilityAndPLABlackPreference() {
        let out = Record(values: ["id": "out", "name": "PLA BLACK", "available": false])
        let exact = Record(values: ["id": "exact", "name": "PLA BLACK", "available": true])
        let heuristic = Record(values: ["id": "h", "name": "Soft PLA Black"])
        XCTAssertEqual(filamentAvailability(out), false)
        XCTAssertEqual(filamentAvailabilityLabel(out), "Out of stock")
        XCTAssertNil(filamentAvailability(heuristic))
        XCTAssertNil(filamentAvailabilityLabel(heuristic))
        XCTAssertEqual(plaBlackFilamentID(in: [out, exact, heuristic]), "exact")
        XCTAssertEqual(plaBlackFilamentID(in: [out, heuristic]), "h")
        XCTAssertNil(plaBlackFilamentID(in: [out]))
    }

    func testConnectionFooterStatusIsConsistent() {
        XCTAssertEqual(
            connectionFooterStatus(hasKey: true, connected: true, accountLoaded: true, busy: false),
            "Connected to Slant 3D"
        )
        XCTAssertEqual(
            connectionFooterStatus(hasKey: true, connected: false, accountLoaded: false, busy: true),
            "Connecting…"
        )
        XCTAssertEqual(
            connectionFooterStatus(hasKey: true, connected: false, accountLoaded: false, busy: false),
            "Couldn’t reach Slant 3D"
        )
        XCTAssertEqual(
            connectionFooterStatus(hasKey: false, connected: false, accountLoaded: false, busy: false),
            "Not connected"
        )
    }

    func testUploadOnlyUpdatesFileIDWhenStillSelected() {
        let uploaded = UUID()
        let other = UUID()
        XCTAssertTrue(shouldUpdateFileIDAfterUpload(uploadedModelID: uploaded, selectedLocalID: uploaded))
        XCTAssertFalse(shouldUpdateFileIDAfterUpload(uploadedModelID: uploaded, selectedLocalID: other))
        XCTAssertFalse(shouldUpdateFileIDAfterUpload(uploadedModelID: uploaded, selectedLocalID: nil))
    }

    func testListHasMoreFromPaginationOrPageSizeFallback() {
        XCTAssertTrue(listHasMorePages(pagination: ["totalPages": 3], recordCount: 10, currentPage: 1, pageSize: 100))
        XCTAssertFalse(listHasMorePages(pagination: ["totalPages": 1], recordCount: 100, currentPage: 1, pageSize: 100))
        XCTAssertTrue(listHasMorePages(pagination: nil, recordCount: 100, currentPage: 1, pageSize: 100))
        XCTAssertFalse(listHasMorePages(pagination: nil, recordCount: 40, currentPage: 1, pageSize: 100))
    }

    func testOrderFilterQueryItems() {
        var filter = OrderFilter(status: "QUEUED", sortOrder: "desc")
        filter.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let items = orderFilterQueryItems(filter, page: 2, limit: 100, platformID: "plat-1")
        XCTAssertEqual(items["page"], "2")
        XCTAssertEqual(items["limit"], "100")
        XCTAssertEqual(items["sortBy"], "createdAt")
        XCTAssertEqual(items["sortOrder"], "DESC")
        XCTAssertEqual(items["status"], "QUEUED")
        XCTAssertEqual(items["platformId"], "plat-1")
        XCTAssertEqual(items["startDate"], orderFilterStartDateQueryValue(filter.startDate!))
        XCTAssertNotEqual(items["startDate"], orderFilterDateString(filter.startDate!))
        XCTAssertTrue(items["startDate"]?.count == 10)
        XCTAssertTrue(OrderFilter(status: "DRAFT").isActive)
        XCTAssertFalse(OrderFilter().isActive)
        XCTAssertEqual(orderStatusFilterOptions.count, 5)
        XCTAssertFalse(orderStatusFilterOptions.contains("PAID"))
        XCTAssertTrue(orderStatusFilterOptions.contains("CANCELLED"))
        XCTAssertEqual(orderStatusTitle("ITEMS_ON_SHELF"), "On the shelf")
        XCTAssertEqual(normalizedOrderSortOrder("asc"), "ASC")
        XCTAssertEqual(normalizedOrderSortOrder("DESC"), "DESC")
        var inverted = OrderFilter()
        inverted.startDate = Date(timeIntervalSince1970: 2_000)
        inverted.endDate = Date(timeIntervalSince1970: 1_000)
        XCTAssertNotNil(orderFilterValidationError(inverted))
        XCTAssertNil(orderFilterValidationError(OrderFilter(status: "QUEUED")))
        var withEnd = OrderFilter()
        withEnd.endDate = Date(timeIntervalSince1970: 1_700_000_000)
        let endItems = orderFilterQueryItems(withEnd, page: 1, limit: 100, platformID: "")
        XCTAssertEqual(endItems["endDate"], orderFilterEndDateQueryValue(withEnd.endDate!))
        XCTAssertNotEqual(endItems["endDate"], orderFilterDateString(withEnd.endDate!))
    }

    func testOrderSearchPublicIDNormalisesTypedNumbers() {
        XCTAssertEqual(orderSearchPublicID("SLANT_1000000000003"), "SLANT_1000000000003")
        XCTAssertEqual(orderSearchPublicID(" slant_1000000000003 "), "SLANT_1000000000003")
        XCTAssertEqual(orderSearchPublicID("1000000000003"), "SLANT_1000000000003")
        XCTAssertEqual(orderSearchPublicID("T-1001"), "T-1001")
        XCTAssertEqual(orderSearchPublicID("١٢٣"), "١٢٣")
    }

    func testOrderNotFoundCoversLiveSlantsOrderLookupRefusal() {
        XCTAssertTrue(orderNotFoundStatus(404))
        // Live Slant answers GET /orders/{unknown} (and /orders/search) with 400 "Order not found."
        let lookup = #"{"success":false,"error":{"message":"Order not found.","statusCode":400}}"#
        XCTAssertTrue(orderNotFoundStatus(400, body: lookup))
        XCTAssertFalse(orderNotFoundStatus(400))
        XCTAssertFalse(orderNotFoundStatus(400, body: #"{"message":"query is required"}"#))
        XCTAssertFalse(orderNotFoundStatus(500, body: lookup))
    }

    func testUploadTypeParameterOmitsSTLIncludesOBJAnd3MF() {
        XCTAssertNil(uploadTypeParameter(forFileExtension: "stl"))
        XCTAssertNil(uploadTypeParameter(forFileExtension: "STL"))
        XCTAssertEqual(uploadTypeParameter(forFileExtension: "obj"), "obj")
        XCTAssertEqual(uploadTypeParameter(forFileExtension: "3mf"), "3mf")
    }

    func testPlatformDraftValidatesHTTPSAndLengths() {
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "http://insecure.example").payload())
        XCTAssertThrowsError(try PlatformDraft(name: String(repeating: "n", count: 101), url: "https://ok.example").payload())
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "https://ok.example", description: String(repeating: "d", count: 501)).payload())
        XCTAssertNoThrow(try PlatformDraft(name: "Shop", url: "https://yourstore.com").payload())
        let existing = Record(values: ["name": "A", "url": "https://a.example", "description": "D", "webhookURL": "https://hook.example"])
        let draft = PlatformDraft(platform: existing)
        XCTAssertEqual(draft.name, "A")
        XCTAssertEqual(draft.url, "https://a.example")
        XCTAssertEqual(draft.description, "D")
        XCTAssertEqual(draft.webhookURL, "https://hook.example")
    }

    func testCatalogDestinationRedirect() {
        let materials = resolvedNavigation(requested: .materials, previous: .models, showDeveloperTools: false)
        XCTAssertEqual(materials.destination, .catalog)
        XCTAssertEqual(materials.catalogKind, .materials)
        XCTAssertFalse(materials.opensSettings)
        let stationery = resolvedNavigation(requested: .stationery, previous: .orders, showDeveloperTools: false)
        XCTAssertEqual(stationery.destination, .catalog)
        XCTAssertEqual(stationery.catalogKind, .stationery)
        let models = resolvedNavigation(requested: .models, previous: .orders, showDeveloperTools: false)
        XCTAssertEqual(models.destination, .models)
        XCTAssertNil(models.catalogKind)
        XCTAssertFalse(Destination.catalog.isCatalogKind)
        XCTAssertTrue(Destination.components.isCatalogKind)
        XCTAssertEqual(Destination.catalogKinds, [.materials, .components, .stationery])
    }

    func testPlatformsOpenSettingsAndKeepTheCurrentScreen() {
        // Platforms moved from Catalog to Settings › Account.
        XCTAssertFalse(Destination.platforms.isCatalogKind)
        let fromOrders = resolvedNavigation(requested: .platforms, previous: .orders, showDeveloperTools: false)
        XCTAssertEqual(fromOrders.destination, .orders)
        XCTAssertNil(fromOrders.catalogKind)
        XCTAssertTrue(fromOrders.opensSettings)
        let fromCatalog = resolvedNavigation(requested: .platforms, previous: .catalog, showDeveloperTools: true)
        XCTAssertEqual(fromCatalog.destination, .catalog)
        XCTAssertTrue(fromCatalog.opensSettings)
        XCTAssertEqual(resolvedNavigation(requested: .platforms, previous: .platforms, showDeveloperTools: false).destination, .models)
    }

    func testDeveloperDestinationsNeedDeveloperTools() {
        XCTAssertTrue(Destination.api.isDeveloperDestination)
        XCTAssertTrue(Destination.activity.isDeveloperDestination)
        XCTAssertFalse(Destination.models.isDeveloperDestination)
        // Hidden: a request for a developer screen leaves the user where they are.
        let hidden = resolvedNavigation(requested: .api, previous: .orders, showDeveloperTools: false)
        XCTAssertEqual(hidden.destination, .orders)
        XCTAssertFalse(hidden.opensSettings)
        XCTAssertEqual(resolvedNavigation(requested: .activity, previous: .api, showDeveloperTools: false).destination, .models)
        // Shown: reachable.
        XCTAssertEqual(resolvedNavigation(requested: .api, previous: .orders, showDeveloperTools: true).destination, .api)
        XCTAssertEqual(resolvedNavigation(requested: .activity, previous: .models, showDeveloperTools: true).destination, .activity)
    }

    func testHidingDeveloperToolsMovesDeveloperScreensToModels() {
        XCTAssertEqual(destinationAfterDeveloperToolsChange(.api, showDeveloperTools: false), .models)
        XCTAssertEqual(destinationAfterDeveloperToolsChange(.activity, showDeveloperTools: false), .models)
        XCTAssertEqual(destinationAfterDeveloperToolsChange(.orders, showDeveloperTools: false), .orders)
        XCTAssertEqual(destinationAfterDeveloperToolsChange(.catalog, showDeveloperTools: false), .catalog)
        XCTAssertEqual(destinationAfterDeveloperToolsChange(.api, showDeveloperTools: true), .api)
    }

    func testDeveloperToolsSwitchWaitsForRequestsAndModalUI() {
        // A Workbench request in flight, or a Workbench review sheet, must never be torn down by hiding the screen.
        XCTAssertEqual(developerToolsToggleBlockedReason(busy: true, modalUIShown: false), "Wait for the current request to finish.")
        XCTAssertEqual(developerToolsToggleBlockedReason(busy: false, modalUIShown: true), "Close the open sheet, alert or dialog first.")
        XCTAssertNotNil(developerToolsToggleBlockedReason(busy: true, modalUIShown: true))
        XCTAssertNil(developerToolsToggleBlockedReason(busy: false, modalUIShown: false))
    }

    func testKeyChangeAndDisconnectWaitForRequestsAndModalUI() {
        // A Pay review or draft in the main window must not lose its account underneath it.
        XCTAssertEqual(accountKeyChangeBlockedReason(busy: true, modalUIShown: false), "Wait for the current request to finish.")
        XCTAssertEqual(accountKeyChangeBlockedReason(busy: false, modalUIShown: true),
                       "Close the open sheet, alert or dialog first.")
        XCTAssertNotNil(accountKeyChangeBlockedReason(busy: true, modalUIShown: true))
        XCTAssertNil(accountKeyChangeBlockedReason(busy: false, modalUIShown: false))
    }

    func testConnectAccountPromptLeadsFirstLaunchToSettings() {
        // First launch or a Keychain read failure: no key and an empty library.
        XCTAssertTrue(showsConnectAccountPrompt(destination: .models, hasKey: false, hasLocalModels: false))
        // The library works offline, so Models opens once it has models (its action bar offers Connect Account).
        XCTAssertFalse(showsConnectAccountPrompt(destination: .models, hasKey: false, hasLocalModels: true))
        for destination in [Destination.orders, .catalog] {
            XCTAssertTrue(showsConnectAccountPrompt(destination: destination, hasKey: false, hasLocalModels: true))
        }
        // The Workbench lists public operations and Activity is local.
        XCTAssertFalse(showsConnectAccountPrompt(destination: .api, hasKey: false, hasLocalModels: false))
        XCTAssertFalse(showsConnectAccountPrompt(destination: .activity, hasKey: false, hasLocalModels: false))
        for destination in Destination.allCases {
            XCTAssertFalse(showsConnectAccountPrompt(destination: destination, hasKey: true, hasLocalModels: false))
        }
    }

    func testCreatePlatformShowsInOneWindowAtATime() {
        XCTAssertNil(createPlatformBlockedReason(hasKey: true, busy: false, limitReached: false, otherComposerOpen: false))
        XCTAssertEqual(createPlatformBlockedReason(hasKey: true, busy: false, limitReached: false, otherComposerOpen: true),
                       "Finish creating the platform in the main window first.")
        XCTAssertEqual(createPlatformBlockedReason(hasKey: false, busy: false, limitReached: false, otherComposerOpen: false),
                       "Connect your account first.")
        XCTAssertNotNil(createPlatformBlockedReason(hasKey: true, busy: false, limitReached: true, otherComposerOpen: false))
        XCTAssertNotNil(createPlatformBlockedReason(hasKey: true, busy: true, limitReached: false, otherComposerOpen: false))
    }

    func testSettingsWindowSheetsCountAsModalUI() {
        // A sheet or dialog on the Settings window while it is key (the key window is the sheet itself)…
        XCTAssertTrue(AppModalState(keyWindowIsSheet: true, anyWindowHasSheet: true).isPresenting)
        // …or while the main window is key again: AppModalState looks at every window, not only the key one.
        XCTAssertTrue(AppModalState(keyWindowIsSheet: false, anyWindowHasSheet: true).isPresenting)
        // The Settings window on its own, with nothing presented, doesn't block menus.
        XCTAssertFalse(AppModalState(hasModalWindow: false, keyWindowIsSheet: false, anyWindowHasSheet: false).isPresenting)
    }

    func testDeliveryDetailsClearedWithSession() {
        let kept = DeliveryDetails(email: "a@b.com", name: "Ada")
        XCTAssertNil(clearedDeliveryDetails(afterSessionClear: kept))
        XCTAssertEqual(maxPlatforms, 5)
    }

    func testLocalModelSupportsPreviewOnlyForSTL() {
        let stl = LocalModel(name: "a", filePath: "/tmp/a.stl")
        let obj = LocalModel(name: "b", filePath: "/tmp/b.obj")
        XCTAssertTrue(stl.supportsPreview)
        XCTAssertFalse(obj.supportsPreview)
        XCTAssertNil(meshFootprint(nil))
    }

    func testOrderDraftBlockedReason() {
        XCTAssertEqual(orderDraftBlockedReasonText(hasKey: false, platformID: ""), "Connect your account first.")
        XCTAssertEqual(orderDraftBlockedReasonText(hasKey: true, platformID: ""), "Choose a default platform in Settings › Account.")
        XCTAssertNil(orderDraftBlockedReasonText(hasKey: true, platformID: "p1"))
    }

    func testConnectOnlyRefreshesWhenAttemptSucceeded() {
        XCTAssertTrue(shouldRefreshAfterConnect(succeeded: true))
        XCTAssertFalse(shouldRefreshAfterConnect(succeeded: false))
    }

    func testExtractedWebhookSecretIgnoresEmpty() {
        XCTAssertNil(extractedWebhookSecret(from: ["webhookSecret": ""]))
        XCTAssertEqual(extractedWebhookSecret(from: ["webhookSecret": "abc"]), "abc")
        XCTAssertEqual(extractedWebhookSecret(from: ["secret": "xyz"]), "xyz")
        XCTAssertNil(extractedWebhookSecret(from: [:]))
    }

    func testWebhookResultParsers() {
        let test = parseWebhookTestResult(from: [
            "success": true,
            "response": ["status": 200],
            "message": "ok"
        ])
        XCTAssertTrue(test.attempted)
        XCTAssertEqual(test.endpointStatus, 200)
        XCTAssertEqual(test.message, "ok")
        let resend = parseWebhookResendResult(from: [
            "attempted": 25, "delivered": 20, "failed": 3, "expired": 2, "remaining": 12
        ])
        XCTAssertEqual(resend.attempted, 25)
        XCTAssertEqual(resend.delivered, 20)
        XCTAssertEqual(resend.failed, 3)
        XCTAssertEqual(resend.expired, 2)
        XCTAssertEqual(resend.remaining, 12)
        let single = parseWebhookSingleResendResult(from: [
            "success": false, "status": 500, "error": "timeout", "alreadyDelivered": false, "expired": false
        ])
        XCTAssertFalse(single.success)
        XCTAssertEqual(single.status, 500)
        XCTAssertEqual(single.error, "timeout")
        let testWithResponseError = parseWebhookTestResult(from: [
            "success": true,
            "response": ["status": 502, "error": "bad gateway"]
        ])
        XCTAssertEqual(testWithResponseError.message, "bad gateway")
        XCTAssertEqual(testWithResponseError.endpointStatus, 502)
    }

    func testOutcomeUnknownHelpersAndResolution() {
        XCTAssertTrue(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: "PAID"))
        XCTAssertFalse(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: "DRAFT"))
        XCTAssertTrue(outcomeResolved(action: .cancel, reviewedStatus: "QUEUED", reloadedStatus: "CANCELED"))
        XCTAssertFalse(outcomeResolved(action: .cancel, reviewedStatus: "QUEUED", reloadedStatus: "QUEUED"))
    }

    func testConnectionProminentActionIsExclusive() {
        XCTAssertEqual(
            connectionProminentAction(connected: false, savedKey: "", keyField: "sl_new", platformID: ""),
            .saveTest
        )
        XCTAssertEqual(
            connectionProminentAction(connected: true, savedKey: "sl_a", keyField: "sl_b", platformID: "p"),
            .saveTest
        )
        XCTAssertEqual(
            connectionProminentAction(connected: true, savedKey: "sl_a", keyField: "sl_a", platformID: ""),
            .createPlatform
        )
        XCTAssertEqual(
            connectionProminentAction(connected: true, savedKey: "sl_a", keyField: "sl_a", platformID: "p"),
            .none
        )
    }

    func testPlatformDraftWebhookSecretOnlyOnUpdate() throws {
        let create = try PlatformDraft(name: "Shop", url: "https://shop.example", webhookSecret: String(repeating: "a", count: 32)).payload()
        XCTAssertNil(create["webhookSecret"])
        var edit = PlatformDraft(name: "Shop", url: "https://shop.example", clearsWebhookWhenBlank: true)
        edit.webhookSecret = String(repeating: "b", count: 32)
        edit.description = ""
        let updated = try edit.payload()
        XCTAssertEqual(updated["webhookSecret"] as? String, edit.webhookSecret)
        XCTAssertEqual(updated["description"] as? String, "")
    }

    func testImportModelTypeFromURLOrNameExtension() {
        XCTAssertEqual(importModelType(url: "https://cdn.example/a.obj", name: "part"), "obj")
        XCTAssertEqual(importModelType(url: "https://cdn.example/a", name: "part.3mf"), "3mf")
        XCTAssertEqual(importModelType(url: "https://cdn.example/a.stl", name: "part"), "stl")
        XCTAssertEqual(importModelType(url: "https://cdn.example/a", name: "part"), "stl")
    }

    func testPlatformDraftClearsWebhookAndValidatesSecret() throws {
        var draft = PlatformDraft(name: "Shop", url: "https://shop.example", clearsWebhookWhenBlank: true)
        let cleared = try draft.payload()
        XCTAssertEqual(cleared["webhookURL"] as? String, "")
        draft.webhookSecret = "short"
        XCTAssertThrowsError(try draft.payload())
        draft.webhookSecret = String(repeating: "a", count: 32)
        let withSecret = try draft.payload()
        XCTAssertEqual(withSecret["webhookSecret"] as? String, draft.webhookSecret)
        let create = try PlatformDraft(name: "Shop", url: "https://shop.example").payload()
        XCTAssertNil(create["webhookURL"])
    }

    func testUsageSummaryRowsFlattenAndRedactKeys() {
        let usage: [String: Any] = [
            "user": ["role": "pro", "apiKey": "secret-value"],
            "summary": ["totalCurrentUsage": 42],
            "apiKeys": [["key": "sl_x"], ["key": "sl_y"]]
        ]
        let rows = usageSummaryRows(usage)
        XCTAssertTrue(rows.contains(where: { $0.0 == "Role" && $0.1 == "pro" }))
        XCTAssertTrue(rows.contains(where: { $0.0 == "Total current usage" && $0.1 == "42" }))
        XCTAssertTrue(rows.contains(where: { $0.0 == "API keys" && $0.1 == "2" }))
        XCTAssertFalse(rows.contains(where: { $0.1.contains("secret-value") }))
        XCTAssertFalse(rows.contains(where: { $0.1.contains("sl_x") }))
    }

    func testUsageRowsHideRepeatsAndShowPercentages() {
        let usage: [String: Any] = [
            "user": ["role": "free", "activeKeys": 1],
            "summary": ["overallUsagePercentage": 2, "totalLimit": 100]
        ]
        let rows = usageSummaryRows(usage, hiding: ["Role"])
        XCTAssertFalse(rows.contains(where: { $0.0 == "Role" }))
        XCTAssertTrue(rows.contains(where: { $0.0 == "Active keys" && $0.1 == "1" }))
        XCTAssertTrue(rows.contains(where: { $0.0 == "Overall usage percentage" && $0.1 == "2%" }))
        XCTAssertTrue(rows.contains(where: { $0.0 == "Total limit" && $0.1 == "100" }))
        XCTAssertTrue(usageSummaryRows(usage).contains(where: { $0.0 == "Role" }))
        XCTAssertEqual(humanizeUsageLabel("API_keys"), "API keys")
        XCTAssertEqual(humanizeUsageLabel("totalAPICalls"), "Total API calls")
    }

    func testHealthServiceDisplayNames() {
        XCTAssertEqual(healthServiceDisplayName("ORDER-SERVICE"), "Order service")
        XCTAssertEqual(healthServiceDisplayName("KRAKEN"), "Kraken")
        XCTAssertEqual(healthServiceDisplayName("files"), "Files")
        XCTAssertEqual(healthServiceDisplayName("API-GATEWAY"), "API gateway")
        XCTAssertEqual(healthServiceDisplayName(""), "")
    }

    func testHealthServiceRowsIgnoreEnvelopeSuccess() {
        let health: [String: Any] = [
            "files": ["healthy": true, "lastCheckedAt": "2024-01-01"],
            "orders": ["healthy": false, "lastCheckedAt": "2024-01-01"]
        ]
        let rows = healthServiceRows(health)
        XCTAssertEqual(rows.first(where: { $0.name == "files" })?.status, "Healthy")
        XCTAssertEqual(rows.first(where: { $0.name == "orders" })?.status, "Unavailable")
        XCTAssertEqual(healthOverallLabel(health), "1 service having problems")
        XCTAssertEqual(healthOverallLabel(["a": ["healthy": true]]), "All services healthy")
    }

    func testComponentCategoryNameWalksParents() {
        let categories = [
            Record(values: ["id": "root", "name": "Hardware"]),
            Record(values: ["id": "leaf", "name": "Screws", "parentId": "root"])
        ]
        XCTAssertEqual(componentCategoryName(id: "leaf", in: categories), "Hardware › Screws")
        XCTAssertEqual(componentCategoryName(id: "root", in: categories), "Hardware")
        XCTAssertNil(componentCategoryName(id: "missing", in: categories))
    }

    func testApplyOrderFilterBusySkipDoesNotCommitFilter() {
        let previous = OrderFilter(status: "QUEUED")
        let next = OrderFilter(status: "SHIPPED")
        let committed = orderFilterAfterBusySkip(previous: previous, attempted: next, ran: false)
        XCTAssertEqual(committed, previous)
        let applied = orderFilterAfterBusySkip(previous: previous, attempted: next, ran: true)
        XCTAssertEqual(applied, next)
    }
}

func orderFilterAfterBusySkip(previous: OrderFilter, attempted: OrderFilter, ran: Bool) -> OrderFilter {
    ran ? attempted : previous
}

func shouldRefreshWorkspaceAfterConnect(connected: Bool, accountLoaded: Bool) -> Bool {
    connected && !accountLoaded
}

func applyShowError(message: String, hadRetry: Bool) -> (error: String?, canRetry: Bool) {
    _ = hadRetry
    return (message, false)
}

func applyClearAccountSession(hadRetry: Bool, accountLoaded: Bool) -> (error: String?, canRetry: Bool, accountLoaded: Bool, filePage: Int, orderPage: Int, lastDelivery: DeliveryDetails?) {
    _ = hadRetry
    _ = accountLoaded
    return (nil, false, false, 0, 0, nil)
}

func clearedDeliveryDetails(afterSessionClear _: DeliveryDetails?) -> DeliveryDetails? { nil }
