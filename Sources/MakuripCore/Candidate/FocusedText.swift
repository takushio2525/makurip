import ApplicationServices
import Foundation

/// 前面のアプリの、焦点のある入力欄を AX で読み書きする（候補窓の差し替えと、変換中の判定に使う）。
///
/// 読むのは選択範囲・文字数・未確定の文字の範囲だけで、**入力欄の文字そのものは読まない**。
/// 問い合わせの待ちは短く切る（応答しないアプリで止まらないように。横取りのタップの中からも呼ぶため）
public enum FocusedText {
    static let timeout: Float = 0.1
    /// NSTextView などの未確定の文字の範囲（`NSAccessibilityTextInputMarkedRangeAttribute`）
    static let markedRangeAttribute = "AXTextInputMarkedRange"
    /// WebKit の未確定の文字の範囲（`kAXTextInputMarkedTextMarkerRangeAttribute`）
    static let webMarkedRangeAttribute = "AXTextInputMarkedTextMarkerRange"

    /// 選択範囲と文字数。選択範囲を読めなければ nil（入力欄でない・AX を出さないアプリ）
    public static func probe(pid: pid_t) -> TextProbe? {
        guard AXIsProcessTrusted(), let element = focusedElement(pid: pid),
            let selection = range(element, kAXSelectedTextRangeAttribute)
        else { return nil }
        var count: CFTypeRef?
        var characterCount: Int?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success {
            characterCount = (count as? NSNumber)?.intValue
        }
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &settable)
        return TextProbe(
            selection: selection, characterCount: characterCount,
            selectionSettable: settableResult == .success && settable.boolValue)
    }

    /// 選択範囲を書き換える。書けなければ false（書けたかは呼ぶ側が読み直して確かめる）
    public static func select(_ range: AXTextRange, pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), let element = focusedElement(pid: pid) else { return false }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// 未確定の文字の長さ。入力欄がこの属性を持たなければ nil（判定できない）、持っていて値がなければ 0
    public static func markedTextLength(pid: pid_t) -> Int? {
        guard AXIsProcessTrusted(), let element = focusedElement(pid: pid) else { return nil }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
            let attributes = names as? [String]
        else { return nil }
        if attributes.contains(markedRangeAttribute) {
            guard let marked = range(element, markedRangeAttribute) else { return 0 }
            return marked.location == kCFNotFound ? 0 : max(0, marked.length)
        }
        if attributes.contains(webMarkedRangeAttribute) {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, webMarkedRangeAttribute as CFString, &value)
            return result == .success && value != nil ? 1 : 0
        }
        return nil
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let element = InsertionPointLocator.element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> AXTextRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &cfRange) else { return nil }
        return AXTextRange(location: cfRange.location, length: cfRange.length)
    }
}
