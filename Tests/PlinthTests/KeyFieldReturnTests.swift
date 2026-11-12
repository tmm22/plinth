import XCTest

/// "No menu item or keyboard shortcut may … send anything to Claude, Meshy, Tripo or 3DAPI": pressing Return in a
/// design-tool or 3DAPI key field must never test (and so send) the key. Only Save & Test does, on a click. SwiftUI
/// gives no way to read a view's modifiers in a unit test, so this reads the source, as `BuildScriptSigningTests` reads
/// build-app.sh.
final class KeyFieldReturnTests: XCTestCase {
    func testKeyFieldsHaveNoReturnAction() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Plinth")
        for file in ["AnthropicSettingsView.swift", "ImageTo3DSettingsView.swift", "DapiSettingsView.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("SecureField("), "\(file) still holds its key field")
            XCTAssertFalse(text.contains(".onSubmit"), "\(file): Return in the key field would send the key")
            XCTAssertTrue(text.contains("No onSubmit: Return never sends the key anywhere."), file)
        }
    }
}
