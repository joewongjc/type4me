# Type4Me 录音指示器拖动定位开发设计

> 文档类型：开发设计
> 文档状态：当前有效（已实现，待用户验收）
> 设计日期：2026-10-14
> 最后校验：2026-10-14
> 实现基线：`feat/draggable-floating-bar`
> 产品设计：[product-design.md](product-design.md)
> 分支：`feat/draggable-floating-bar`

## 1. 设计摘要

当前录音指示器面板由 `FloatingBarController` 管理，位置只有一种：`FloatingBarPanel.bottomCenteredFrame(size:visibleFrame:)` 把面板放在锚定屏幕 `visibleFrame` 的底部居中，胶囊底边距可见区域底边 `TF.barBottomOffset`。`FloatingBarView` 用 `VStack { topOverlay; capsule }` 加 `.frame(alignment: .bottom)` 把胶囊压在面板底部，因此面板只会向上生长。

本设计引入四个部分：

```text
FloatingBarPlacement            持久化的位置中心（每轴：默认 / 自定义）
FloatingBarPlacementGeometry    纯函数：位置 → 中心点 → 锚定边 → 面板 frame、限位、反算
FloatingBarSnapper              按轴吸附 + 迟滞 + 触感事件
FloatingBarChromeModel          控制器与 SwiftUI 之间的共享状态：锚定边、手柄显示、拖动中
```

再加两个 AppKit 组件：

```text
FloatingBarDragHandleView       手柄 NSView：按下、拖动、松开、光标、无障碍
FloatingBarPlacementGuideWindow 拖动期间的十字虚线参考窗口（不接收鼠标）
```

默认位置下所有几何计算必须与 `bottomCenteredFrame` 逐像素一致，这是首要回归约束。

## 2. 核心工程原则

1. 只持久化**基准形态胶囊中心**；展开高度、浮层、手柄都不参与记录；
2. 吸附的轴保存为 `.default`，不保存具体坐标；
3. 几何计算全部是无 UI 依赖的纯函数，用单元测试覆盖；
4. 拖动期间只改面板 origin，不改 size，避免触发 SwiftUI 重新布局；
5. 拖动期间冻结锚定边，松手后再重新判定，避免手柄在指针下跳到胶囊另一侧；
6. 鼠标位置统一使用屏幕坐标 `NSEvent.mouseLocation`，不使用会随窗口移动而变化的 `locationInWindow`；
7. 外观预览（`presentationOverride != nil`）不注入 `FloatingBarChromeModel`，因此没有手柄、始终底边锚定；
8. 参考窗口按需创建，拖动结束后释放；
9. 新增尺寸、阈值、时长全部进入 `TF` token；
10. 所有文案通过 `L(_:_:)` 在显示时渲染。

## 3. 当前实现基线

### 3.1 面板定位

[FloatingBarPanel.swift](../../../Type4Me/UI/FloatingBar/FloatingBarPanel.swift)：

```swift
static func bottomCenteredFrame(size: NSSize, visibleFrame: NSRect) -> NSRect {
    NSRect(
        x: (visibleFrame.midX - size.width / 2).rounded(),
        y: (visibleFrame.minY + TF.barBottomOffset - TF.floatingPanelShadowInset).rounded(),
        width: size.width,
        height: size.height
    )
}
```

`FloatingBarController.applyPanelSize(_:display:)` 是唯一调用点（除手动输入窗外）。`anchorDisplayID` 在 `show()` 时取鼠标所在屏幕，会话内保持不变。

### 3.2 面板尺寸

`FloatingBarPanelLayout` 包含 `contentSize`、`horizontalOverflow`、`capsuleSize`，`panelSize` 在四周加 `TF.floatingPanelShadowInset`，宽度向上取偶数，以保证 `midX - width / 2` 的像素相位稳定。

### 3.3 视图结构

```swift
VStack(spacing: topOverlayGap) {
    if let overlay = activeTopOverlay { topOverlay(overlay) }
    if shouldRenderCapsule { capsuleBar }
}
.padding(TF.floatingPanelShadowInset)
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
```

浮层有 `.transcript`、`.action(_)`、`.mode` 三种，全部位于胶囊上方。

### 3.4 鼠标交互

- `FloatingBarButtonNSView`：完成、取消按钮的按下、拖动偏移、悬停、点击；
- `HoverTrackingNSView`：`hitTest` 返回 `nil`，进入有 150ms 延迟，并处理面板 resize 时合成的假 exit；
- 面板在有可见内容且非 Hidden 阶段时 `ignoresMouseEvents = false`。

### 3.5 其它共享位置的面板

- `ManualInputPanel`：直接调用 `bottomCenteredFrame`，再按自身阴影内边距修正 y；编辑器最大高度用 `TF.barBottomOffset` 估算；
- `CorrectionLearningPanel.positionAboveFloatingBar()`：硬编码 `visible.minY + TF.barBottomOffset + TF.barHeight + 18`。

## 4. 数据模型与持久化

### 4.1 模型

新文件 `Type4Me/UI/FloatingBar/FloatingBarPlacement.swift`：

