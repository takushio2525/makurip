import CoreGraphics
import Testing

@testable import MakuripCore

/// メニューバーの項目の置き場所（#35）。数値は macOS 26・14 インチの内蔵画面での実測
@Suite("メニューバーの項目の置き場所")
struct StatusItemPlacementTests {
    /// 内蔵画面（幅 1512pt）。ノッチの右の領域は x=848〜1512（幅 664）
    let notched = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notchRightWidth: CGFloat = 664

    @Test("保存位置が無いときだけ種をまく。利用者が動かした位置（とまいた種）には触らない")
    func seedOnlyWhenMissing() {
        #expect(StatusItemPlacement.positionToSeed(saved: nil) == StatusItemPlacement.seedPosition)
        #expect(StatusItemPlacement.positionToSeed(saved: 412.0) == nil)
        #expect(StatusItemPlacement.positionToSeed(saved: StatusItemPlacement.seedPosition) == nil)
    }

    @Test("種はシステムの項目（100〜400 台）より左に並ぶ値")
    func seedIsLeftOfSystemItems() {
        #expect(StatusItemPlacement.seedPosition >= 500)
    }

    @Test("隔離したインスタンスは本番と別の保存名・別の鍵（本番の位置を書き換えない）")
    func isolatedUsesOwnName() {
        let production = StatusItemPlacement.autosaveName(isolated: false)
        let isolated = StatusItemPlacement.autosaveName(isolated: true)
        #expect(production != isolated)
        #expect(
            StatusItemPlacement.preferredPositionKey(autosaveName: production)
                == "NSStatusItem Preferred Position MakuripStatusItem")
        #expect(
            StatusItemPlacement.preferredPositionKey(autosaveName: production)
                != StatusItemPlacement.preferredPositionKey(autosaveName: isolated))
    }

    @Test("ノッチの右の領域に収まっていれば見える（種をまいた位置 x=1001）")
    func visibleRightOfNotch() {
        let frame = CGRect(x: 1001, y: 949, width: 38, height: 33)
        #expect(
            StatusItemPlacement.visibility(itemFrame: frame, screenFrame: notched, rightOfNotchWidth: notchRightWidth)
                == .visible)
    }

    @Test("ノッチの左（種なしで押し出された x=566）とノッチにかかる位置（x=829）は隠れている")
    func hiddenBehindNotch() {
        for x in [566.0, 829.0] {
            let frame = CGRect(x: x, y: 949, width: 38, height: 33)
            #expect(
                StatusItemPlacement.visibility(
                    itemFrame: frame, screenFrame: notched, rightOfNotchWidth: notchRightWidth) == .behindNotch)
        }
    }

    @Test("ノッチのない画面・窓がないときは決めない（遮蔽状態はロック中に当てにならないので使わない）")
    func unknownWithoutNotch() {
        let frame = CGRect(x: 1677, y: 1410, width: 38, height: 30)
        let plain = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(
            StatusItemPlacement.visibility(itemFrame: frame, screenFrame: plain, rightOfNotchWidth: nil) == .unknown)
        #expect(StatusItemPlacement.visibility(itemFrame: frame, screenFrame: plain, rightOfNotchWidth: 0) == .unknown)
        #expect(
            StatusItemPlacement.visibility(itemFrame: nil, screenFrame: notched, rightOfNotchWidth: notchRightWidth)
                == .unknown)
    }

    @Test("内蔵画面が主画面でない（左に外部画面がある）ときも、画面の右端からの幅で判定する")
    func notchedScreenWithOffset() {
        let offset = CGRect(x: 2560, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 2560 + 1001, y: 949, width: 38, height: 33)
        let hidden = CGRect(x: 2560 + 566, y: 949, width: 38, height: 33)
        #expect(
            StatusItemPlacement.visibility(itemFrame: visible, screenFrame: offset, rightOfNotchWidth: notchRightWidth)
                == .visible)
        #expect(
            StatusItemPlacement.visibility(itemFrame: hidden, screenFrame: offset, rightOfNotchWidth: notchRightWidth)
                == .behindNotch)
    }
}
