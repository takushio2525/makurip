import AppKit
import Foundation
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// カードの上でスクロールしたとき、カードに重ねた透明な NSView（`CardMouseView`）がスクロールを横取りせず、一覧へ流すこと（#38）。
///
/// AppKit はホイールの出来事を、位置で当たるビュー（hitTest）の `scrollWheel` に渡し、受けないビューは次の応答者へ回す。
/// そこで「カードの上で当たるのは重ねた NSView」「その応答者の連なりが一覧のスクロールに届く」「重ねた NSView に渡すと外側のスクロールが動く」を確かめる。
/// 窓は画面の外（-10000）の枠なしの窓で、画面ロック中でも動く（どの画面にも映らない）。
///
/// SwiftUI の一覧のスクロール（`HostingScrollView`）は、画面の外の窓では合成したホイールに直接渡しても動かない（2026-11-04 に確かめた）。
/// そのため本物のパネルでは位置の変化を見ず、動くことは素の NSScrollView で確かめる。本物のパネルが動くことは `make e2e-click` で見る
@MainActor
@Suite("カードの上のスクロール", .serialized)
struct CardScrollTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test("本物のパネル: カードの上で当たるのは重ねた NSView で、その先は一覧のスクロールに届き、ホイールでは貼らない")
    func panelRoutesScrollToList() throws {
        _ = NSApplication.shared
        let history = SampleHistory.make()
        let model = HistoryPanelModel(actions: history)
        model.clock = { SampleHistory.now }
        var pasted = 0
        model.effects = HistoryPanelModel.Effects(paste: { _, _ in pasted += 1 })
        model.open()

        let host = NSHostingView(rootView: HistoryPanelView(model: model, loader: ClipContentLoader(actions: history)))
        host.frame = CGRect(origin: .zero, size: HistoryPanelView.size)
        let window = Self.offscreenWindow(size: HistoryPanelView.size, content: host)
        defer { Self.close(window) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let card = try #require(
            Self.cardViews(in: host).first { $0.rowID == model.items.first?.id }, "1 枚目のカードに重ねた NSView がある")
        let scroll = try #require(card.enclosingScrollView, "カードは一覧のスクロールの中にある")
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height, "一覧は窓より長い（スクロールできる）")

        let center = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        let hit = host.hitTest(host.superview?.convert(center, from: nil) ?? center)
        #expect(hit === card, "カードの真ん中で当たるのは重ねた NSView")
        #expect(Self.responders(from: card).contains { $0 === scroll }, "重ねた NSView の次の応答者をたどると一覧のスクロールに届く")

        hit?.scrollWheel(with: try Self.wheel(lines: -5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(pasted == 0)
        #expect(model.pressedRowID == nil)
    }

    @Test("重ねた NSView にホイールを渡すと、外側のスクロールが動き、押す・離すは起きない")
    func overlayPassesScrollToEnclosingScrollView() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 200, height: 100)
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        let document = FlippedView(frame: CGRect(x: 0, y: 0, width: size.width, height: 1000))
        let card = CardMouseView(frame: CGRect(x: 0, y: 0, width: size.width, height: 80))
        card.rowID = UUID()
        var presses = 0
        var releases = 0
        card.onPress = { _ in presses += 1 }
        card.onRelease = { _, _ in releases += 1 }
        document.addSubview(card)
        scroll.documentView = document
        let window = Self.offscreenWindow(size: size, content: scroll)
        defer { Self.close(window) }

        // 合成した最初の 1 回は、どこへ渡しても素の NSScrollView が動かない（2026-11-04 に確かめた）。スクロールへ直接 1 回送って捨てる
        scroll.scrollWheel(with: try Self.wheel(lines: -5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = scroll.contentView.bounds.origin.y
        card.scrollWheel(with: try Self.wheel(lines: -5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(
            scroll.contentView.bounds.origin.y > before, "下へ送られた（\(before) → \(scroll.contentView.bounds.origin.y)）")
        #expect(presses == 0)
        #expect(releases == 0)
    }

    // MARK: 道具

    /// 画面の外の枠なしの窓（ScrollView の位置送りは表示中の窓でしか効かないので出す。どの画面にも映らない）
    static func offscreenWindow(size: CGSize, content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }

    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// ホイールを行単位で回した出来事（負は下へ送る向き）
    static func wheel(lines: Int32) throws -> NSEvent {
        let cgEvent = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    static func responders(from view: NSView) -> [NSResponder] {
        var chain: [NSResponder] = []
        var next: NSResponder? = view
        while let responder = next, chain.count < 64 {
            chain.append(responder)
            next = responder.nextResponder
        }
        return chain
    }

    static func cardViews(in root: NSView) -> [CardMouseView] {
        var found: [CardMouseView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let card = view as? CardMouseView { found.append(card) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}