```swift
struct FloatingBarPlacement: Codable, Equatable, Sendable {
    enum Horizontal: Codable, Equatable, Sendable {
        case `default`
        /// Center X as a fraction of visibleFrame width, 0...1.
        case fraction(Double)
    }

    enum Vertical: Codable, Equatable, Sendable {
        case `default`
        /// Distance in points from visibleFrame.minY to the base capsule center.
        case fromBottom(Double)
        /// Distance in points from visibleFrame.maxY to the base capsule center.
        case fromTop(Double)
    }

    var version = 1
    var horizontal: Horizontal = .default
    var vertical: Vertical = .default

    static let `default` = FloatingBarPlacement()
    var isDefault: Bool { horizontal == .default && vertical == .default }
}
```

### 4.2 存储

```swift
enum FloatingBarPlacementStore {
    static let storageKey = "tf_floatingBarPlacement"   // JSON String
    static func load(_ defaults: UserDefaults = .standard) -> FloatingBarPlacement
    static func save(_ placement: FloatingBarPlacement, _ defaults: UserDefaults = .standard)
    static func reset(_ defaults: UserDefaults = .standard)  // removeObject
}
```

- 缺失、解析失败、`version` 不认识，一律返回 `.default`，不写回、不报错；
- `save(.default)` 等价于 `reset()`，即删除 key，让“未自定义”的用户在存储上保持干净；
- 选用 JSON String 而不是 `Data`，方便设置页用 `@AppStorage(FloatingBarPlacementStore.storageKey) var raw: String = ""` 观察变化并显示“默认 / 自定义”；
- 不使用 `credentials.json`：这是 UI 偏好，与其它外观设置一样放在 `UserDefaults`。

### 4.3 变更通知

`save` / `reset` 之后发送 `Notification.Name.floatingBarPlacementDidChange`。`FloatingBarController` 订阅该通知；设置页通过 `@AppStorage` 自动刷新，无需订阅。

## 5. 几何

新文件 `Type4Me/UI/FloatingBar/FloatingBarPlacementGeometry.swift`，全部是 `static` 纯函数，不读取 `UserDefaults` 和 `NSScreen`。

### 5.1 基准高度

```swift
static func baseCapsuleHeight(for style: RecordingIndicatorStyle) -> CGFloat {
    style == .compact ? TF.compactIndicatorHeight : TF.barHeight
}
```

Compact 实时文本展开的 48pt 不是基准，`FloatingBarPanelLayout.fallback(for:showsLiveTranscript:)` 也不能直接复用（它包含展开高度）。

### 5.2 默认中心与位置解析

```swift
static func defaultCenter(visibleFrame v: NSRect, baseHeight h: CGFloat) -> CGPoint {
    CGPoint(x: v.midX, y: v.minY + TF.barBottomOffset + h / 2)
}

static func resolveCenter(
    _ p: FloatingBarPlacement, visibleFrame v: NSRect, baseHeight h: CGFloat
) -> CGPoint {
    let d = defaultCenter(visibleFrame: v, baseHeight: h)
    let x: CGFloat = switch p.horizontal {
        case .default: d.x
        case .fraction(let f): v.minX + v.width * CGFloat(f)
    }
    let y: CGFloat = switch p.vertical {
        case .default: d.y
        case .fromBottom(let dy): v.minY + CGFloat(dy)
        case .fromTop(let dy): v.maxY - CGFloat(dy)
    }
    return clampCenter(CGPoint(x: x, y: y), ...)   // see 5.5
}
```

### 5.3 锚定边

```swift
enum FloatingBarVerticalAnchor: Equatable { case bottom, top }

static func verticalAnchor(center: CGPoint, visibleFrame v: NSRect) -> FloatingBarVerticalAnchor {
    center.y > v.midY ? .top : .bottom
}
```

`.default` 垂直位置恒为 `.bottom`。

### 5.4 面板 frame

`FloatingBarPanelLayout` 新增一个字段：

```swift
/// Extra content on the anchor side of the capsule (drag handle + gap).
var anchorSideReserve: CGFloat = 0
```

`contentSize.height` 由视图计算时已包含这段预留（见 7.2），`panelSize` 公式不变。

```swift
static func panelFrame(
    layout: FloatingBarPanelLayout,
    center: CGPoint,
    baseHeight: CGFloat,
    anchor: FloatingBarVerticalAnchor,
    visibleFrame v: NSRect
) -> NSRect {
    let size = layout.panelSize
    let inset = TF.floatingPanelShadowInset
    let reserve = layout.anchorSideReserve
    var x = center.x - size.width / 2
    let y: CGFloat
    switch anchor {
    case .bottom:
        let capsuleBottom = center.y - baseHeight / 2
        y = capsuleBottom - reserve - inset
    case .top:
        let capsuleTop = center.y + baseHeight / 2
        y = capsuleTop + reserve + inset - size.height
    }
    x += horizontalShiftKeepingContentVisible(...)   // see 5.5
    return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
}
```

**回归不变量**：`placement == .default`、`reserve == 0` 时，`capsuleBottom = minY + barBottomOffset`，因此 `y = minY + barBottomOffset - inset`，`x = midX - width / 2`，与 `bottomCenteredFrame` 完全相同。保留 `bottomCenteredFrame` 作为默认分支的薄包装，现有 `AppStateTests` 断言继续有效。

### 5.5 限位

两层限位：

