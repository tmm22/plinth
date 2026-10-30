import XCTest
@testable import SlantStudio

// Round 13: window reopening, Help, the review's close check, the Claude key hold, next-send estimates and labels.

extension ShellUXTests {
    func testOnlyTheMainWindowCountsAsTheMainWindow() {
        // SwiftUI's main window and an unnamed window can be the main window.
        XCTAssertTrue(isMainStudioWindowCandidate(identifier: "main-AppWindow-1", isPanel: false, canBecomeMain: true))
        XCTAssertTrue(isMainStudioWindowCandidate(identifier: nil, isPanel: false, canBecomeMain: true))
        // Settings, Help, panels and windows that can't become main never are, so revealing never picks them and a
        // closed main window is noticed even while they are open.
        XCTAssertFalse(isMainStudioWindowCandidate(identifier: "com_apple_SwiftUI_Settings_window", isPanel: false, canBecomeMain: true))
        XCTAssertFalse(isMainStudioWindowCandidate(identifier: helpWindowIdentifier, isPanel: false, canBecomeMain: true))
        XCTAssertFalse(isMainStudioWindowCandidate(identifier: nil, isPanel: true, canBecomeMain: true))
        XCTAssertFalse(isMainStudioWindowCandidate(identifier: "main-AppWindow-1", isPanel: false, canBecomeMain: false))
    }

    func testHelpIsLocalAndPointsToSlantsPublicDocs() {
        XCTAssertEqual(slantAPIDocumentationURL.scheme, "https")
        XCTAssertEqual(slantAPIDocumentationURL.host, "slant3dapi.com")
        XCTAssertFalse(studioHelpSections.isEmpty)
        XCTAssertEqual(Set(studioHelpSections.map(\.id)).count, studioHelpSections.count, "Section titles are unique IDs")
        for section in studioHelpSections {
            XCTAssertFalse(section.body.contains("..."), "Use the ellipsis character: \(section.title)")
            XCTAssertFalse(section.body.contains("github"), "The repository is private: \(section.title)")
            // Sentence-case headings.
            let rest = section.title.dropFirst()
            XCTAssertFalse(rest.split(separator: " ").contains { $0.first?.isUppercase == true && $0 != "Plinth" },
                           "Sentence case: \(section.title)")
        }
        XCTAssertTrue(studioHelpSections.contains { $0.body.contains("Window › Plinth") })
    }

    func testActivityStatusIconsHaveMeaningfulLabels() {
        XCTAssertEqual(activityStatusAccessibilityLabel(success: true), "Succeeded")
        XCTAssertEqual(activityStatusAccessibilityLabel(success: false), "Didn’t succeed")
    }

    func testPhotoSharingUsesTheServiceNamesShownElsewhere() {
        XCTAssertEqual(ImageSharingService.anthropic.displayName, "Claude (Anthropic)")
        XCTAssertEqual(ImageSharingService.tripo.displayName, ImageTo3DService.tripo.title)
        XCTAssertEqual(ImageSharingService.meshy.displayName, ImageTo3DService.meshy.title)
    }
}

extension PrintReviewTests {
    func testClosingAsksOnlyWhenBilledWorkWouldBeLost() {
        // Nothing sent yet, or the plan's copy already saved: close at once.
        XCTAssertNil(printReviewCloseConfirmation(hasPlan: false, asking: false, savedCopy: false))
        XCTAssertNil(printReviewCloseConfirmation(hasPlan: true, asking: false, savedCopy: true))
        // A plan on screen with nothing saved from it.
        let plan = printReviewCloseConfirmation(hasPlan: true, asking: false, savedCopy: false)
        XCTAssertEqual(plan?.title, "Close this review?")
        XCTAssertTrue(plan?.message.contains("billed again") == true)
        // Claude still replying: closing stops it part-way.
        let asking = printReviewCloseConfirmation(hasPlan: false, asking: true, savedCopy: false)
        XCTAssertEqual(asking?.title, "Stop Claude and close this review?")
        XCTAssertTrue(asking?.message.contains("may bill") == true)
        XCTAssertNotNil(printReviewCloseConfirmation(hasPlan: true, asking: true, savedCopy: true), "Asking again after a saved copy")
    }

