import CoreGraphics
import Testing

@testable import MakuripCore

@Suite("パネルを出す位置")
struct PanelPlacementTests {
    /// 主画面（メニューバーと Dock を除く）と、右に並べた 2 枚目
    let main = CGRect(x: 0, y: 80, width: 1440, height: 795)
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    let size = CGSize(width: 372, height: 528)

    @Test("文字カーソルの下に、左端をカーソルより 18pt 左にそろえて出す（試作の place と同じ）")
    func belowCaret() {
        let caret = CGRect(x: 300, y: 700, width: 2, height: 18)
        let frame = PanelPlacement.frame(size: size, anchor: .caret(caret), screens: [main, second])
        #expect(frame.minX == 282)
        #expect(frame.maxY == 692)  // カーソルの下端から 8pt 下
        #expect(frame.size == size)
    }

    @Test("下に入りきらなければカーソルの上に出す")
    func aboveWhenNoRoom() {
        let caret = CGRect(x: 300, y: 300, width: 2, height: 18)
        let frame = PanelPlacement.frame(size: size, anchor: .caret(caret), screens: [main])
        #expect(frame.minY == 326)  // カーソルの上端 + 8
    }

    @Test("画面の端からはみ出さない（右端・上端）")
    func clampToScreen() {
        let caret = CGRect(x: 1430, y: 860, width: 2, height: 14)
        let frame = PanelPlacement.frame(size: size, anchor: .caret(caret), screens: [main])
        #expect(frame.maxX == main.maxX - 12)
        #expect(frame.maxY <= main.maxY)
        #expect(frame.minY >= main.minY + 12)
    }

    @Test("カーソルのある画面に出す（2 枚目の画面）")
    func secondScreen() {
        let caret = CGRect(x: 2000, y: 900, width: 2, height: 18)
        let frame = PanelPlacement.frame(size: size, anchor: .caret(caret), screens: [main, second])
        #expect(second.contains(frame))
    }

    @Test("代わりの決め方: 入力欄の枠 → マウスの位置 → 画面の下寄りの中央")
    func fallbacks() {
        // 入力欄の枠の左下を基準にする（大きい入力欄でも上端まで飛ばない）
        let field = CGRect(x: 200, y: 250, width: 800, height: 400)
        let byField = PanelPlacement.frame(size: size, anchor: .field(field), screens: [main])
        #expect(byField.minX == 182)
        #expect(byField.minY == 258)  // 枠の下に入らないので、枠の下端のすぐ上（枠の上端までは飛ばない）
        // マウスの位置
        let byMouse = PanelPlacement.frame(size: size, anchor: .mouse(CGPoint(x: 500, y: 800)), screens: [main])
        #expect(byMouse.minX == 482)
        #expect(byMouse.maxY == 792)
        // 手がかりなし: マウスのある画面の下寄りの中央
        let none = PanelPlacement.frame(
            size: size, anchor: .none, screens: [main, second], mouse: CGPoint(x: 2000, y: 10))
        #expect(none.midX == second.midX)
        #expect(none.minY == second.minY + (second.height - size.height) * 0.25)
    }

    @Test("候補窓（#8）用: カーソルの右に出し、指定の行をカーソルの行の高さにそろえる")
    func beside() {
        let caret = CGRect(x: 300, y: 500, width: 2, height: 20)
        let frame = PanelPlacement.frame(
            size: CGSize(width: 372, height: 200), anchor: .caret(caret), screens: [main], side: .beside(rowOffset: 50))
        #expect(frame.minX == 310)
        #expect(frame.maxY - 50 == caret.midY)
        // 右に入らなければ左へ
        let right = CGRect(x: 1300, y: 500, width: 2, height: 20)
        let flipped = PanelPlacement.frame(
            size: CGSize(width: 372, height: 200), anchor: .caret(right), screens: [main], side: .beside(rowOffset: 50))
        #expect(flipped.maxX == 1292)
    }

    @Test("⌘Y のプレビューはパネルの右、入らなければ左。上端と高さはそろえる")
    func peek() {
        let panel = CGRect(x: 100, y: 200, width: 372, height: 528)
        let right = PanelPlacement.peekFrame(panel: panel, width: 470, screens: [main])
        #expect(right.minX == 482)
        #expect(right.minY == panel.minY)
        #expect(right.height == panel.height)
        let farRight = CGRect(x: 1000, y: 200, width: 372, height: 528)
        let left = PanelPlacement.peekFrame(panel: farRight, width: 470, screens: [main])
        #expect(left.maxX == 990)
    }

    @Test("AX の座標（左上原点）を AppKit の座標（左下原点）へ")
    func flip() {
        let ax = CGRect(x: 100, y: 50, width: 2, height: 20)
        let appKit = PanelPlacement.appKitRect(fromAX: ax, primaryScreenHeight: 900)
        #expect(appKit == CGRect(x: 100, y: 830, width: 2, height: 20))
    }

    @Test("使えない AX の値を捨てる")
    func usable() {
        #expect(!InsertionPointLocator.isUsable(.zero))
        #expect(!InsertionPointLocator.isUsable(CGRect(x: 0, y: 0, width: 0, height: 18)))
        #expect(!InsertionPointLocator.isUsable(CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)))
        #expect(InsertionPointLocator.isUsable(CGRect(x: 10, y: 10, width: 0, height: 18)))
    }
}