1. **中心限位** `clampCenter`：按**实际胶囊高度**和**当前生效的锚定边**计算胶囊矩形，保证它加上锚定侧手柄预留 `TF.barPlacementHandleReserve` 完整位于 `visibleFrame` 内。胶囊宽度用当前样式的最小宽度（Regular 为 `baseRecordingWidth`，Compact 为 `TF.compactIndicatorWidth`）。

   ```swift
   static func clampCenter(
       _ c: CGPoint,
       baseHeight: CGFloat,
       actualCapsuleHeight: CGFloat,     // layout.capsuleSize?.height ?? baseHeight
       anchor: FloatingBarVerticalAnchor,
       handleReserve: CGFloat,
       minCapsuleWidth: CGFloat,
       visibleFrame v: NSRect
   ) -> CGPoint
   ```

   胶囊矩形的垂直范围：`.bottom` 为 `[c.y - base/2, c.y - base/2 + actual]`，手柄预留在下方；`.top` 为 `[c.y + base/2 - actual, c.y + base/2]`，手柄预留在上方。

   以下时机都要重新限位：解析保存值、拖动中每次移动、拖动中 layout 变化（例如 Compact 展开为 48pt）、松手后重新判定锚定边、屏幕参数变化。限位只影响显示位置；只有松手时保存的是限位后的中心，也就是用户看到的位置。
2. **内容平移** `horizontalShiftKeepingContentVisible`：Regular 胶囊随实时文本变宽，或浮层比胶囊宽时，如果可见内容（`contentSize`，不含阴影内边距）越过左右边界，就整体水平平移回屏幕内。只平移面板，不改写位置中心。

非拖动状态下，锚定边由位置决定，展开和浮层总是朝屏幕中线方向生长，一般不会触发垂直限位。但拖动中锚定边是冻结的：例如 Compact 底边锚定、展开到 48pt 时被拖到屏幕顶部，展开部分会朝屏幕外生长。因此第 1 层必须按实际高度计算，不能只按基准高度计算。浮层在拖动中隐藏，不参与限位；松手后锚定边重新判定，浮层朝中线方向弹出。

### 5.6 反算保存值

```swift
static func placement(
    droppedCenter c: CGPoint,
    snapped: FloatingBarSnapAxes,
    visibleFrame v: NSRect
) -> FloatingBarPlacement {
    let h: FloatingBarPlacement.Horizontal = snapped.contains(.x)
        ? .default : .fraction(Double((c.x - v.minX) / v.width))
    let vert: FloatingBarPlacement.Vertical
    if snapped.contains(.y) { vert = .default }
    else if c.y > v.midY { vert = .fromTop(Double(v.maxY - c.y)) }
    else { vert = .fromBottom(Double(c.y - v.minY)) }
    return FloatingBarPlacement(horizontal: h, vertical: vert)
}
```

## 6. 吸附

新类型放在几何文件中：

```swift
struct FloatingBarSnapAxes: OptionSet { static let x, y }

struct FloatingBarSnapper {
    private(set) var snapped: FloatingBarSnapAxes = []

    /// Returns the adjusted center and the axes that became snapped on this update.
    mutating func update(raw: CGPoint, target: CGPoint) -> (CGPoint, newlySnapped: FloatingBarSnapAxes)
}
```

每个轴独立执行：

```text
distance = |raw.axis - target.axis|
if snapped.contains(axis):
    if distance > TF.barPlacementSnapExit (14): remove axis
else:
    if distance <= TF.barPlacementSnapEnter (8): insert axis, mark newly snapped
adjusted.axis = snapped.contains(axis) ? target.axis : raw.axis
```

- 拖动开始时，用起始中心初始化 `snapped`：从默认位置开始拖，两个轴初始即为已吸附，不触发触感。否则用户刚按下就会感到一次震动；
- `target` 为当前所在屏幕的 `defaultCenter`；跨屏时换屏，`snapped` 按新 target 重新计算，不触发触感；
- 控制器在 `newlySnapped` 非空时调用一次触感（两个轴同时进入也只调用一次）：

```swift
NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
```

没有 Force Touch 硬件时系统静默忽略，无需判断。

## 7. 视图层

### 7.1 FloatingBarChromeModel

```swift
@MainActor
final class FloatingBarChromeModel: ObservableObject {
    @Published var verticalAnchor: FloatingBarVerticalAnchor = .bottom
    @Published private(set) var isHandleVisible = false
    @Published var isDragging = false
    @Published var snappedAxes: FloatingBarSnapAxes = []
    /// True only while a drag outlives its session (see 8.4).
    @Published var isRetainedForDrag = false

    func setHovering(_ hovering: Bool)   // show immediately, hide after TF.barPlacementHandleHideDelay (0.3s)
}
```

- 由 `FloatingBarController` 创建并持有，作为 `FloatingBarView` 的可选参数传入；
- `isHandleVisible` 在拖动中强制为 `true`；
- 进入的 150ms 延迟复用 `HoverTrackingNSView` 现有逻辑，模型只负责离开宽限期。

`FloatingBarView` 新增：

```swift
let chrome: FloatingBarChromeModel?   // nil in Appearance Preview
```

用 `@ObservedObject` 包一层可选包装，或拆出 `FloatingBarChromeReader` 子视图，避免泛型视图持有可选 `@ObservedObject` 的限制。

### 7.2 布局

