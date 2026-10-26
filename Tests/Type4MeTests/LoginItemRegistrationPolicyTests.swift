import Foundation
import XCTest
@testable import Type4Me

final class LoginItemRegistrationPolicyTests: XCTestCase {
    func testAllowsExecutableInsideApplicationBundle() {
        XCTAssertTrue(LoginItemRegistrationPolicy.supportsRegistration(
            bundleURL: URL(fileURLWithPath: "/Applications/Type4Me Dev.app"),
            bundleIdentifier: "com.type4me.dev",
            executableURL: URL(fileURLWithPath: "/Applications/Type4Me Dev.app/Contents/MacOS/Type4Me")
        ))
    }

    func testRejectsSwiftPackageDebugExecutable() {
        XCTAssertFalse(LoginItemRegistrationPolicy.supportsRegistration(
            bundleURL: URL(fileURLWithPath: "/Users/test/type4me/.build/arm64-apple-macosx/debug"),
            bundleIdentifier: "Type4Me-adhoc",
            executableURL: URL(fileURLWithPath: "/Users/test/type4me/.build/arm64-apple-macosx/debug/Type4Me")
        ))
    }

    func testRejectsApplicationBundleWithoutBundleIdentifier() {
        XCTAssertFalse(LoginItemRegistrationPolicy.supportsRegistration(
            bundleURL: URL(fileURLWithPath: "/Applications/Type4Me.app"),
            bundleIdentifier: nil,
            executableURL: URL(fileURLWithPath: "/Applications/Type4Me.app/Contents/MacOS/Type4Me")
        ))
    }

    func testRejectsExecutableOutsideClaimedApplicationBundle() {
        XCTAssertFalse(LoginItemRegistrationPolicy.supportsRegistration(
            bundleURL: URL(fileURLWithPath: "/Applications/Type4Me.app"),
            bundleIdentifier: "com.type4me.app",
            executableURL: URL(fileURLWithPath: "/tmp/Type4Me")
        ))
    }
}
