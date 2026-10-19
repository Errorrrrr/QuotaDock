import XCTest
import Security
@testable import QuotaDockCore

final class KeychainAccessTests: XCTestCase {
    private enum Expected: Error { case failure }

    func testBackgroundPolicyIsDisabledAndRestoredAfterSuccessAndFailure() throws {
        var original = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess else {
            throw XCTSkip("Keychain interaction policy unavailable")
        }
        try KeychainAccess.perform(allowInteraction: false) {
            var allowed = DarwinBoolean(true)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue)
            // Nested calls must not restore interaction before the outer operation ends.
            try KeychainAccess.perform(allowInteraction: false) {}
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue)
        }
        XCTAssertThrowsError(try KeychainAccess.perform(allowInteraction: false) { throw Expected.failure })
        var restored = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(restored.boolValue, original.boolValue)
    }
}
