# Type4Me 手机版（测试中）

iPhone 上的 Type4Me 是一个语音键盘：在任何输入框切到 Type4Me 键盘，按住说话，松手出字。和 Mac 版一样可以选识别服务、文本模型和模式，热词和片段替换也能用。

手机版正在 TestFlight 公开测试，直接在 iPhone 上打开 [https://testflight.apple.com/join/57f5897s](https://testflight.apple.com/join/57f5897s) 安装即可。想自己编译的话，按下面的步骤用 Xcode 装到 iPhone 上。

<table>
  <tr>
    <td width="25%"><img src="../docs/screenshots/ios-keyboard.png" alt="键盘：按住说话，松手出字" /></td>
    <td width="25%"><img src="../docs/screenshots/ios-home.png" alt="首页：用量与我的模式" /></td>
    <td width="25%"><img src="../docs/screenshots/ios-settings.png" alt="设置：识别、模型与词汇" /></td>
    <td width="25%"><img src="../docs/screenshots/ios-scan-sync.jpg" alt="扫码同步 Mac 上的配置" /></td>
  </tr>
  <tr>
    <td align="center"><sub>键盘：按住说话，松手出字</sub></td>
    <td align="center"><sub>首页：用量与我的模式</sub></td>
    <td align="center"><sub>设置：识别、模型与词汇</sub></td>
    <td align="center"><sub>扫码同步 Mac 上的配置</sub></td>
  </tr>
</table>

## 需要准备

- iPhone，iOS 26 或更新版本。
- Mac，装好 Xcode 26 或更新版本，以及 [Homebrew](https://brew.sh)。
- Apple 账号。免费的 Apple ID 就能装，但这样装的 App 7 天后会失效，需要重新运行一次；付费开发者账号没有这个限制。
- 一个云端语音识别服务的 API Key（比如火山引擎、Soniox），要润色、翻译还需要一个文本模型的 API Key。已经在用 Mac 版的话，可以直接从 Mac 同步。

## 安装

1. 下载代码，安装 XcodeGen：

   ```bash
   git clone https://github.com/joewongjc/type4me.git
   cd type4me/iOS
   brew install xcodegen
   ```

2. 在 `iOS/` 目录新建 `Signing.local.xcconfig`，填上你自己的签名信息：

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   T4M_BUNDLE_ID_PREFIX = com.yourname.type4me
   ```

   - `DEVELOPMENT_TEAM`：先在 Xcode › Settings › Accounts 登录 Apple 账号，选中账号下面的团队就能看到 Team ID。
   - `T4M_BUNDLE_ID_PREFIX`：起一个只属于你的前缀，比如 `com.你的名字.type4me`。默认的 `com.type4me` 已经被注册，不能用。

3. 生成工程并用 Xcode 打开：

   ```bash
   xcodegen generate
   open Type4MeiOS.xcodeproj
   ```

4. 用数据线连上 iPhone。在 Xcode 顶部选 `Type4MeiOS` 和你的 iPhone，点运行（⌘R）。第一次运行时 Xcode 会自动注册 App ID 和 App Group，等它完成。
5. 第一次装到手机上时：
   - iPhone 提示需要开发者模式：打开「设置 › 隐私与安全性 › 开发者模式」，按提示重启。
   - 用免费 Apple ID 时，打开「设置 › 通用 › VPN 与设备管理」，信任你的开发者证书。
6. 打开 Type4Me，按引导添加键盘：「设置 › 通用 › 键盘 › 键盘 › 添加新键盘 › Type4Me」，再打开「允许完全访问」。键盘要靠完全访问和 App 通信。听写内容只发给你自己配置的识别服务和模型，不经过其他服务器。

## 配置

两种方式选一种：

- **从 Mac 同步**：在 Mac 版 Type4Me 的侧边栏打开「手机版」，勾选要同步的识别服务、模型、模式和词汇。在手机版里点「设置 › 扫码同步」对准二维码。内容多时 Mac 会轮播几张码，保持对准直到扫齐。
- **在手机上填**：在「设置 › 识别服务」和「设置 › 处理模型」里直接填写 API Key，每项都能测试连接。

密钥只保存在这台 iPhone 的钥匙串里。二维码里的 API Key 没有加密，不要截图分享。

## 使用

1. 打开 Type4Me App 开启语音会话，然后回到要打字的 App。
2. 切到 Type4Me 键盘，选一个模式，按住麦克风说话，松手出字。
3. App 被系统清掉或者手动划掉后，键盘上的麦克风会变成空心，点一下跳回 App 重新开启。

只有按住说话时才打开麦克风，松开就关。iOS 不允许键盘直接录音，所以录音、识别和调用模型都在 App 里完成，App 要留在后台待命。

## 问题反馈

在 [GitHub Issues](https://github.com/joewongjc/type4me/issues) 里反馈，标题注明「手机版」。「设置 › 诊断记录」可以一键复制最近的运行记录，贴在 Issue 里方便排查。

## 给开发者

### 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程描述，改完运行 `xcodegen generate` |
| `Signing.xcconfig` | 默认签名设置；自己的值写在 `Signing.local.xcconfig`（Git 忽略） |
| `App/` | 主 App：语音会话、云端识别（`ASR/PhoneASR.swift` 列出支持的服务商）、文本模型调用（OpenAI 兼容和 Claude）、热词和片段替换、引导、扫码导入、首页、历史、设置 |
| `Keyboard/` | 键盘扩展：模式切换、按住说话、出字到光标、撤销 |
| `Shared/` | 两边共用：App Group 路径、键盘与 App 之间的指令和状态格式 |
| `SharedActivity/` | “开启语音会话” App Intent，控制中心按钮和操作按钮共用 |
| `Widgets/` | 控制中心按钮 |
| `../Type4MeTransferCore/` | Mac 和 iPhone 共用的同步格式（`T4M2.` 开头）和片段替换的匹配规则 |
| `../Type4Me/ASR`、`../Type4Me/Protocol` | 所有云端识别服务的客户端、协议和配置，直接复用 Mac 版源码（本地引擎和弃用的百度除外） |
| `../Type4Me/LLM/LLMProvider.swift` | 文本模型服务商的地址、模型列表和思考开关，直接复用 Mac 版 |

### 后台录音的做法

打开 App 时（必须在前台）激活 `playAndRecord` 音频会话并持续输出静音，再挂一个看不见的画中画会话，让进程留在后台，并且可以从后台打开麦克风。之后每次按住说话，App 只在后台打开麦克风输入，说完马上关掉。

- 后台开麦被系统拒绝时，App 记下错误码、音频路由和会话状态，键盘提示“原因见诊断记录”。
- 诊断记录同时写到 App 的 `Library/Caches/diagnostics.log`，连线后可以读出来：`xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier <bundle ID 前缀>.ios --source Library/Caches/diagnostics.log --destination .`

### 真机验证清单

结果都会记在「设置 › 诊断记录」，可以一键复制。

1. 引导：添加键盘、允许完全访问后，在引导页的输入框切到 Type4Me，能显示“已检测到 Type4Me 键盘”。
2. 导入：用 App 里的「扫码同步」扫 Mac「手机版」页面的二维码，多张码轮播时能一次扫齐；iPhone 相机扫单张码能直接打开导入页。
3. 后台开麦：打开 App，回到备忘录，按住说话，诊断里出现“后台开启麦克风成功”。
4. 只有按住说话时状态栏才有麦克风提示，松开、出字后消失，诊断里有“麦克风已关闭”。
5. 放音乐、来电、录微信语音之后，会话能不能恢复。
6. 锁屏 10 分钟、30 分钟后，键盘是否还是实心麦克风。
7. 处理过程中切换到别的输入框，文字应该进剪贴板，不插进新输入框。
8. 控制中心添加“Type4Me 语音会话”按钮，点一下打开 App 并开启会话；操作按钮也可以选它。
9. 设置里的“测试识别服务”“测试处理模型”都显示 ✓ 和耗时。
10. 词汇：在「设置 › 词汇」加一条片段替换，说出触发词，出字里已经替换；从 Mac 同步词汇后，热词和片段数量对得上。
