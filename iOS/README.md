# Type4Me iPhone（MVP）

iPhone 版是一个语音键盘：键盘本身不能录音，录音、识别、调用模型都在 Type4Me App 里完成。App 留在后台待命，键盘通过 App Group 和 Darwin 通知把指令发给它。

## 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程描述，改完运行 `xcodegen generate` |
| `App/` | 主 App：语音会话、云端识别（`ASR/PhoneASR.swift` 列出支持的服务商）、文本模型调用（OpenAI 兼容和 Claude）、引导、扫码导入、首页、历史、设置 |
| `Keyboard/` | 键盘扩展：模式切换、按住说话、出字到光标、撤销 |
| `Shared/` | 两边共用：App Group 路径、键盘与 App 之间的指令和状态格式 |
| `SharedActivity/` | “开启语音会话” App Intent，控制中心按钮和操作按钮共用 |
| `Widgets/` | 控制中心按钮 |
| `../Type4MeTransferCore/` | Mac 和 iPhone 共用的配置文本格式（`T4M1.` 开头） |
| `../Type4Me/ASR`、`../Type4Me/Protocol` | 所有云端识别服务的客户端、协议和配置，直接复用 Mac 版源码（本地引擎和弃用的百度除外） |
| `../Type4Me/LLM/LLMProvider.swift` | 文本模型服务商的地址、模型列表和思考开关，直接复用 Mac 版 |

## 在真机上运行

1. `brew install xcodegen`，然后在本目录运行 `xcodegen generate`。
2. 用 Xcode 打开 `Type4MeiOS.xcodeproj`，选 `Type4MeiOS` scheme 和连接的 iPhone，运行。团队已设为 `T98LK79X2K`，自动签名会注册 `com.type4me.ios`、`com.type4me.ios.keyboard` 和 App Group `group.com.type4me.ios`。
3. 在 Mac 上运行包含本分支改动的 Type4Me，打开「设置 › 模型 › 同步到 iPhone」，用 iPhone 相机扫码。

## 后台录音的做法

打开 App 时（必须在前台）激活 `playAndRecord` 音频会话，并持续输出静音，让进程在后台留着。之后每次按住说话，App 只在后台打开麦克风输入，说完马上关掉。

- 默认「说话时才开麦克风」：其他时候不开麦克风，没有橙点。iOS 是否允许已激活的会话从后台开麦，要在真机上验证。
- 后台开麦被系统拒绝时，App 不会自己改成常开，只记下错误码、音频路由和会话状态，键盘提示“原因见诊断记录”。「会话期间保持麦克风」只能在设置里手动选。
- 诊断记录同时写到 App 的 `Library/Caches/diagnostics.log`，连线后可以读出来：`xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.type4me.ios --source Library/Caches/diagnostics.log --destination .`
- App 被系统清掉或手动划掉后，键盘上的麦克风变成空心，点一下跳回 App 重新开启。

## 真机验证清单

结果都会记在「设置 › 诊断记录」，可以一键复制。

1. 引导：添加键盘、允许完全访问后，在引导页的输入框切到 Type4Me，能显示“已检测到 Type4Me 键盘”。
2. 导入：用 App 里的「扫码同步」扫 Mac 上的二维码，多张码轮播时能一次扫齐；iPhone 相机扫单张码能直接打开导入页。
3. 后台开麦：打开 App，回到备忘录，按住说话。诊断里出现“后台开启麦克风成功”就说明默认做法可行；出现“后台开启麦克风失败”会带错误码。
4. 只有按住说话时状态栏才有麦克风提示，松开、出字后消失，诊断里有“麦克风已关闭”。
5. 放音乐、来电、录微信语音之后，会话能不能恢复。
6. 锁屏 10 分钟、30 分钟后，键盘是否还是实心麦克风。
7. 处理过程中切换到别的输入框，文字应该进剪贴板，不插进新输入框。
8. 控制中心添加“Type4Me 语音会话”按钮，点一下打开 App 并开启会话；操作按钮也可以选它。
9. 设置里的“测试识别服务”“测试处理模型”都显示 ✓ 和耗时。
