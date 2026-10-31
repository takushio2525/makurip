import ApplicationServices
import CoreGraphics

/// 前面のアプリの文字カーソル（取れなければ入力欄の枠）を Accessibility API で取る。
///
/// 順に試す: 焦点の要素の `AXSelectedTextRange` → `AXBoundsForRange`（文字カーソル）→ `AXPosition` + `AXSize`（入力欄の枠）。
/// 返す座標は AX のまま（主画面の左上が原点）。AppKit の座標へは `PanelPlacement.appKitRect(fromAX:primaryScreenHeight:)`。
/// アクセシビリティの許可がないとき・取れないアプリ（ターミナル・Electron 製の多く）では nil。
/// 呼ぶ側はそのとき `PanelAnchor.mouse` → `.none` の順で代わりにする（`PanelPlacement` の説明）。
public enum InsertionPointLocator {
    public enum Result: Equatable, Sendable {
        case caret(CGRect)
        case field(CGRect)
    }

    /// `pid` は前面のアプリ（パネルを出す前に控えたもの）。応答の遅いアプリで止まらないよう、問い合わせの待ちを短くする
    public static func locate(pid: pid_t, timeout: Float = 0.15) -> Result? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, timeout)
        if let caret = caretBounds(of: focused) { return .caret(caret) }
        if let frame = frame(of: focused) { return .field(frame) }
        return nil
    }

    static func caretBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var boundsValue: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return isUsable(rect) ? rect : nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        let rect = CGRect(origin: origin, size: size)
        return isUsable(rect) ? rect : nil
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// 取れたが使えない値（0 の大きさで原点にいる・無限大など。返してくるアプリがある）を捨てる
    static func isUsable(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
            return false
        }
        if rect.origin == .zero, rect.width == 0 || rect.height == 0 { return false }
        return rect.height > 0 || rect.width > 0
    }
}
