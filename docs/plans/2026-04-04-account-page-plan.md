# Account 页面 & 匿名登录实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 Account 页面 (侧边栏底部 tab)，支持匿名登录 (用户名+密码)，设备绑定防刷免费额度。

**Architecture:** 客户端新增 CloudAPIClient 统一请求层处理 auth headers 和 401 拦截。AccountTab 替代 CloudSettingsCard 成为唯一的账户管理入口。服务端新增用户名密码注册/登录端点和设备绑定中间件。

**Tech Stack:** Swift 6/SwiftUI (客户端), Go/PostgreSQL (服务端), IOKit (设备 ID), bcrypt (密码哈希), JWT/HMAC-SHA256 (认证)

**Design doc:** `docs/plans/2026-04-04-account-page-design.md`

---

## Part A: 客户端

### Task 1: DeviceIdentifier 工具类

**Files:**
- Create: `Type4Me/Auth/DeviceIdentifier.swift`

**Step 1: 创建 DeviceIdentifier**

```swift
// Type4Me/Auth/DeviceIdentifier.swift

import Foundation
import IOKit

enum DeviceIdentifier {
    /// 获取稳定的设备标识符。
    /// 优先使用 Hardware UUID (IOPlatformUUID)，取不到时回退到 Keychain 存储的随机 UUID。
    static var deviceID: String {
        if let hwUUID = hardwareUUID() {
            return hwUUID
        }
        return keychainFallbackUUID()
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    private static func keychainFallbackUUID() -> String {
        let service = "com.type4me.device-id"
        let account = "device-uuid"

        // Try read from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let uuid = String(data: data, encoding: .utf8) {
            return uuid
        }

        // Generate and store
        let uuid = UUID().uuidString
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: uuid.data(using: .utf8)!
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return uuid
    }
}
```

**Step 2: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Type4Me/Auth/DeviceIdentifier.swift
git commit -m "feat: add DeviceIdentifier for hardware UUID with Keychain fallback"
```

---

### Task 2: CloudAPIClient 统一请求层

**Files:**
- Create: `Type4Me/Auth/CloudAPIClient.swift`

**Step 1: 创建 CloudAPIClient**

```swift
// Type4Me/Auth/CloudAPIClient.swift

import Foundation
import os

/// 服务端错误类型
enum CloudAPIError: Error, LocalizedError {
    case deviceConflict        // 账户已在其他设备登录
    case tokenExpired          // JWT 过期
    case invalidCredentials    // 登录凭证错误
    case usernameTaken         // 用户名已被占用
    case serverError(String)   // 其他服务端错误
    case networkError(Error)   // 网络错误

    var errorDescription: String? {
        switch self {
        case .deviceConflict: return L("账户已在其他设备登录", "Account logged in on another device")
        case .tokenExpired: return L("登录已过期，请重新登录", "Session expired, please log in again")
        case .invalidCredentials: return L("用户名或密码错误", "Invalid username or password")
        case .usernameTaken: return L("用户名已被占用", "Username already exists")
        case .serverError(let msg): return msg
        case .networkError(let err): return err.localizedDescription
        }
    }
}

@MainActor
final class CloudAPIClient {
    static let shared = CloudAPIClient()

    let deviceID: String
    private let logger = Logger(subsystem: "com.type4me.app", category: "CloudAPI")

    private init() {
        deviceID = DeviceIdentifier.deviceID
    }

