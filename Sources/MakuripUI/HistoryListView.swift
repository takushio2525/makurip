import MakuripCore
import Observation
import SwiftUI

/// 仮の一覧の状態。絞り込みは大文字小文字・全角半角・濁点の有無を区別しない部分一致（仮）。
/// ひらがな/カタカナ・ローマ字に強い本番の検索はフェーズ2で作る
@MainActor
@Observable
final class HistoryListModel {
    var query = "" {
        didSet {
            if query != oldValue {
                refilter()
                selectedIndex = 0
            }
        }
    }
    private(set) var allItems: [ClipItem] = []
    private(set) var filtered: [ClipItem] = []
    var selectedIndex = 0
    /// 値が変わるたびに絞り込み欄へフォーカスを当てる
    var focusRequest = 0

    var selected: ClipItem? {
        filtered.indices.contains(selectedIndex) ? filtered[selectedIndex] : nil
    }

    func setItems(_ items: [ClipItem]) {
        let selectedID = selected?.id
        allItems = items
        refilter()
        if let selectedID, let index = filtered.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(0, filtered.count - 1))
        }
    }

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), filtered.count - 1)
    }

    private func refilter() {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            filtered = allItems
            return
        }
        filtered = allItems.filter { item in
            let haystack = [
                item.previewText ?? "", item.source?.name ?? "", item.kind.label, item.copyMethod.label,
            ].joined(separator: "\n")
            return tokens.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }
}

struct HistoryListView: View {
    @Bindable var model: HistoryListModel
    let onPaste: (UUID) -> Void
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("絞り込み", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.top, 30)
                .padding(.bottom, 12)
                .focused($queryFocused)
            Divider()
            if model.filtered.isEmpty {
                Spacer()
                Text(model.allItems.isEmpty ? "履歴はまだありません" : "一致する履歴はありません")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, item in
                                HistoryRow(item: item, isSelected: index == model.selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { onPaste(item.id) }
                                    .onTapGesture { model.selectedIndex = index }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedIndex) { _, _ in
                        if let id = model.selected?.id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            Text("↑↓ で選ぶ　Enter で貼り付け　Esc で閉じる")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { queryFocused = true }
        .onChange(of: model.focusRequest) { _, _ in queryFocused = true }
    }
}

struct HistoryRow: View {
    let item: ClipItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.kind.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear))
    }

    private var title: String {
        if let text = item.previewText, let line = text.split(whereSeparator: \.isNewline).first {
            return String(line)
        }
        return
            "\(item.kind.label)（\(ByteCountFormatter.string(fromByteCount: Int64(item.totalBytes), countStyle: .file))）"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let name = item.source?.name ?? item.source?.bundleID { parts.append(name) }
        parts.append(item.copyMethod.label)
        parts.append(item.lastUsedAt.formatted(.relative(presentation: .named)))
        if item.copyCount > 1 { parts.append("\(item.copyCount) 回") }
        return parts.joined(separator: "・")
    }
}