    func testClaudeSheetsHoldTheKeyOnlyOnceOneIsSetUp() {
        // Without a key there is no conversation to protect, so Settings can add one while the sheet is open.
        XCTAssertFalse(claudeSheetShouldBeginKeySession(configured: false, holding: false))
        XCTAssertTrue(claudeSheetShouldBeginKeySession(configured: true, holding: false))
        // Begun once per sheet.
        XCTAssertFalse(claudeSheetShouldBeginKeySession(configured: true, holding: true))
        XCTAssertFalse(claudeSheetShouldBeginKeySession(configured: false, holding: true))
    }
}

extension AccessoryDesignerTests {
    func testNextSendForecastMatchesTheBriefForecastForTheSameTokens() {
        // An empty history plus the allowance for the seller's note equals a brief of 875 characters and no photos.
        let next = accessoryNextSendForecast(messages: [], repliesLeft: 10)
        let brief = accessoryCostForecast(photoSizes: [], textCharacters: 875)
        XCTAssertEqual(next, brief)
    }

    func testNextSendForecastGrowsWithTheConversation() throws {
        let photo = AnthropicImage(mediaType: .jpeg, base64Data: "")
        let short: [AnthropicMessageParam] = [.user([.image(photo), .text("Make a stand.")])]
        let longer = short + [
            .user([.toolResult(toolUseID: "a", content: [.text(String(repeating: "x", count: 4_000)), .image(photo), .image(photo)])])
        ]
        XCTAssertGreaterThan(accessoryConversationTokens(short), accessoryConversationTokens([]))
        XCTAssertGreaterThan(accessoryConversationTokens(longer), accessoryConversationTokens(short))
        let small = try XCTUnwrap(accessoryNextSendForecast(messages: short, repliesLeft: 10))
        let large = try XCTUnwrap(accessoryNextSendForecast(messages: longer, repliesLeft: 10))
        XCTAssertLessThan(small.typical.usd, large.typical.usd)
        XCTAssertLessThan(small.typical.usd, small.maximum.usd)
    }

    func testNextSendForecastFollowsTheRepliesLeft() throws {
        let messages: [AnthropicMessageParam] = [.user(text: "Make a stand.")]
        // No replies left: the loop stops before sending, so there is nothing to estimate.
        XCTAssertNil(accessoryNextSendForecast(messages: messages, repliesLeft: 0))
        let newRound = try XCTUnwrap(accessoryNextSendForecast(messages: messages, repliesLeft: 10))
        XCTAssertEqual(newRound.typicalReplies, 5)
        XCTAssertEqual(newRound.maximumReplies, 10)
        let text = accessoryNextSendForecastText(newRound, newRound: true)
        XCTAssertTrue(text.hasPrefix("Estimated cost of sending: about $"), text)
        XCTAssertTrue(text.contains("if Claude needs 5 replies"), text)
        XCTAssertTrue(text.contains("if it uses all 10"), text)
        // Answering mid-round: only the replies left in the round.
        let answering = try XCTUnwrap(accessoryNextSendForecast(messages: messages, repliesLeft: 3))
        XCTAssertEqual(answering.typicalReplies, 3)
        XCTAssertEqual(answering.maximumReplies, 3)
        XCTAssertEqual(answering.typical, answering.maximum)
        let answerText = accessoryNextSendForecastText(answering, newRound: false)
        XCTAssertTrue(answerText.contains("at most about $"), answerText)
        XCTAssertTrue(answerText.contains("the 3 left in this round"), answerText)
        XCTAssertFalse(answerText.contains("needs"), answerText)
    }

    func testMissingKeyTextNamesWhereToAddIt() {
        XCTAssertTrue(accessoryMissingClaudeKeyText.contains("Settings › Design Tools › Claude (Anthropic)"))
    }
}