    /// 发起认证 API 请求，自动注入 Authorization + X-Device-ID headers。
    /// 401 时自动区分错误类型，设备互踢/过期时自动登出。
    func request(
        _ endpoint: String,
        method: String = "GET",
        body: Data? = nil,
        requiresAuth: Bool = true
    ) async throws -> Data {
        let url = URL(string: CloudConfig.apiEndpoint + endpoint)!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")

        if requiresAuth {
            guard let token = await CloudAuthManager.shared.accessToken() else {
                throw CloudAPIError.tokenExpired
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.serverError("Invalid response")
        }

        // Handle error responses
        if http.statusCode == 401 {
            try handleUnauthorized(data)
        }

        if http.statusCode == 409 {
            // Parse error body
            if let errBody = try? JSONDecoder().decode(ErrorResponse.self, from: data),
               errBody.error == "username_taken" {
                throw CloudAPIError.usernameTaken
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError("HTTP \(http.statusCode): \(body)")
        }

        return data
    }

    private func handleUnauthorized(_ data: Data) throws -> Never {
        let errBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)

        switch errBody?.error {
        case "device_conflict":
            Task { @MainActor in
                await CloudAuthManager.shared.signOut()
                NotificationCenter.default.post(name: .cloudDeviceConflict, object: nil)
            }
            throw CloudAPIError.deviceConflict

        case "token_expired":
            Task { @MainActor in
                await CloudAuthManager.shared.signOut()
            }
            throw CloudAPIError.tokenExpired

        case "invalid_credentials":
            throw CloudAPIError.invalidCredentials

        default:
            throw CloudAPIError.tokenExpired
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let message: String?
    }
}

// Notification for device conflict (UI can listen to show alert)
extension Notification.Name {
    static let cloudDeviceConflict = Notification.Name("cloudDeviceConflict")
}
```

**Step 2: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Type4Me/Auth/CloudAPIClient.swift
git commit -m "feat: add CloudAPIClient with unified auth headers and 401 handling"
```

---

### Task 3: CloudQuotaManager 迁移到 CloudAPIClient

**Files:**
- Modify: `Type4Me/Auth/CloudQuotaManager.swift`

**Step 1: 重构 refresh() 使用 CloudAPIClient**

将 `CloudQuotaManager.refresh()` 中手动拼装的两个 URLRequest 改为使用 `CloudAPIClient.shared.request()`。保留 `QuotaResponse` 和 `UsageResponse` 的 Decodable 结构体不变。

关键改动:
- 删除手动获取 token 和构建 URLRequest 的代码
- 改为 `let data = try await CloudAPIClient.shared.request("/api/quota")`
- usage 同理: `let data = try await CloudAPIClient.shared.request("/api/usage")`
- 保留 `lastFetched` 缓存逻辑
- 保留 `deductLocal()` 不变 (它不走网络)

**Step 2: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Type4Me/Auth/CloudQuotaManager.swift
git commit -m "refactor: migrate CloudQuotaManager to use CloudAPIClient"
```

---

### Task 4: CloudAuthManager 扩展 (匿名登录 + signOut 清理)

**Files:**
- Modify: `Type4Me/Auth/CloudAuthManager.swift`

**Step 1: 添加 LoginMethod 枚举和新属性**

在 `CloudAuthManager` 中新增:

```swift
enum LoginMethod: String {
    case email
    case anonymous
}

// 新增 @Published 属性
@Published private(set) var username: String?
@Published private(set) var loginMethod: LoginMethod?
```

在 `init()` 中恢复这两个属性:
```swift
username = UserDefaults.standard.string(forKey: "tf_cloud_username")
if let method = UserDefaults.standard.string(forKey: "tf_cloud_login_method") {
    loginMethod = LoginMethod(rawValue: method)
}
```

**Step 2: 添加匿名注册和密码登录方法**

```swift
func registerAnonymous(username: String, password: String) async throws {
    struct RegisterRequest: Encodable {
        let username: String
        let password: String
        let device_id: String
    }
    let body = try JSONEncoder().encode(RegisterRequest(
        username: username, password: password,
        device_id: CloudAPIClient.shared.deviceID
    ))
    let data = try await CloudAPIClient.shared.request(
        "/auth/register", method: "POST", body: body, requiresAuth: false
    )

    struct RegisterResponse: Decodable {
        let token: String; let user_id: String; let username: String
    }
    let result = try JSONDecoder().decode(RegisterResponse.self, from: data)

    saveSession(token: result.token, userID: result.user_id,
                email: nil, username: result.username, method: .anonymous)
}

func loginWithPassword(username: String, password: String) async throws {
    struct LoginRequest: Encodable {
        let username: String
        let password: String
        let device_id: String
    }
    let body = try JSONEncoder().encode(LoginRequest(
        username: username, password: password,
        device_id: CloudAPIClient.shared.deviceID
    ))
    let data = try await CloudAPIClient.shared.request(
        "/auth/login", method: "POST", body: body, requiresAuth: false
    )

    struct LoginResponse: Decodable {
        let token: String; let user_id: String; let username: String
        let email: String?
    }
    let result = try JSONDecoder().decode(LoginResponse.self, from: data)

    saveSession(token: result.token, userID: result.user_id,
                email: result.email, username: result.username, method: .anonymous)
}
```

**Step 3: 抽取 saveSession 和更新 signOut**

```swift
private func saveSession(token: String, userID: String,
                         email: String?, username: String?,
                         method: LoginMethod) {
    jwt = token
    UserDefaults.standard.set(email, forKey: "tf_cloud_email")
    UserDefaults.standard.set(userID, forKey: "tf_cloud_user_id")
    UserDefaults.standard.set(username, forKey: "tf_cloud_username")
    UserDefaults.standard.set(method.rawValue, forKey: "tf_cloud_login_method")
    isLoggedIn = true
    self.userEmail = email
    self.userID = userID
    self.username = username
    self.loginMethod = method
}

func signOut() async {
    jwt = nil
    for key in ["tf_cloud_email", "tf_cloud_user_id",
                "tf_cloud_username", "tf_cloud_login_method"] {
        UserDefaults.standard.removeObject(forKey: key)
    }
    isLoggedIn = false
    userEmail = nil
    userID = nil
    username = nil
    loginMethod = nil
}
```

同时将现有的 `verify()` 方法中的登录成功逻辑改为调用 `saveSession()`。

**Step 4: 更新 verify() 调用 saveSession 并传 device_id**

现有 `verify()` 的 `VerifyRequest` 结构体新增 `device_id` 字段:
```swift
struct VerifyRequest: Encodable {
    let email: String; let code: String; let device_id: String
}
```

`sendCode()` 的请求体也新增 `device_id`:
```swift
request.httpBody = try JSONEncoder().encode([
    "email": email,
    "device_id": CloudAPIClient.shared.deviceID
])
```

**Step 5: 更新 JWT 注释**

```swift
// JWT stored in UserDefaults — security is enforced by device binding,
// not token expiry. See design doc for details.
```

**Step 6: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add Type4Me/Auth/CloudAuthManager.swift
git commit -m "feat: add anonymous login (username+password) and device_id to auth flow"
```

---

### Task 5: CloudASRClient 添加 device_id

**Files:**
- Modify: `Type4Me/ASR/CloudASRClient.swift:50-53`

**Step 1: 在 WebSocket URL 中加入 device_id**

当前代码 (第 52-53 行):
```swift
let endpoint = CloudConfig.apiEndpoint + "/asr"
let authedEndpoint = endpoint + "?token=" + token
```

改为:
```swift
let endpoint = CloudConfig.apiEndpoint + "/asr"
let deviceID = CloudAPIClient.shared.deviceID
let authedEndpoint = endpoint + "?token=" + token + "&device_id=" + deviceID
```

**Step 2: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Type4Me/ASR/CloudASRClient.swift
git commit -m "feat: pass device_id in ASR WebSocket connection URL"
```

---

### Task 6: SettingsTab 枚举新增 .account + 侧边栏布局

**Files:**
- Modify: `Type4Me/UI/Settings/SettingsView.swift`

**Step 1: SettingsTab 新增 .account case**

在 `SettingsTab` 枚举中加 `.account`:
```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case vocabulary
    case modes
    case history
    case about
    case account  // 新增
```

`tabs(for:)` 中排除 `.account` (不在主导航列表中):
```swift
static func tabs(for edition: AppEdition?) -> [SettingsTab] {
    switch edition {
    case .member:
        return [.general, .modes, .vocabulary, .history, .about]
    case .byoKey, .none:
        return [.general, .models, .vocabulary, .modes, .history, .about]
    }
}
```

`.account` 的 displayName 和 subtitle:
```swift
case .account: return L("账户", "Account")
// subtitle:
case .account: return L("登录与订阅管理", "Login & subscription")
```

**Step 2: 重构侧边栏底部**

将 sidebar 中的 `SidebarEditionCard()` 替换为 Account tab + 版本切换链接。

Account tab 仅在 `edition == .member` 时显示:

```swift
// 在 sidebar 的 Spacer() 之后:
if edition == .member {
    navItem(.account)
        .padding(.horizontal, 10)
}

EditionSwitchLink()
    .padding(.horizontal, 10)
    .padding(.bottom, 12)
```

其中 `EditionSwitchLink` 是从 `SidebarEditionCard` 中提取的版本切换逻辑 (见 Task 7)。

**Step 3: 在 content ZStack 中添加 AccountTab 页面**

```swift
if edition == .member {
    tabPage(.account) { AccountTab() }
}
```

**Step 4: 更新 onAppear/onChange 逻辑**

如果当前 selectedTab 是 `.account` 但切到了 byoKey 模式，需要回退:
```swift
if (selectedTab == .models && edition == .member) ||
   (selectedTab == .account && edition != .member) {
    selectedTab = .general
}
```

**Step 5: 验证编译**

注意: 这一步会编译失败，因为 `AccountTab` 和 `EditionSwitchLink` 还不存在。这是预期的，在 Task 7/8 创建后才能通过。先 commit SettingsView 的修改。

Run: `cd ~/projects/type4me && swift build 2>&1 | grep "error:" | head -5`
Expected: error about missing AccountTab and EditionSwitchLink

**Step 6: Commit (WIP)**

```bash
git add Type4Me/UI/Settings/SettingsView.swift
git commit -m "wip: add account tab to sidebar layout (pending AccountTab view)"
```

---

### Task 7: SidebarEditionCard 简化为 EditionSwitchLink

**Files:**
- Modify: `Type4Me/UI/Settings/SidebarEditionCard.swift`

**Step 1: 重构为 EditionSwitchLink**

将 `SidebarEditionCard` 重命名为 `EditionSwitchLink`，只保留版本切换功能，移除账户预览:

```swift
struct EditionSwitchLink: View {
    @ObservedObject private var auth = CloudAuthManager.shared
    @State private var showSwitchConfirm = false
    @State private var showLoginAlert = false
    @AppStorage("tf_app_edition") private var editionRaw: String?

    private var edition: AppEdition? {
        editionRaw.flatMap { AppEdition(rawValue: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switchLink
        }
        .confirmationDialog(
            L("切换版本", "Switch Edition"),
            isPresented: $showSwitchConfirm,
            titleVisibility: .visible
        ) {
            Button(switchTargetLabel) { performSwitch() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(switchConfirmMessage)
        }
        .alert(
            L("请先登录", "Please log in first"),
            isPresented: $showLoginAlert
        ) {
            Button("OK") {}
        } message: {
            Text(L(
                "切换到官方会员需要先登录 Type4Me Cloud 账户。请在设置中登录后再试。",
                "Switching to Member requires a Type4Me Cloud account. Please log in first."
            ))
        }
    }

    private var switchLink: some View {
        Button {
            if switchTarget == .member && !auth.isLoggedIn {
                showLoginAlert = true
            } else {
                showSwitchConfirm = true
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: edition == .member ? "key.fill" : "person.crop.circle")
                    .font(.system(size: 10))
                Text(switchTargetLabel)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
            }
            .font(.system(size: 10))
            .foregroundStyle(TF.settingsTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // 保留现有的 switchTarget, switchTargetLabel, switchConfirmMessage, performSwitch()
    // ... (从现有 SidebarEditionCard 中复制)
}
```

**Step 2: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | grep "error:" | head -5`
Expected: 只剩 AccountTab 未定义的错误

**Step 3: Commit**

```bash
git add Type4Me/UI/Settings/SidebarEditionCard.swift
git commit -m "refactor: simplify SidebarEditionCard to EditionSwitchLink (account info moved to AccountTab)"
```

---

### Task 8: AccountTab 视图 (未登录状态)

**Files:**
- Create: `Type4Me/UI/Settings/AccountTab.swift`

**Step 1: 创建 AccountTab 基本结构**

```swift
// Type4Me/UI/Settings/AccountTab.swift

import SwiftUI

struct AccountTab: View, SettingsCardHelpers {
    @ObservedObject private var auth = CloudAuthManager.shared
    @ObservedObject private var quota = CloudQuotaManager.shared

    var body: some View {
        if auth.isLoggedIn {
            loggedInView
        } else {
            loginView
        }
    }
}
```

**Step 2: 实现 loginView (邮箱登录 + 匿名模式)**

```swift
// MARK: - Login View

extension AccountTab {
    @ViewBuilder
    private var loginView: some View {
        SettingsSectionHeader(
            label: "ACCOUNT",
            title: L("账户", "Account"),
            description: L(
                "登录后即可使用 Type4Me Cloud 语音识别和文本处理服务。",
                "Sign in to use Type4Me Cloud voice recognition and text processing."
            )
        )

        // 邮箱登录
        emailLoginCard

        Spacer().frame(height: 16)

        // 匿名模式
        anonymousLoginCard
    }
}
```

**Step 3: 实现邮箱登录卡片**

从现有 `CloudSettingsCard.loginContent` 迁移邮箱验证码流程。

所需 @State 变量:
```swift
@State private var email = ""
@State private var codeSent = false
@State private var verificationCode = ""
@State private var isLoading = false
@State private var errorMessage: String?
```

邮箱登录卡片使用 `settingsGroupCard` 包裹，内容复用 CloudSettingsCard 中的 email input + send code + verify code 流程。

**Step 4: 实现匿名登录卡片**

```swift
// 匿名模式相关 @State
@State private var anonUsername = ""
@State private var anonPassword = ""
@State private var anonIsLogin = false  // toggle: 注册 vs 登录
@State private var anonLoading = false
@State private var anonError: String?

private var anonymousLoginCard: some View {
    settingsGroupCard(L("匿名模式", "Anonymous Mode"), icon: "person.fill.questionmark") {
        Text(L(
            "不想提供邮箱？设置用户名和密码即可使用。",
            "Don't want to use email? Set a username and password."
        ))
        .font(.system(size: 12))
        .foregroundStyle(TF.settingsTextTertiary)
        .padding(.bottom, 4)

        // Toggle: 注册 / 登录
        HStack(spacing: 12) {
            Button(L("注册新账户", "Register")) {
                anonIsLogin = false
                anonError = nil
            }
            .foregroundStyle(anonIsLogin ? TF.settingsTextSecondary : TF.settingsText)

            Button(L("已有账户", "Log in")) {
                anonIsLogin = true
                anonError = nil
            }
            .foregroundStyle(anonIsLogin ? TF.settingsText : TF.settingsTextSecondary)
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .padding(.bottom, 4)

        // Input fields
        HStack(spacing: 8) {
            FixedWidthTextField(text: $anonUsername, placeholder: L("用户名", "Username"))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

            FixedWidthSecureField(text: $anonPassword, placeholder: L("密码 (至少6位)", "Password (6+ chars)"))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

            primaryButton(
                anonLoading
                    ? L("请等待...", "Please wait...")
                    : anonIsLogin ? L("登录", "Log in") : L("注册", "Register")
            ) {
                anonIsLogin ? loginAnonymous() : registerAnonymous()
            }
            .disabled(anonUsername.isEmpty || anonPassword.count < 6 || anonLoading)
        }

        if let error = anonError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsAccentRed)
        }
    }
}
```

**Step 5: 实现注册和登录 action**

```swift
private func registerAnonymous() {
    anonLoading = true
    anonError = nil
    Task {
        do {
            try await auth.registerAnonymous(username: anonUsername, password: anonPassword)
        } catch CloudAPIError.usernameTaken {
            anonError = L("用户名已被占用", "Username already exists")
        } catch {
            anonError = error.localizedDescription
        }
        anonLoading = false
    }
}

private func loginAnonymous() {
    anonLoading = true
    anonError = nil
    Task {
        do {
            try await auth.loginWithPassword(username: anonUsername, password: anonPassword)
        } catch {
            anonError = error.localizedDescription
        }
        anonLoading = false
    }
}
```

**Step 6: 添加 loggedInView 占位符**

```swift
@ViewBuilder
private var loggedInView: some View {
    Text("TODO: logged in view")
}
```

**Step 7: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (所有之前的 WIP commit 现在应该能编译了)

**Step 8: Commit**

```bash
git add Type4Me/UI/Settings/AccountTab.swift
git commit -m "feat: add AccountTab with email login and anonymous mode (login view)"
```

---

### Task 9: AccountTab 已登录视图

**Files:**
- Modify: `Type4Me/UI/Settings/AccountTab.swift`

**Step 1: 实现个人信息区块**

```swift
@ViewBuilder
private var loggedInView: some View {
    SettingsSectionHeader(
        label: "ACCOUNT",
        title: L("账户", "Account"),
        description: ""
    )

    // 1. 个人信息
    profileCard

    Spacer().frame(height: 16)

    // 2. 订阅
    subscriptionCard

    Spacer().frame(height: 16)

    // 3. 用量统计
    usageCard

    Spacer().frame(height: 16)

    // 4. 账单历史
    billingCard

    Spacer().frame(height: 16)

    // 登出
    Button(L("登出", "Log out")) {
        Task { await auth.signOut() }
    }
    .buttonStyle(.plain)
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(TF.settingsAccentRed)
}
```

**Step 2: profileCard**

```swift
private var profileCard: some View {
    settingsGroupCard(L("个人信息", "Profile"), icon: "person.circle.fill") {
        HStack(spacing: 10) {
            // Avatar
            let letter = (auth.userEmail?.first ?? auth.username?.first)
                .map(String.init)?.uppercased() ?? "?"
            Text(letter)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(TF.settingsNavActive))

            VStack(alignment: .leading, spacing: 2) {
                Text(auth.userEmail ?? auth.username ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TF.settingsText)

                if auth.loginMethod == .anonymous && auth.userEmail == nil {
                    Text(L("请牢记用户名和密码，未绑定邮箱将无法找回", "Remember your credentials — without email binding, recovery is impossible"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Status badge
            statusBadge
        }

        // 绑定邮箱入口 (匿名用户)
        if auth.loginMethod == .anonymous && auth.userEmail == nil {
            SettingsDivider()
            Button(L("绑定邮箱", "Bind email")) {
                // TODO: bind email flow
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.settingsAccentAmber)
        }
    }
}

private var statusBadge: some View {
    Text(quota.isPaid ? L("已订阅", "Subscribed") : L("免费", "Free"))
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                quota.isPaid
                    ? TF.settingsAccentGreen.opacity(0.15)
                    : Color.orange.opacity(0.15)
            )
        )
        .foregroundStyle(quota.isPaid ? TF.settingsAccentGreen : .orange)
}
```

**Step 3: subscriptionCard**

```swift
private var subscriptionCard: some View {
    settingsGroupCard(L("订阅", "Subscription"), icon: "creditcard.fill") {
        if quota.isPaid {
            SettingsRow(label: L("套餐", "Plan"), value: L("周订阅", "Weekly"), statusColor: .green)
            if let exp = quota.expiresAt {
                SettingsRow(label: L("到期", "Expires"), value: formatDate(exp))
            }
        } else {
            SettingsRow(label: L("套餐", "Plan"), value: L("免费", "Free"))
            HStack {
                Text(L("剩余字数", "Remaining"))
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Text("\(quota.freeCharsRemaining) / 2000")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(quota.freeCharsRemaining > 500 ? TF.settingsTextSecondary : .orange)
            }
            .padding(.vertical, 10)
        }

        if !quota.isPaid {
            SettingsDivider()
            let priceLabel = CloudConfig.currentRegion == .cn
                ? CloudConfig.weeklyPriceCN : CloudConfig.weeklyPriceUS
            primaryButton(L("订阅 \(priceLabel)/周", "Subscribe \(priceLabel)/wk")) {
                // TODO: open payment page
            }
        }
    }
}
```

**Step 4: usageCard**

```swift
private var usageCard: some View {
    settingsGroupCard(L("用量统计", "Usage"), icon: "chart.bar.fill") {
        SettingsRow(
            label: L("本周用量", "This week"),
            value: "\(quota.weekChars) " + L("字", "chars")
        )
        SettingsRow(
            label: L("总计", "Total"),
            value: "\(quota.totalChars) " + L("字", "chars")
        )
    }
}
```

**Step 5: billingCard (带加载状态)**

```swift
@State private var billingRecords: [BillingRecord] = []
@State private var billingLoading = false
@State private var billingError: String?

struct BillingRecord: Decodable, Identifiable {
    let id: Int
    let amount: Int
    let currency: String
    let status: String
    let description: String?
    let created_at: String
}

private var billingCard: some View {
    settingsGroupCard(L("账单历史", "Billing History"), icon: "doc.text.fill") {
        if billingLoading {
            HStack {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            }
            .padding(.vertical, 10)
        } else if let error = billingError {
            HStack {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsAccentRed)
                Spacer()
                Button(L("重试", "Retry")) { fetchBilling() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsAccentAmber)
            }
            .padding(.vertical, 10)
        } else if billingRecords.isEmpty {
            Text(L("暂无账单记录", "No billing records"))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.vertical, 10)
        } else {
            ForEach(billingRecords) { record in
                HStack {
                    Text(formatBillingDate(record.created_at))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextSecondary)
                    Spacer()
                    Text(record.description ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsText)
                    Spacer()
                    Text(formatAmount(record.amount, currency: record.currency))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                }
                .padding(.vertical, 6)
                if record.id != billingRecords.last?.id {
                    SettingsDivider()
                }
            }
        }
    }
}

private func fetchBilling() {
    billingLoading = true
    billingError = nil
    Task {
        do {
            let data = try await CloudAPIClient.shared.request("/api/billing/history")
            billingRecords = try JSONDecoder().decode([BillingRecord].self, from: data)
        } catch {
            billingError = L("加载失败", "Failed to load")
        }
        billingLoading = false
    }
}

private func formatBillingDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    guard let date = f.date(from: iso) else { return iso }
    let df = DateFormatter()
    df.dateStyle = .medium
    return df.string(from: date)
}

private func formatAmount(_ cents: Int, currency: String) -> String {
    let amount = Double(cents) / 100.0
    return currency == "CNY" ? "¥\(String(format: "%.2f", amount))" : "$\(String(format: "%.2f", amount))"
}

private func formatDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    return f.string(from: date)
}
```

**Step 6: 添加 .task 刷新数据**

在 body 的 `loggedInView` 分支加:
```swift
.task {
    if auth.isLoggedIn {
        await quota.refresh(force: true)
        fetchBilling()
    }
}
```

**Step 7: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add Type4Me/UI/Settings/AccountTab.swift
git commit -m "feat: add AccountTab logged-in view (profile, subscription, usage, billing)"
```

---

### Task 10: 设备互踢提示 UI

**Files:**
- Modify: `Type4Me/UI/Settings/SettingsView.swift`

**Step 1: 监听设备互踢通知**

在 `SettingsView` 中添加:

```swift
@State private var showDeviceConflict = false

// 在 body 中添加 .onReceive:
.onReceive(NotificationCenter.default.publisher(for: .cloudDeviceConflict)) { _ in
    showDeviceConflict = true
}
.alert(
    L("设备冲突", "Device Conflict"),
    isPresented: $showDeviceConflict
) {
    Button("OK") {
        selectedTab = .account
    }
} message: {
    Text(L(
        "你的账户已在其他设备登录，当前设备已自动登出。",
        "Your account has been logged in on another device. This device has been signed out."
    ))
}
```

**Step 2: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Type4Me/UI/Settings/SettingsView.swift
git commit -m "feat: show device conflict alert when session is kicked"
```

---

### Task 11: 清理 CloudSettingsCard

**Files:**
- Delete: `Type4Me/UI/Settings/CloudSettingsCard.swift`
- Modify: 引用 CloudSettingsCard 的文件 (如果有)

**Step 1: 搜索引用**

Run: `grep -rn "CloudSettingsCard" --include="*.swift" ~/projects/type4me/Type4Me/`

如果只在 CloudSettingsCard.swift 自身和某个 tab 中使用，删除文件并移除引用。

**Step 2: 删除文件并修复引用**

```bash
git rm Type4Me/UI/Settings/CloudSettingsCard.swift
```

修改引用它的 tab view，移除 `CloudSettingsCard()` 调用。

**Step 3: 验证编译**

Run: `cd ~/projects/type4me && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git commit -m "refactor: remove CloudSettingsCard (merged into AccountTab)"
```

---

## Part B: 服务端

### Task 12: 数据库迁移

**Files:**
- Create: `migrations/004_anonymous_auth_and_billing.sql`

**Step 1: 创建迁移文件**

```sql
-- migrations/004_anonymous_auth_and_billing.sql
-- Anonymous login, device binding, and billing history

-- Users: add username/password and login method
ALTER TABLE users ADD COLUMN username TEXT UNIQUE;
ALTER TABLE users ADD COLUMN password_hash TEXT;
ALTER TABLE users ADD COLUMN login_method TEXT NOT NULL DEFAULT 'email';
ALTER TABLE users ADD COLUMN active_device_id TEXT;

-- Device bindings: track which devices are bound to which accounts
CREATE TABLE device_bindings (
    device_id TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id),
    login_method TEXT NOT NULL,
    bound_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (device_id, login_method)
);

-- Billing history: payment records
CREATE TABLE billing_history (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id UUID NOT NULL REFERENCES users(id),
    amount INTEGER NOT NULL,
    currency TEXT NOT NULL,
    provider TEXT,
    external_id TEXT,
    status TEXT NOT NULL DEFAULT 'completed',
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_billing_history_user ON billing_history(user_id);

-- Login rate limiting
CREATE TABLE login_attempts (
    username TEXT NOT NULL,
    ip TEXT NOT NULL,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    success BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_login_attempts_username ON login_attempts(username, attempted_at);
CREATE INDEX idx_login_attempts_ip ON login_attempts(ip, attempted_at);
```

**Step 2: 应用迁移**

Run: `psql $DATABASE_URL -f migrations/004_anonymous_auth_and_billing.sql`

**Step 3: Commit**

```bash
git add migrations/004_anonymous_auth_and_billing.sql
git commit -m "db: add anonymous auth, device binding, and billing history tables"
```

---

### Task 13: 服务端匿名注册和密码登录

**Files:**
- Modify: `internal/auth/handler.go`
- Modify: `internal/auth/jwt.go`

**Step 1: 添加 bcrypt 依赖**

Run: `cd ~/projects/type4me-server && go get golang.org/x/crypto/bcrypt`

**Step 2: 在 AuthHandler 中添加 Register 方法**

在 `handler.go` 中新增:

```go
// Register creates an anonymous account with username + password.
// POST /auth/register  {"username": "...", "password": "...", "device_id": "..."}
func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Username string `json:"username"`
        Password string `json:"password"`
        DeviceID string `json:"device_id"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        jsonError(w, "invalid request", http.StatusBadRequest)
        return
    }
    if len(req.Username) < 1 || len(req.Password) < 6 {
        jsonError(w, "username required, password must be 6+ characters", http.StatusBadRequest)
        return
    }

    // Check device binding limit
    var count int
    h.db.QueryRow(
        `SELECT COUNT(*) FROM device_bindings WHERE device_id = $1 AND login_method = 'anonymous'`,
        req.DeviceID,
    ).Scan(&count)
    if count >= 1 {
        jsonErrorCode(w, "device_limit", "This device already has an anonymous account", http.StatusForbidden)
        return
    }

    // Hash password
    hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), 12)
    if err != nil {
        log.Printf("bcrypt error: %v", err)
        jsonError(w, "internal error", http.StatusInternalServerError)
        return
    }

    // Create user
    var userID string
    err = h.db.QueryRow(
        `INSERT INTO users (username, password_hash, login_method)
         VALUES ($1, $2, 'anonymous') RETURNING id`,
        req.Username, string(hash),
    ).Scan(&userID)
    if err != nil {
        if isUniqueViolation(err) {
            jsonErrorCode(w, "username_taken", "Username already exists", http.StatusConflict)
            return
        }
        log.Printf("failed to create user: %v", err)
        jsonError(w, "internal error", http.StatusInternalServerError)
        return
    }

    // Create free plan
    h.db.Exec(
        `INSERT INTO user_plans (user_id, plan, free_chars_remaining) VALUES ($1, 'free', 2000)`,
        userID,
    )

    // Device binding
    h.db.Exec(
        `INSERT INTO device_bindings (device_id, user_id, login_method) VALUES ($1, $2, 'anonymous')`,
        req.DeviceID, userID,
    )

    // Set active device
    h.db.Exec(`UPDATE users SET active_device_id = $1 WHERE id = $2`, req.DeviceID, userID)

    // Issue JWT (1 year)
    token, err := h.issuer.IssueAnonymous(userID, req.Username)
    if err != nil {
        log.Printf("failed to issue token: %v", err)
        jsonError(w, "internal error", http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]string{
        "token":    token,
        "user_id":  userID,
        "username": req.Username,
    })
}
```

**Step 3: 添加 Login 方法**

```go
// Login authenticates with username + password.
// POST /auth/login  {"username": "...", "password": "...", "device_id": "..."}
func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Username string `json:"username"`
        Password string `json:"password"`
        DeviceID string `json:"device_id"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        jsonError(w, "invalid request", http.StatusBadRequest)
        return
    }

    ip := r.Header.Get("X-Real-IP")
    if ip == "" { ip = r.RemoteAddr }

    // Rate limit: 5 failures per username in 15 min
    if blocked := h.checkLoginRateLimit(req.Username, ip); blocked {
        jsonError(w, "too many failed attempts, try again later", http.StatusTooManyRequests)
        return
    }

    // Find user
    var userID, hash string
    var email sql.NullString
    err := h.db.QueryRow(
        `SELECT id, password_hash, email FROM users WHERE username = $1`,
        req.Username,
    ).Scan(&userID, &hash, &email)
    if err != nil {
        h.recordLoginAttempt(req.Username, ip, false)
        jsonErrorCode(w, "invalid_credentials", "Invalid username or password", http.StatusUnauthorized)
        return
    }

    // Verify password
    if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)); err != nil {
        h.recordLoginAttempt(req.Username, ip, false)
        jsonErrorCode(w, "invalid_credentials", "Invalid username or password", http.StatusUnauthorized)
        return
    }

    h.recordLoginAttempt(req.Username, ip, true)

    // Update active device (kicks old device)
    h.db.Exec(`UPDATE users SET active_device_id = $1 WHERE id = $2`, req.DeviceID, userID)

    // Issue JWT
    token, err := h.issuer.IssueAnonymous(userID, req.Username)
    if err != nil {
        jsonError(w, "internal error", http.StatusInternalServerError)
        return
    }

    resp := map[string]interface{}{
        "token":    token,
        "user_id":  userID,
        "username": req.Username,
    }
    if email.Valid {
        resp["email"] = email.String
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(resp)
}
```

**Step 4: 添加 rate limiting 和 helper 函数**

```go
func (h *AuthHandler) checkLoginRateLimit(username, ip string) bool {
    var count int
    h.db.QueryRow(
        `SELECT COUNT(*) FROM login_attempts
         WHERE username = $1 AND success = false
         AND attempted_at > NOW() - INTERVAL '15 minutes'`,
        username,
    ).Scan(&count)
    if count >= 5 {
        return true
    }

    // Per-IP: 20 per minute
    h.db.QueryRow(
        `SELECT COUNT(*) FROM login_attempts
         WHERE ip = $1 AND attempted_at > NOW() - INTERVAL '1 minute'`,
        ip,
    ).Scan(&count)
    return count >= 20
}

func (h *AuthHandler) recordLoginAttempt(username, ip string, success bool) {
    h.db.Exec(
        `INSERT INTO login_attempts (username, ip, success) VALUES ($1, $2, $3)`,
        username, ip, success,
    )
}

func jsonError(w http.ResponseWriter, msg string, code int) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(code)
    json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func jsonErrorCode(w http.ResponseWriter, errCode, msg string, httpCode int) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(httpCode)
    json.NewEncoder(w).Encode(map[string]string{"error": errCode, "message": msg})
}

func isUniqueViolation(err error) bool {
    return strings.Contains(err.Error(), "duplicate key") ||
           strings.Contains(err.Error(), "unique constraint")
}
```

**Step 5: 在 jwt.go 中添加 IssueAnonymous**

```go
// IssueAnonymous creates a JWT for an anonymous (username-based) user. Valid for 1 year.
func (i *Issuer) IssueAnonymous(userID, username string) (string, error) {
    now := time.Now()
    claims := jwt.MapClaims{
        "sub":      userID,
        "username": username,
        "iat":      now.Unix(),
        "exp":      now.Add(365 * 24 * time.Hour).Unix(),
    }
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
    return token.SignedString(i.secret)
}
```

同时更新现有 `Issue()` 方法的 exp 为 1 年:
```go
"exp": now.Add(365 * 24 * time.Hour).Unix(),
```

**Step 6: 验证编译**

Run: `cd ~/projects/type4me-server && go build ./...`
Expected: 成功

**Step 7: Commit**

```bash
git add internal/auth/handler.go internal/auth/jwt.go go.mod go.sum
git commit -m "feat: add anonymous register and password login endpoints"
```

---

### Task 14: 设备绑定中间件

**Files:**
- Modify: `internal/proxy/middleware.go`

**Step 1: 在 AuthMiddlewareFunc 中添加设备校验**

需要给 middleware 注入 db 引用。改造 `AuthMiddlewareFunc`:

```go
// DeviceAwareAuthMiddleware verifies JWT and checks device binding.
func DeviceAwareAuthMiddleware(verifier *auth.Verifier, db *sql.DB, handler http.HandlerFunc) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        token := extractToken(r)
        if token == "" {
            jsonError(w, "token_expired", "Missing authentication token", http.StatusUnauthorized)
            return
        }

        claims, err := verifier.Verify(token)
        if err != nil {
            jsonError(w, "token_expired", "Invalid or expired token", http.StatusUnauthorized)
            return
        }

        // Check device binding
        deviceID := r.Header.Get("X-Device-ID")
        if deviceID == "" {
            deviceID = r.URL.Query().Get("device_id")
        }

        if deviceID != "" {
            var activeDevice sql.NullString
            db.QueryRow(`SELECT active_device_id FROM users WHERE id = $1`, claims.UserID).Scan(&activeDevice)
            if activeDevice.Valid && activeDevice.String != "" && activeDevice.String != deviceID {
                jsonError(w, "device_conflict", "Account logged in on another device", http.StatusUnauthorized)
                return
            }
        }

        ctx := context.WithValue(r.Context(), userIDKey, claims.UserID)
        handler(w, r.WithContext(ctx))
    }
}

func jsonError(w http.ResponseWriter, code, msg string, httpCode int) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(httpCode)
    json.NewEncoder(w).Encode(map[string]string{"error": code, "message": msg})
}
```

**Step 2: 更新 main.go 路由注册**

将 `proxy.AuthMiddlewareFunc(verifier, ...)` 改为 `proxy.DeviceAwareAuthMiddleware(verifier, db, ...)`。

所有受保护的路由都需要更新:
```go
mux.HandleFunc("GET /api/quota", proxy.DeviceAwareAuthMiddleware(verifier, db, api.QuotaHandler(quotaMgr)))
mux.HandleFunc("GET /api/usage", proxy.DeviceAwareAuthMiddleware(verifier, db, api.UsageHandler(quotaMgr)))
// ... 其余类似
```

同时注册新路由:
```go
mux.HandleFunc("POST /auth/register", authHandler.Register)
mux.HandleFunc("POST /auth/login", authHandler.Login)
```

**Step 3: 验证编译**

Run: `cd ~/projects/type4me-server && go build ./...`
Expected: 成功

**Step 4: Commit**

```bash
git add internal/proxy/middleware.go cmd/proxy/main.go
git commit -m "feat: add device-aware auth middleware and register new auth routes"
```

---

### Task 15: 账单历史 API

**Files:**
- Create: `internal/api/billing.go`
- Modify: `cmd/proxy/main.go`

**Step 1: 创建 billing handler**

```go
package api

import (
    "encoding/json"
    "net/http"

    "github.com/nicekid1/type4me-server/internal/proxy"
    "github.com/nicekid1/type4me-server/internal/quota"
)

func BillingHistoryHandler(mgr *quota.Manager) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        userID := proxy.UserIDFromContext(r.Context())

        rows, err := mgr.DB.Query(
            `SELECT id, amount, currency, status, description, created_at
             FROM billing_history WHERE user_id = $1
             ORDER BY created_at DESC LIMIT 50`,
            userID,
        )
        if err != nil {
            http.Error(w, "internal error", http.StatusInternalServerError)
            return
        }
        defer rows.Close()

        type Record struct {
            ID          int64  `json:"id"`
            Amount      int    `json:"amount"`
            Currency    string `json:"currency"`
            Status      string `json:"status"`
            Description *string `json:"description"`
            CreatedAt   string `json:"created_at"`
        }

        var records []Record
        for rows.Next() {
            var rec Record
            var desc *string
            var createdAt time.Time
            if err := rows.Scan(&rec.ID, &rec.Amount, &rec.Currency, &rec.Status, &desc, &createdAt); err != nil {
                continue
            }
            rec.Description = desc
            rec.CreatedAt = createdAt.Format(time.RFC3339)
            records = append(records, rec)
        }

        if records == nil {
            records = []Record{} // 空数组而不是 null
        }

        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(records)
    }
}
```

**Step 2: 注册路由**

在 main.go 中添加:
```go
mux.HandleFunc("GET /api/billing/history", proxy.DeviceAwareAuthMiddleware(verifier, db, api.BillingHistoryHandler(quotaMgr)))
```

**Step 3: 验证编译**

Run: `cd ~/projects/type4me-server && go build ./...`
Expected: 成功

**Step 4: Commit**

```bash
git add internal/api/billing.go cmd/proxy/main.go
git commit -m "feat: add billing history API endpoint"
```

---

### Task 16: 更新邮箱登录端点支持 device_id

**Files:**
- Modify: `internal/auth/handler.go`

**Step 1: SendCode 接收 device_id (可选)**

修改 `SendCode` 的请求结构体:
```go
var req struct {
    Email    string `json:"email"`
    DeviceID string `json:"device_id"`
}
```

device_id 在 SendCode 阶段不做校验，只是提前接收。

**Step 2: Verify 处理 device_id**

修改 `Verify` 的请求结构体:
```go
var req struct {
    Email    string `json:"email"`
    Code     string `json:"code"`
    DeviceID string `json:"device_id"`
}
```

在创建/查找用户后:
```go
// 检查设备绑定限制 (一个设备一个邮箱账户)
if req.DeviceID != "" {
    var count int
    h.db.QueryRow(
        `SELECT COUNT(*) FROM device_bindings WHERE device_id = $1 AND login_method = 'email'`,
        req.DeviceID,
    ).Scan(&count)
    // 只在新用户注册时检查，已有用户登录不限制
    if err == sql.ErrNoRows && count >= 1 {
        // 新注册但设备已有邮箱账户
        jsonErrorCode(w, "device_limit", "This device already has an email account", http.StatusForbidden)
        return
    }

    // 写入设备绑定 (ON CONFLICT 更新)
    h.db.Exec(
        `INSERT INTO device_bindings (device_id, user_id, login_method)
         VALUES ($1, $2, 'email')
         ON CONFLICT (device_id, login_method) DO UPDATE SET user_id = $2, bound_at = NOW()`,
        req.DeviceID, userID,
    )

    // 更新活跃设备
    h.db.Exec(`UPDATE users SET active_device_id = $1 WHERE id = $2`, req.DeviceID, userID)
}
```

同时更新 JWT 有效期为 1 年 (已在 Task 13 Step 5 完成)。

**Step 3: 验证编译**

Run: `cd ~/projects/type4me-server && go build ./...`
Expected: 成功

**Step 4: Commit**

```bash
git add internal/auth/handler.go
git commit -m "feat: add device_id support to email verification flow"
```

---

### Task 17: 集成测试

**Step 1: 本地启动服务端**

确保 PostgreSQL 运行，应用迁移，启动 server。

**Step 2: 测试匿名注册**

```bash
curl -X POST http://localhost:PORT/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","device_id":"test-device-1"}'
```

Expected: `{"token":"...","user_id":"...","username":"testuser"}`

**Step 3: 测试密码登录**

```bash
curl -X POST http://localhost:PORT/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","device_id":"test-device-1"}'
```

Expected: 200 OK with token

**Step 4: 测试设备互踢**

```bash
# 在设备 2 登录
curl -X POST http://localhost:PORT/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","device_id":"test-device-2"}'

# 用设备 1 的 token 请求 quota
curl http://localhost:PORT/api/quota \
  -H "Authorization: Bearer OLD_TOKEN" \
  -H "X-Device-ID: test-device-1"
```

Expected: 401 with `{"error":"device_conflict",...}`

**Step 5: 测试重复注册**

```bash
curl -X POST http://localhost:PORT/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","device_id":"test-device-1"}'
```

Expected: 409 with `{"error":"username_taken",...}`

**Step 6: 测试客户端 UI**

1. `cd ~/projects/type4me && scripts/deploy.sh` 构建并启动 app
2. 打开设置，切换到 Member 版
3. 点击底部 Account tab
4. 测试邮箱登录流程
5. 登出，测试匿名注册流程
6. 验证已登录视图的四个区块都正常显示
7. 验证版本切换链接正常工作

**Step 7: Commit (如有修复)**

```bash
git commit -m "fix: integration test fixes"
```
