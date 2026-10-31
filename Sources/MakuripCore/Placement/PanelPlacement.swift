import CoreGraphics

/// パネルを出す手がかり。座標はすべて AppKit の画面座標（左下が原点）
public enum PanelAnchor: Equatable, Sendable {
    /// 文字カーソル（AX の `AXBoundsForRange` で取れたとき）
    case caret(CGRect)
    /// 焦点のある入力欄の枠（文字カーソルが取れないアプリ。ターミナル・Electron 製など）
    case field(CGRect)
    /// マウスの位置（入力欄も取れないとき）
    case mouse(CGPoint)
    /// 手がかりなし（画面の下寄りの中央に出す）
    case none
}

/// パネル・候補窓をどこに出すかの計算（純粋関数）。位置の手がかりは `InsertionPointLocator` が AX で取る。
///
/// 案 B のパネル（#2）は試作（`makurip-design/ui/shared/panel-b.js` の `place`）どおり、文字カーソルの**下**に、
/// 左端をカーソルより少し左にそろえて出す。下に入りきらなければ上に出す。
/// 候補窓（#8）はカーソルの**横（右）**に、選んでいる行の高さをカーソルの行にそろえて出す（`.beside`）。
public enum PanelPlacement {
    public enum Side: Sendable {
        /// カーソルの下（入らなければ上）。案 B のパネル
        case below
        /// カーソルの右（入らなければ左）。`rowOffset` はパネルの上端から「カーソルの行にそろえたい行」の中心までの距離
        case beside(rowOffset: CGFloat)
    }

    /// 画面の端から空ける幅
    public static let screenMargin: CGFloat = 12
    /// カーソルとパネルのすき間
    public static let gap: CGFloat = 8
    /// パネルの左端をカーソルより左へずらす幅（試作の `c.left - 18`）
    public static let caretLeading: CGFloat = 18

    /// パネルの枠（AppKit の座標）。`screens` は各画面の `visibleFrame`（メニューバーと Dock を除いた範囲）
    public static func frame(
        size: CGSize, anchor: PanelAnchor, screens: [CGRect], side: Side = .below, mouse: CGPoint? = nil
    ) -> CGRect {
        let point = anchorPoint(anchor) ?? mouse ?? .zero
        guard let screen = screen(containing: point, in: screens) else {
            return CGRect(origin: .zero, size: size)
        }
        let target: CGRect
        switch anchor {
        case .caret(let rect):
            target = rect
        case .field(let rect):
            // 入力欄の枠の左下を、高さのないカーソルとみなす（大きい入力欄の上端まで飛ばないように）
            target = CGRect(x: rect.minX, y: rect.minY, width: 0, height: 0)
        case .mouse(let point):
            target = CGRect(origin: point, size: .zero)
        case .none:
            let origin = CGPoint(
                x: screen.midX - size.width / 2, y: screen.minY + max(0, screen.height - size.height) * 0.25)
            return clamp(CGRect(origin: origin, size: size), in: screen)
        }
        var origin: CGPoint
        switch side {
        case .below:
            origin = CGPoint(x: target.minX - caretLeading, y: target.minY - gap - size.height)
            if origin.y < screen.minY + screenMargin {
                origin.y = target.maxY + gap
            }
        case .beside(let rowOffset):
            origin = CGPoint(x: target.maxX + gap, y: target.midY + rowOffset - size.height)
            if origin.x + size.width > screen.maxX - screenMargin {
                origin.x = target.minX - gap - size.width
            }
        }
        return clamp(CGRect(origin: origin, size: size), in: screen)
    }

    /// ⌘Y の大きいプレビューの枠。パネルの右に入れば右、入らなければ左。上端と高さはパネルにそろえる
    public static func peekFrame(panel: CGRect, width: CGFloat, screens: [CGRect], gap: CGFloat = 10) -> CGRect {
        let screen = Self.screen(containing: CGPoint(x: panel.midX, y: panel.midY), in: screens) ?? panel
        let fitsRight = panel.maxX + gap + width <= screen.maxX - screenMargin
        let x = fitsRight ? panel.maxX + gap : panel.minX - gap - width
        return CGRect(x: x, y: panel.minY, width: width, height: panel.height)
    }

    /// AX の座標（主画面の左上が原点・y は下向き）を AppKit の座標（主画面の左下が原点・y は上向き）へ
    public static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: 内部

    static func anchorPoint(_ anchor: PanelAnchor) -> CGPoint? {
        switch anchor {
        case .caret(let rect), .field(let rect): CGPoint(x: rect.minX, y: rect.midY)
        case .mouse(let point): point
        case .none: nil
        }
    }

    /// 点を含む画面。どれにも入らなければいちばん近い画面
    static func screen(containing point: CGPoint, in screens: [CGRect]) -> CGRect? {
        if let hit = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) { return hit }
        return screens.min { distance(point, $0) < distance(point, $1) }
    }

    static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// 画面の中に収める（上はメニューバーの下 8pt、ほかの辺は 12pt 空ける。試作と同じ）
    static func clamp(_ rect: CGRect, in screen: CGRect) -> CGRect {
        var origin = rect.origin
        origin.x = min(max(screen.minX + screenMargin, origin.x), screen.maxX - rect.width - screenMargin)
        origin.y = max(min(origin.y, screen.maxY - rect.height - gap), screen.minY + screenMargin)
        return CGRect(origin: origin, size: rect.size)
    }
}
