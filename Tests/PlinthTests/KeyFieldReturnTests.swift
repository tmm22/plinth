import XCTest

/// "No menu item or keyboard shortcut may … send anything to Claude, Meshy, Tripo or 3DAPI": pressing Return in the
/// Slant, design-tool or 3DAPI key field must never save or test (and so send) the key. Only Save & Test does, on a
/// click (round 23 added the Slant key, whose test of a mistyped key used to empty every loaded list). The check covers
/// each whole file, because SwiftUI's `onSubmit` on a container (a `Section` or `Form`) also fires for the fields
/// inside it. SwiftUI gives no way to read a view's modifiers in a unit test, so this reads the source, as
/// `BuildScriptSigningTests` reads build-app.sh.
final class KeyFieldReturnTests: XCTestCase {
    func testKeyFieldsHaveNoReturnAction() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Plinth")
        for file in ["SettingsView.swift", "AnthropicSettingsView.swift", "ImageTo3DSettingsView.swift", "DapiSettingsView.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("SecureField("), "\(file) still holds its key field")
            XCTAssertFalse(text.contains(".onSubmit"), "\(file): Return in a field here would send the key")
            XCTAssertTrue(text.contains("No onSubmit: Return never sends the key anywhere."), file)
        }
    }
}