```swift
private var anchor: FloatingBarVerticalAnchor { chrome?.verticalAnchor ?? .bottom }
private var isRetainedForDrag: Bool { chrome?.isRetainedForDrag == true }
private var shouldRenderCapsule: Bool { state.barPhase != .hidden || isRetainedForDrag }
private var showsHandle: Bool { chrome?.isHandleVisible == true && shouldRenderCapsule }
/// Static 10pt reserve while the bar is active to eliminate window resize jitter on hover.
private var handleReserve: CGFloat { chrome != nil ? TF.barPlacementHandleReserve : 0 }

**会话在拖动中结束时保留展示（见 8.4）**：`AppState` 会先把 `barPhase` 设为 `.hidden`，清空 `segments`，然后才调用 `onHidePanel`。如果视图只看 `barPhase`，胶囊和手柄会立刻被移除，手柄 NSView 离开视图层级，后续的 `mouseDragged` / `mouseUp` 全部丢失。因此：

- `isRetainedForDrag == true` 且 `barPhase == .hidden` 时，`barContent` 渲染一个**空壳胶囊**：当前样式的基准尺寸，只有背景与边框，没有内容。不尝试冻结上一阶段的内容，因为 `segments`、计时器等数据已经被清空；
- `panelLayout` 在这种状态下按空壳胶囊尺寸计算，不返回 `.hidden`；
- 手柄放在 `if shouldRenderCapsule` 之外的稳定位置，并加固定 `.id`，确保阶段切换时 SwiftUI 不会重建手柄的 NSView。重建会让 AppKit 丢失正在进行的鼠标跟踪。

`body` 调整为按锚定边排列：

```text
.bottom:  [overlay] gap [capsule] handleGap [handle]     alignment .bottom
.top:     [handle] handleGap [capsule] gap [overlay]     alignment .top
```

`panelLayout` 的高度常态计入 `handleReserve`（10pt），并写入 `anchorSideReserve`。

**消除 Hover 跳动（核心工程经验）**：如果 `handleReserve` 在悬停时才动态增加，SwiftUI 的内部排版先于 AppKit 原生窗口异步 Resize，会导致胶囊在首帧被向上挤压 10pt、次帧窗口变大后又拉回原位，视觉上产生剧烈上下跳动。改为**常态预留架构**：只要浮条展示（`chrome != nil`），手柄所需的 10pt 在几何中始终预留（未悬停时为透明底），悬停与移开仅执行纯视觉 `opacity(0 ↔ 1)` 渐变，**窗口尺寸与 Origin 的变动量完全为 0**，胶囊在屏幕上绝对静止。
### 7.3 浮层

- `activeTopOverlay` 在 `chrome?.isDragging == true` 时返回 `nil`；
- 重命名为 `activeOuterOverlay` 等方向中性名称（可选，非必须）；
- `TranscriptPopup` 的 `scrollTo(anchor: .bottom)` 行为不变，只改变它相对胶囊的位置。

### 7.4 悬停追踪

在胶囊与手柄的公共容器 `.background` 上挂一个 `FloatingBarHoverTracker`，回调 `chrome?.setHovering(_:)`。`HoverTrackingNSView` 的 `hitTest` 返回 `nil`，不会影响按钮和手柄的点击。手柄出现导致面板 resize 时，现有的 `containsMouse` 防护会吞掉合成的 exit。

### 7.5 手柄

新文件 `Type4Me/UI/FloatingBar/FloatingBarDragHandle.swift`：

```swift
struct FloatingBarDragHandle: NSViewRepresentable {
    let onDragBegan: (CGPoint) -> Void      // screen point
    let onDragMoved: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onHoverChanged: ((Bool) -> Void)?
}

final class FloatingBarDragHandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent)     // record NSEvent.mouseLocation
    override func mouseDragged(with event: NSEvent)  // threshold 3pt, then onDragBegan then onDragMoved
    override func mouseUp(with event: NSEvent)       // ended only if began
}
```

- **视觉与材质**：`FloatingBarDragHandleControl` 采用一体式液态玻璃 Tab，复用与胶囊相同的 `VisualEffectBlur`、深浅对比底板与 `recordingGlassRim` 高光，内部带 2×3 Grip Dots；
- **事件透传**：视觉层设置 `.allowsHitTesting(false)`，确保鼠标事件 100% 直通底层的 `FloatingBarDragHandleView`；
- **光标调度**：使用系统标准原生光标，避免非激活浮窗（non-activating panel）光标栈冲突；
- **无障碍与提示**：`setAccessibilityRole(.handle)`，悬停 150ms 触发与完成/取消按钮同款磨砂毛玻璃 Tooltip（`hintBubble`），展示在胶囊对侧。
## 8. 控制器

### 8.1 位置状态

`FloatingBarController` 新增：

```swift
let chrome = FloatingBarChromeModel()
private var placement = FloatingBarPlacementStore.load()
private var drag: DragSession?
private var pendingHideAfterDrag = false
private var guideWindow: FloatingBarPlacementGuideWindow?

private struct DragSession {
    var grabOffset: CGVector        // mouse - base center at drag start
    var anchor: FloatingBarVerticalAnchor  // frozen for the session
    var snapper: FloatingBarSnapper
    var center: CGPoint
    var displayID: CGDirectDisplayID?
}
```

### 8.2 frame 计算

`applyPanelSize(_:display:)` 改为 `applyPanelFrame(layout:display:)`：

```text
screen  = drag.map { screen(for: $0.displayID) } ?? resolvedAnchorScreen()
base    = baseCapsuleHeight(current style)
anchor  = drag?.anchor ?? verticalAnchor(resolvedCenter, visibleFrame)
center  = clampCenter(drag?.center ?? resolveCenter(placement, visibleFrame, base),
                      actualCapsuleHeight: layout.capsuleSize?.height ?? base, anchor, ...)
