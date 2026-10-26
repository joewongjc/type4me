import XCTest
@testable import Type4Me

final class UpdateInfoTests: XCTestCase {

    func testDownloadURLUsesLocalAssetForLocalInstallations() throws {
        let update = try decodeUpdate("""
        {
          "version": "1.9.5",
          "date": "2026-06-01",
          "notes": "Fix updater",
          "cloud_dmg_url": "https://example.com/Type4Me-cloud.dmg",
          "cloud_dmg_size": 1234,
          "cloud_dmg_sha256": "cloudhash",
          "local_dmg_url": "https://example.com/Type4Me-local.dmg",
          "local_dmg_size": 5678,
          "local_dmg_sha256": "localhash"
        }
        """)

        XCTAssertEqual(
            update.downloadURL(isLocalInstallation: false).absoluteString,
            "https://example.com/Type4Me-cloud.dmg"
        )
        XCTAssertEqual(
            update.downloadURL(isLocalInstallation: true).absoluteString,
            "https://example.com/Type4Me-local.dmg"
        )
        XCTAssertEqual(update.dmgSHA256(isLocalInstallation: false), "cloudhash")
        XCTAssertEqual(update.dmgSHA256(isLocalInstallation: true), "localhash")
        XCTAssertEqual(update.dmgSize(isLocalInstallation: false), 1234)
        XCTAssertEqual(update.dmgSize(isLocalInstallation: true), 5678)
        XCTAssertNotNil(update.formattedSize(isLocalInstallation: false))
        XCTAssertNotNil(update.formattedSize(isLocalInstallation: true))
    }

    func testDownloadURLFallsBackToVariantSpecificReleaseAssetNames() throws {
        let update = try decodeUpdate("""
        {
          "version": "1.9.5",
          "date": "2026-06-01",
          "notes": "Fix updater"
        }
        """)

        XCTAssertEqual(
            update.downloadURL(isLocalInstallation: false).absoluteString,
            "https://github.com/joewongjc/type4me/releases/download/v1.9.5/Type4Me-v1.9.5-cloud.dmg"
        )
        XCTAssertEqual(
            update.downloadURL(isLocalInstallation: true).absoluteString,
            "https://github.com/joewongjc/type4me/releases/download/v1.9.5/Type4Me-v1.9.5-local-apple-silicon.dmg"
        )
    }

    func testDownloadFailureMessageExplainsTooManyOpenFiles() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 24)
        let urlError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotOpenFile,
            userInfo: [NSUnderlyingErrorKey: posix]
        )

        let message = AppUpdater.downloadFailureMessage(
            for: urlError,
            fallback: "Too many open files"
        )

        XCTAssertTrue(
            message.contains("打开文件过多") || message.contains("Too many files"),
            message
        )
    }

    private func decodeUpdate(_ json: String) throws -> UpdateInfo {
        try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
    }
}
