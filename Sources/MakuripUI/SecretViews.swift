import MakuripCore
import SwiftUI

/// 秘密の項目の表示（試作の .secret-box・.kbadge[data-kind=secret]・.secret-inline）。
///
/// 一覧用の平文（`ClipItem.previewText`）は取り込みのときに伏せ字にしてあるので、隠しているときはそれをそのまま出す。
/// 本当の中身は、表示のキー（既定 ⌥）を押している間とプレビューの「押している間だけ表示」の間だけ `ClipContentLoader.secret` から読む

enum SecretDisplay {
    /// 伏せ字の箱で出すか。画像は、秘密が添えられた文字（URL など）の側にあって画面に出ないので、画像のまま出す
    static func masks(_ item: ClipItem) -> Bool {
        item.isSecretLikely && item.kind != .image
    }
}

/// 種類の札の隣に出す「秘密」の札（鍵の印）
struct SecretBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock").font(.system(size: 10.5))
            Text("秘密")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(palette.secret)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.secret.opacity(0.14)))
    }
}

/// 伏せ字（または表示中の中身）の箱。隠しているときは赤みの鍵、表示しているときは青みの目
struct SecretBox: View {
    enum Size {
        /// 一覧のカード（試作の .pv-secret.sm）
        case card
        /// ⌘Y のプレビュー（試作の .pv-secret.lg）
        case preview
    }

    let text: String
    let shown: Bool
    let size: Size
    @Environment(\.palette) private var palette

    var body: some View {
        let radius: CGFloat = size == .card ? 9 : 12
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = shown ? palette.accent : palette.secret
        HStack(alignment: .center, spacing: size == .card ? 8 : 10) {
            Image(systemName: shown ? "eye" : "lock")
                .font(.system(size: size == .card ? 12 : 15))
                .foregroundStyle(shown ? palette.accentInk : palette.secret)
            Text(text)
                .font(CSSText.mono(size == .card ? 11.5 : 14))
                .lineSpacing(size == .card ? 2 : 4)
                .foregroundStyle(palette.text)
                .lineLimit(size == .card ? 3 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(
            size == .card
                ? EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
                : EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        )
        .background(shape.fill(shown ? palette.accentSoft : palette.secret.opacity(0.09)))
        .overlay(shape.strokeBorder(tint.opacity(shown ? 0.4 : 0.3), lineWidth: 0.5))
    }
}

/// 「⌥ を押している間だけ表示」のように、キーを文の中に出す
struct RevealHint: View {
    let combo: KeyCombo?
    let suffix: String
    var chipStyle: KeyChip.Style = .normal

    var body: some View {
        HStack(spacing: 5) {
            if let combo { KeyChip(combo, style: chipStyle) }
            Text(combo == nil ? "表示のキーは未設定です" : suffix)
        }
    }
}

/// カードの本文（伏せ字の箱と、表示のキーの案内）
struct SecretCardBody: View {
    let item: ClipItem
    let revealing: Bool
    let keymap: Keymap
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecretBox(text: shownText, shown: revealing, size: .card)
            RevealHint(combo: keymap.primary(.reveal), suffix: "を押している間だけ表示")
                .font(.system(size: 11))
                .foregroundStyle(palette.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shownText: String {
        if revealing { return DisplayText.leadingLines(loader.secret(for: item).text, count: 3) }
        return item.previewText ?? String(repeating: SecretMask.bullet, count: 16)
    }
}

/// ⌘Y のプレビューの本文（試作の .pv-secret.lg: 箱・理由と案内・押している間だけ表示するボタン）
struct SecretPreviewBody: View {
    let item: ClipItem
    let model: HistoryPanelModel
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        let secret = loader.secret(for: item)
        let revealing = model.isRevealing
        ScrollView([.vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                SecretBox(text: revealing ? secret.text : secret.masked, shown: revealing, size: .preview)
                note(reason: secret.reason)
                    .padding(.top, 10)
                if secret.truncated {
                    Text(verbatim: "長いので先頭の \(ClipContentLoader.previewCharacterLimit) 文字だけを表示しています（貼るときは全文が入ります）")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.text2)
                        .padding(.top, 6)
                }
                PressToReveal(pressed: Binding(get: { model.revealPressed }, set: { model.revealPressed = $0 }))
                    .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 22, leading: 18, bottom: 16, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func note(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(reason)なので隠しています。")
            RevealHint(combo: model.keymap.primary(.reveal), suffix: "を押している間だけ表示します。")
            Text("貼り付けると元の文字列が入ります。")
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.text2)
    }
}

/// 押している間だけ表示するボタン（試作の .peek。離すとすぐ隠れる）
struct PressToReveal: View {
    @Binding var pressed: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye").font(.system(size: 12))
            Text("押している間だけ表示")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(palette.text)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(pressed ? palette.fill3 : palette.fill2))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false })
    }
}