chrome.verticalAnchor = anchor
frame   = panelFrame(layout, center, base, anchor, visibleFrame)
panel.setFrame(frame, display:)
```

**拖动中所有 frame 计算都以 `drag.displayID` 为准**，包括 `updatePanelLayout`、延迟收缩任务、手柄显隐引起的 resize。`anchorDisplayID` 到松手才更新；如果拖动中仍使用 `resolvedAnchorScreen()`，拖到另一块屏幕后，任何一次 resize 都会按旧屏幕的 `visibleFrame` 做限位和水平平移，把指示器拉回旧屏幕。`drag.displayID` 对应的屏幕在拖动中消失时，按 8.5 结束拖动。

控制器内部统一通过一个 `currentPlacementScreen()` 取屏幕，禁止在其它位置直接调用 `resolvedAnchorScreen()`。

`resizePanel` 现在只比较 size，改为比较完整 frame，因为锚定边切换时 size 不变但 origin 会变。延迟收缩逻辑（`capsuleShrinkDelay`）保持不变，只是最终调用 `applyPanelFrame`。

### 8.3 拖动流程

```text
handle began(p):
    cancelPendingPanelShrink() & applyPanelFrame(currentLayout, false)
    visualCenter = currentCenter + horizontalShiftKeepingContentVisible(...)
    drag = DragSession(grabOffset: p - visualCenter, anchor: chrome.verticalAnchor,
                       snapper: seeded with visualCenter vs defaultCenter, ...)
    dragLifecycle.dragBegan()
    chrome.isDragging = true
    show guide window on current screen

handle moved(p):
    raw     = p - grabOffset
    screen  = screen containing raw (fallback: nearest)
    target  = defaultCenter(screen.visibleFrame, base)
    (c, new) = snapper.update(raw, target)
    minW    = max(style.minWidth, actualContentWidth)  // eliminate edge dead-zone
    c       = clampCenter(c, actualCapsuleHeight: base, anchor: drag.anchor,
                          handleReserve: reserve, minCapsuleWidth: minW, visibleFrame: screen.visibleFrame)
    drag.center = c; drag.displayID = screen
    panel.setFrameOrigin(panelFrame(currentLayout, c, ...).origin)   // origin only
    guide.update(screen, target, snapper.snapped)
    if !new.isEmpty: haptic
    chrome.snappedAxes = snapper.snapped

commitCurrentDrag(at: p?):
    if p != nil: apply moved(p)
    // If p == nil (forced end on screen changes or manual input): directly submit drag.center without re-applying grabOffset!
    placement = placement(droppedCenter, snapper.snapped, visibleFrame)
    FloatingBarPlacementStore.save(placement)
    anchorDisplayID = drag.displayID
    drag = nil; chrome.isDragging = false
    guide fade out & release
    action = dragLifecycle.dragEnded()
    chrome.isRetainedForDrag = dragLifecycle.isRetainedForDrag
    applyPanelFrame(currentLayout, display: true)
    if action == .releaseRetainedAndHide:
        hide()

拖动中跨过中线不切换锚定边；松手后如果锚定边改变，手柄和浮层换到另一侧，胶囊位置不变。如果新的锚定边下胶囊越界，重新限位后胶囊可能会小幅内移。

### 8.4 拖动与会话生命周期

`AppState` 结束会话的顺序是：先设 `barPhase = .hidden`（并清空 `segments`），再调用 `onHidePanel`。在这之前，`barPhase` 的变化已经触发视图重新计算 `panelLayout` 和 `updatePanelLayout`；如果不做处理，`updatePanelLayout` 会把 `ignoresMouseEvents` 设为 `true`。所以只推迟 `hide()` 是不够的，需要同时保住展示和事件接收：

| 事件 | 拖动中的处理 |
|---|---|
| `barPhase` 变为 `.hidden` | 视图按 7.2 渲染空壳胶囊与手柄（由 `chrome.isRetainedForDrag` 驱动） |
| `updatePanelLayout` | `drag != nil` 时不修改 `ignoresMouseEvents`（保持 `false`），也不走 Hidden 阶段的“保持原尺寸直到淡出”分支；按 8.2 以 `drag.displayID` 和 `drag.center` 正常 resize |
| `hide()` | 设置 `pendingHideAfterDrag = true`、`chrome.isRetainedForDrag = true` 后返回，不淡出、不 `orderOut`；松手后执行真正的 `hide()` |
| `show()`（拖动中开始新会话） | 清除 `pendingHideAfterDrag`，置 `chrome.isRetainedForDrag = false`，新阶段内容替换空壳；不重新选屏，不覆盖 `drag.center`；照常递增 `panelGeneration`，使旧会话可能残留的 hide 完成回调失效 |
| `setManualInputEditing(true)` | 结束拖动：按当前位置保存，关闭参考窗口，清除 `pendingHideAfterDrag` / `isRetainedForDrag`，然后执行原逻辑 |

`isRetainedForDrag` 只在“拖动中且会话已结束”时为 `true`，不影响非拖动状态下现有的显示与隐藏时序。

### 8.5 外部变更

