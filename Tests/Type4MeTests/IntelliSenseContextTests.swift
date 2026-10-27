import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class IntelliSenseContextTests: XCTestCase {
    func testClassifiesKnownApplicationFamilies() {
        let representatives: [(String?, String?, ApplicationCategory)] = [
            ("com.tinyspeck.slackmacgap", nil, .messaging),
            ("com.tencent.xinWeChat", nil, .messaging),
            ("com.apple.MobileSMS", nil, .messaging),
            ("com.apple.mail", nil, .email),
            ("com.microsoft.Outlook", nil, .email),
            ("com.mimestream.Mimestream", nil, .email),
            ("com.apple.Notes", nil, .document),
            ("md.obsidian", nil, .document),
            ("com.apple.Safari", nil, .browser),
            ("company.thebrowser.Browser", "Arc", .browser),
            ("company.thebrowser.dia", "Dia", .browser),
            ("com.microsoft.VSCode", nil, .development),
            (nil, "Codex", .development),
            ("com.mitchellh.ghostty", nil, .terminal),
            ("com.github.wez.wezterm", nil, .terminal),
        ]
        for (bundle, name, expected) in representatives {
            XCTAssertEqual(AppContextClassifier.classify(bundleIdentifier: bundle, appName: name), expected)
        }
        XCTAssertEqual(AppContextClassifier.classify(bundleIdentifier: "com.example.unknown", appName: nil), .other)
    }

    func testClassifiesChromiumSearchTextAreaUsingAccessibilitySemantics() {
        XCTAssertEqual(
            IntelliSenseContextCapturer.classifyControl(
                role: "AXTextArea",
                subrole: "",
                description: "Search",
                identifier: "APjFqb",
                appCategory: .browser
            ),
            .search
        )
        XCTAssertEqual(
            IntelliSenseContextCapturer.classifyControl(
                role: "AXTextArea",
                subrole: "",
                placeholder: "搜索 Google 或输入网址",
                appCategory: .browser
            ),
            .search
        )
        XCTAssertEqual(
            IntelliSenseContextCapturer.classifyControl(
                role: "AXTextArea",
                subrole: "",
                description: "Comment",
                appCategory: .browser
            ),
            .multiLine
        )
    }

    func testSensitiveScannerDetectsCredentialsAndAllowsOrdinaryText() {
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("api_key = abcdefghijklmnop"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("Authorization: Bearer abcdefghijklmnop"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("password: correct-horse-battery-staple"))
        XCTAssertFalse(IntelliSenseSensitiveTextScanner.containsSensitiveContent("请把这段话说得自然一点"))
    }

    func testSensitiveScannerDetectsCardNumbersThatPassLuhn() {
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("4111111111111111"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("卡号 6222 0212 3456 7890 128，请核对"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("5500-0000-0000-0004"))
        // Same length, fails the check: an order number, not a card.
        XCTAssertFalse(IntelliSenseSensitiveTextScanner.containsSensitiveContent("订单号 4111111111111112"))
        XCTAssertFalse(IntelliSenseSensitiveTextScanner.containsSensitiveContent("电话 13800138000"))
    }

    func testSensitiveScannerDetectsOneTimeCodes() {
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("【某银行】验证码 482913，5 分钟内有效"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("482913是你的登录验证码"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("Your verification code is 7731"))
        XCTAssertTrue(IntelliSenseSensitiveTextScanner.containsSensitiveContent("OTP: 90210"))
        XCTAssertFalse(IntelliSenseSensitiveTextScanner.containsSensitiveContent("会议改到 2026 年 11 月 3 号"))
        XCTAssertFalse(IntelliSenseSensitiveTextScanner.containsSensitiveContent("验证一下这个方案"))
    }

    func testAppOnlySnapshotDoesNotInventContext() {
        let snapshot = IntelliSenseContextSnapshot.appOnly(TargetApplicationContext(
            processIdentifier: nil,
            bundleIdentifier: "com.apple.Terminal",
            displayName: "Terminal"
        ))
        XCTAssertEqual(snapshot.appCategory, .terminal)
        XCTAssertEqual(snapshot.availability, .appOnly)
        XCTAssertTrue(snapshot.contextBeforeCursor.isEmpty)
        XCTAssertTrue(snapshot.contextAfterCursor.isEmpty)
    }

    func testBlacklistStopsBeforeAccessibilityCapture() async {
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        settings.contextAwarenessEnabled = true
        settings.blacklistedApps = [BlacklistedApp(
            bundleIdentifier: "com.example.Secret",
            displayName: "Secret"
        )]
        let snapshot = await IntelliSenseContextCapturer.capture(
            target: TargetApplicationContext(
                processIdentifier: getpid(),
                bundleIdentifier: "COM.EXAMPLE.SECRET",
                displayName: "Secret"
            ),
            settings: settings
        )
        XCTAssertEqual(snapshot.availability, .blacklisted)
        XCTAssertTrue(snapshot.contextBeforeCursor.isEmpty)
        XCTAssertTrue(snapshot.contextAfterCursor.isEmpty)
    }
}