- `.floatingBarPlacementDidChange`：重新 `load()`；面板可见且不在拖动中时，移动到新 frame；“减少动态效果”关闭时用 `NSAnimationContext` 动画 0.25s；
- `NSApplication.didChangeScreenParametersNotification`：面板可见时重新 `applyPanelFrame`；锚定屏幕消失时沿用 `resolvedAnchorScreen()` 现有回退逻辑；拖动中直接结束拖动并保存。

## 9. 参考线窗口

新文件 `Type4Me/UI/FloatingBar/FloatingBarPlacementGuideWindow.swift`：

```swift
final class FloatingBarPlacementGuideWindow: NSPanel {
    // borderless + nonactivatingPanel, clear background, ignoresMouseEvents = true
    // level = .floating, ordered below the bar panel: order(.below, relativeTo: barPanel.windowNumber)
    // collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // frame = screen.visibleFrame
    func update(visibleFrame: NSRect, defaultCenter: CGPoint, snapped: FloatingBarSnapAxes)
}
```

- 内容为 SwiftUI `Canvas`：两条 `Path`，采用**双层高对比度渲染（Dual-contrast Stroke）**：
  - **未吸附**：底层 2.2pt 暗色底影（`black.opacity(0.35)`）+ 顶层 1.0pt 白色虚线（`[6, 4]`），在纯白、纯黑及任意桌面背景下均清晰可见；
  - **吸附后**：底层 3.0pt 阴影 + 顶层 1.5pt 实心 **Type4Me 暖琥珀色（`TF.amber`）**，吸附时橙金高光聚焦；
- 换屏时直接 `setFrame` 到新屏幕的 `visibleFrame`；
- 淡入 0.12s、淡出 0.2s；“减少动态效果”时不做动画。
## 10. 关联面板

### 10.1 手动输入窗

`ManualInputPanel` 不再调用 `bottomCenteredFrame`，改为：

```text
center = resolveCenter(placement, visibleFrame, baseHeight: current style)
anchor = verticalAnchor(center, visibleFrame)
frame  = panelFrame-like computation with ManualInputLayout.shadowInset
```

几何层提供 `anchoredFrame(size:center:baseHeight:anchor:shadowInset:visibleFrame:)` 的泛化版本，`panelFrame` 基于它实现。编辑器最大高度改为“锚定边到对侧可见边的距离 − 现有 overhead”，替代硬编码的 `TF.barBottomOffset`。顶边锚定时编辑器向下增高。

### 10.2 纠错学习卡片

`positionAboveFloatingBar()` 改名为 `positionBesideFloatingBar(capsuleRect:anchor:)`：

- `.bottom`：`y = capsuleRect.maxY + TF.correctionPanelGap`；
- `.top`：`y = capsuleRect.minY - TF.correctionPanelGap - frame.height`；
- `x = capsuleRect.midX - frame.width / 2`，再限位到 `visibleFrame`。

`capsuleRect` 由 `FloatingBarPlacementGeometry.baseCapsuleRect(...)` 计算，不依赖指示器面板当前是否可见。`18` 提取为 `TF.correctionPanelGap`。

## 11. 设置页

`AppearanceSettingsTab` 的“录音显示”分组末尾新增 `indicatorPositionRow`：

```swift
@AppStorage(FloatingBarPlacementStore.storageKey) private var placementRaw = ""

private var isPlacementDefault: Bool { FloatingBarPlacementStore.decode(placementRaw).isDefault }
```

- 标题、说明、状态（默认 / 自定义）、按钮（恢复默认）全部用 `L(_:_:)`；
- 按钮 `.disabled(isPlacementDefault)`，点击调用 `FloatingBarPlacementStore.reset()`；
- 对 Regular、Compact 都显示，不放进 `if !isCompact`；
- 外观预览 `AppearancePreviewStage` 不传 `chrome`，保持现状。

## 12. Design Token

`Type4Me/UI/DesignSystem.swift` 新增：

```swift
static let barPlacementHandleWidth: CGFloat = 24
static let barPlacementHandleThickness: CGFloat = 10
static let barPlacementHandleHitHeight: CGFloat = 10
static let barPlacementHandleGap: CGFloat = 0
static var barPlacementHandleReserve: CGFloat { barPlacementHandleGap + barPlacementHandleHitHeight }
static let barPlacementHandleHideDelay: Duration = .milliseconds(300)
static let barPlacementDragThreshold: CGFloat = 3
static let barPlacementSnapEnter: CGFloat = 8
static let barPlacementSnapExit: CGFloat = 14
static let barPlacementGuideDash: [CGFloat] = [6, 4]
static let correctionPanelGap: CGFloat = 18
// colors: barPlacementHandle(Light), barPlacementGuide(Light), barPlacementGuideActive(Light)
```

## 13. 本地化

| Key 场景 | 中文 | English |
|---|---|---|
| 设置标题 | 指示器位置 | Indicator Position |
| 设置说明 | 将鼠标悬停在录音指示器上，拖动旁边的手柄即可移动。 | Hover over the recording indicator and drag its handle to move it. |
| 状态 | 默认 / 自定义 | Default / Custom |
| 按钮 | 恢复默认 | Reset to Default |
| 手柄 Tooltip | 拖动以移动指示器 | Drag to move the indicator |
| 手柄 AX 标签 | 移动录音指示器 | Move recording indicator |
| 手柄 AX 提示 | 拖动以改变位置，可在外观设置中恢复默认位置 | Drag to change its position. You can reset it in Appearance settings. |

`FloatingBarView` 已经通过 `@AppStorage("tf_language")` 观察语言；手柄 NSView 的无障碍文案在 `updateNSView` 中刷新，满足“切换语言即时更新常驻浮窗”的要求。

## 14. 文件规划

| 文件 | 变更 |
|---|---|
| `Type4Me/UI/FloatingBar/FloatingBarPlacement.swift` | 新增：模型、Store、通知名 |
| `Type4Me/UI/FloatingBar/FloatingBarPlacementGeometry.swift` | 新增：几何纯函数、`FloatingBarSnapAxes`、`FloatingBarSnapper`、`FloatingBarVerticalAnchor` |
| `Type4Me/UI/FloatingBar/FloatingBarChromeModel.swift` | 新增：共享 UI 状态 |
| `Type4Me/UI/FloatingBar/FloatingBarDragHandle.swift` | 新增：手柄视图与事件 NSView |
| `Type4Me/UI/FloatingBar/FloatingBarPlacementGuideWindow.swift` | 新增：参考线窗口 |
| `Type4Me/UI/FloatingBar/FloatingBarPanel.swift` | `FloatingBarPanelLayout.anchorSideReserve`；控制器位置、拖动、通知、屏幕变化 |
| `Type4Me/UI/FloatingBar/FloatingBarView.swift` | `chrome` 参数、按锚定边排列、手柄、悬停、拖动中隐藏浮层、`.handle` tooltip |
| `Type4Me/UI/FloatingBar/ManualInputPanel.swift` | 使用位置几何 |
| `Type4Me/UI/FloatingBar/CorrectionLearningPanel.swift` | 按锚定边定位 |
| `Type4Me/UI/Settings/AppearanceSettingsTab.swift` | 指示器位置设置行 |
| `Type4Me/UI/DesignSystem.swift` | token |
| `Type4MeTests/FloatingBarPlacementTests.swift` | 新增：见第 15 节 |
| `docs/README.md` | 文档索引 |

## 15. 单元测试

`Type4MeTests/FloatingBarPlacementTests.swift`：

**默认回归**

- 多组 `visibleFrame`（含非零 origin 的副屏）× Regular / Compact × 多组 layout（含 `horizontalOverflow`、浮层高度）：`.default` + `reserve == 0` 的 `panelFrame` 与 `bottomCenteredFrame` 完全相等。

**解析**

- `fraction(0.3)` 在 1440 宽与 2560 宽屏幕上分别得到 30% 位置；
- `fromBottom(150)` 在不同高度屏幕上中心距底边都是 150；
- `fromTop` 同理；
- 超出范围的值（`fraction(1.4)`、负距离）经过 `clampCenter` 后完整可见。

**锚定与生长**

- 中心在中线以上判定为 `.top`；
- `.top` 时增加 layout 高度（模拟 Compact 48pt 展开、浮层），胶囊顶边 y 不变；
- `.bottom` 时胶囊底边 y 不变；
- 手柄预留增加时胶囊在屏幕上的 rect 不变（两种锚定各一组）。

**限位**

- 四个角、贴菜单栏、贴 Dock：基准胶囊加手柄预留在 `visibleFrame` 内；
- 宽胶囊靠右边缘：可见内容被平移回屏幕内，位置中心不变。

**拖动边界（Codex 评审补充）**

- `.bottom` 锚定、Compact 实际高度 48、基准 24，把中心拖到 `visibleFrame.maxY`：限位后胶囊顶边 ≤ `maxY`；
- `.top` 锚定的对称情况：胶囊底边加手柄预留 ≥ `minY`；
- 拖动中 layout 从 24 变为 48：重新计算后的 frame 仍在屏幕内；
- 松手后锚定边翻转：重新限位后胶囊在屏幕内；
- 拖动中 `drag.displayID` 指向副屏、`anchorDisplayID` 仍是主屏，触发一次 resize：frame 落在副屏 `visibleFrame` 内（几何层用注入的屏幕表测试 `currentPlacementScreen()` 的选择逻辑）。

**拖动与会话生命周期**

把 hide / show / retain 决策抽成纯状态机 `FloatingBarDragLifecycle`，单独测试：

- 拖动中 `hide()` → 不隐藏，`isRetainedForDrag == true`；松手 → 隐藏，retain 清除；
- 拖动中 `hide()` 后又 `show()` → 松手后不隐藏；
- 拖动中 `setManualInputEditing(true)` → 拖动结束，pending 清除；
- 非拖动时 `hide()` → 行为与现状一致。

**吸附**

- 距离 8 进入、10 保持、14 保持、14.1 脱离、脱离后 10 不重新进入、8 重新进入；
- 两轴同一次 `update` 同时进入，`newlySnapped == [.x, .y]`（控制器据此只触发一次）；
- 从默认中心开始拖动时初始 `snapped == [.x, .y]`，首次移动不产生 `newlySnapped`。

**反算与持久化**

- 吸附轴反算为 `.default`；上半屏反算为 `.fromTop`；
- `resolveCenter(placement(c))` 往返误差 < 0.5pt；
- JSON 往返；空字符串、乱码、`version: 99` 解码为 `.default`；
- `save(.default)` 删除 key。

**关联面板**

- 纠错学习卡片：`.bottom` 时在胶囊上方，`.top` 时在下方，都在 `visibleFrame` 内；
- 手动输入窗：默认位置下 frame 与改造前一致。

**本地化**

- 中英文切换后，设置行的标题、状态、按钮文案与手柄 AX 标签随 `tf_language` 变化。

几何测试使用固定 `NSRect`，不依赖真实屏幕，可在 CI 中运行。

## 16. 手动验收

按 [产品设计第 14 节](product-design.md#14-验收场景) 执行。按项目约定，UI 体验验收交给用户，开发侧只完成编译、签名、安装完整性检查。需要额外关注的设备组合：

- 内建 Retina 屏 + 不同缩放比例的外接屏，并且外接屏在主屏左侧（origin.x 为负）；
- Dock 在左侧、右侧、自动隐藏；
- 全屏应用、Stage Manager；
- 外接鼠标（无触感）与 Force Touch 触控板。

## 17. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 默认位置偏移 1px，引起老用户感知 | 第 15 节默认回归测试逐像素比对 `bottomCenteredFrame` |
| 手柄出现时面板 resize 合成 mouseExited，手柄闪烁 | 复用 `containsMouse` 防护，加 300ms 离开宽限期 |
| 非 key 面板中光标不生效 | 使用 `.cursorUpdate` + `.activeAlways` 跟踪区；失败时只缺少光标反馈，不影响拖动 |
| 窗口移动导致 `locationInWindow` 抖动 | 全程使用 `NSEvent.mouseLocation` |
| 拖动中会话结束，`barPhase = .hidden` 先于 `hide()` 移除胶囊与手柄、禁用鼠标事件，`mouseUp` 丢失 | `isRetainedForDrag` 渲染空壳胶囊；拖动中不修改 `ignoresMouseEvents`；推迟 `hide()`；新会话 `show()` 清除待隐藏请求（8.4） |
| 阶段切换导致 SwiftUI 重建手柄 NSView，拖动中断 | 手柄位于条件分支之外，并使用固定 `.id` |
| 冻结锚定边后展开内容越出屏幕 | 按实际胶囊高度与生效锚定边限位，拖动中与松手后都重新限位（5.5） |
| 跨屏拖动时 resize 仍按旧屏幕计算，指示器被拉回 | 拖动中统一使用 `drag.displayID`（8.2） |
| 跨中线时手柄跳到另一侧 | 拖动期间冻结锚定边 |
| 拖动频率高导致卡顿 | 拖动中只 `setFrameOrigin`，不触发 SwiftUI 布局；参考线只在吸附状态或换屏时重绘 |
| 屏幕拔出后位置不可见 | 屏幕参数变化时重新计算并限位 |
| 手动输入窗顶边锚定后编辑器高度计算错误 | 最大高度按锚定边到对侧边的距离计算，单测覆盖 |

## 18. 实现顺序

1. `FloatingBarPlacement` + Store + 几何 + Snapper，以及对应的单元测试（默认回归先行）；
2. `FloatingBarPanelLayout.anchorSideReserve`，控制器改用 `applyPanelFrame`，此时行为应与现状完全一致；
3. `FloatingBarChromeModel`，视图按锚定边排列，`.top` 时浮层翻转（可临时写入保存值来验证）；
4. 手柄视图、悬停显示、拖动流程、拖动中推迟 hide；
5. 吸附、触感、参考线窗口；
6. 手动输入窗、纠错学习卡片；
7. 设置页“恢复默认”，以及本地化与无障碍；
8. 屏幕参数变化、外部变更通知；
9. 更新 `docs/README.md`，把文档状态改为已实现并填写实现基线。

## 19. 技术决策汇总

| 决策 | 结论 | 理由 |
|---|---|---|
| 记录点 | 基准胶囊中心 | 与样式展开、浮层解耦；参考线交叉点语义清晰 |
| 水平坐标 | `visibleFrame` 宽度比例 | 在宽窄不同的屏幕上保持视觉关系 |
| 垂直坐标 | 距较近边的点数 | “离底部多远不挡输入框”以点数计，换高屏不应漂移 |
| 吸附存储 | 吸附轴存 `.default` | 跟随未来默认值与样式变化 |
| 锚定边 | 中线以上顶边锚定，否则底边锚定 | 生长总朝屏幕中央，无需垂直二次限位 |
| 拖动实现 | 自管 `mouseDragged` + `setFrameOrigin` | `performDrag` 无法插入吸附与限位 |
| 拖动中锚定边 | 冻结 | 避免手柄在指针下跳动 |
| 存储 | `UserDefaults` JSON String | 与其它外观偏好一致，可被 `@AppStorage` 观察 |
| 预览 | 不注入 chrome | 预览只展示外观，避免与设置页交互冲突 |
| 手柄形态 | 一体式毛玻璃拉手 + 6 点点阵 | 物理抓握隐喻直观，深浅毛玻璃材质与胶囊一体 |
| 布局跳动防护 | 常态预留 10pt，纯 opacity 渐变 | 消除动态 Resize 导致的 1 帧布局时序上下抖动 |
| 参考线对比度 | 双层暗影 + 白虚线 / 琥珀实线 | 解决纯白网页背景下白虚线不可见的问题 |
| 光标策略 | 系统标准指针 | 避免非激活浮窗自定义光标栈冲突 |
