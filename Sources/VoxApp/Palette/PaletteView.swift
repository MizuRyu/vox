// コマンドパレットの SwiftUI view 群。パネルの生成と状態は PalettePanel.swift。
import AppKit
import SwiftUI
import VoxCore

/// 検索フィールド。NSTextField の field editor に ↑↓ / Enter / ⌥Enter を拾わせる。
private struct QueryField: NSViewRepresentable {
  let model: PaletteModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.delegate = context.coordinator
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    field.placeholderString = "ファイル名の一部を打つ"
    field.stringValue = model.query
    field.cell?.usesSingleLineMode = true
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    if field.stringValue != model.query { field.stringValue = model.query }
    let coordinator = context.coordinator
    if coordinator.focusToken != model.focusToken {
      coordinator.focusToken = model.focusToken
      coordinator.focusAttempts = 0
    }
    // HUD と同じ理由で同期・回数制限（毎回 async を積むと main を溢れさせる）。
    guard coordinator.focusAttempts < Coordinator.focusAttemptLimit, let window = field.window,
      window.firstResponder !== field.currentEditor()
    else { return }
    coordinator.focusAttempts += 1
    guard window.makeFirstResponder(field) else { return }
    // T22。一度取れたら次の focusToken までは奪い返さない。
    // 右ペインを選択している間に再描画が来てもフォーカスを取り上げないため。
    coordinator.focusAttempts = Coordinator.focusAttemptLimit
    // makeFirstResponder は全選択にする。マウスから戻したときに打ち直しにならないよう末尾へ置く。
    if let editor = field.currentEditor() {
      editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    /// パネルが key になるまでの取り直しの上限。到達したら次の focusToken まで諦める。
    static let focusAttemptLimit = 5

    let model: PaletteModel
    var focusAttempts = 0
    var focusToken = -1

    init(model: PaletteModel) {
      self.model = model
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      // 先頭に打った記号は語ではなく sigil の切り替えとして解釈する（ADR-005）。
      let parsed = PaletteQueryParser.parse(field.stringValue, current: model.sigil)
      if parsed.sigil != model.sigil {
        model.sigil = parsed.sigil
        field.stringValue = parsed.term
      }
      model.query = parsed.term
      model.selection = model.defaultSelection
      model.refreshRows()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.moveUp(_:)):
        model.move(by: -1)
        return true
      case #selector(NSResponder.moveDown(_:)):
        model.move(by: 1)
        return true
      case #selector(NSResponder.insertNewline(_:)):
        model.commit(fileNameOnly: false)
        return true
      case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
        // ⌥Enter。ファイル名のみ。
        model.commit(fileNameOnly: true)
        return true
      default:
        return false
      }
    }
  }
}

/// パレット内の検索フィールドを探す。プレビューからフォーカスを返すときに使う（T22）。
@MainActor
private func findQueryField(in view: NSView?) -> NSTextField? {
  guard let view else { return nil }
  if let field = view as? NSTextField, field.isEditable { return field }
  for subview in view.subviews {
    if let found = findQueryField(in: subview) { return found }
  }
  return nil
}

/// T22。読み取り専用のプレビュー。マウスでの選択と ⌘C（Edit メニューの `copy:`）だけ受ける。
private final class PreviewTextView: NSTextView {
  /// `⌘A` は検索フィールドの全選択を優先する（プレビューではなく）。
  override func selectAll(_ sender: Any?) {
    guard let editor = focusQueryField() else {
      super.selectAll(sender)
      return
    }
    editor.selectAll(sender)
  }

  /// 打鍵はパレットの操作（検索・↑↓・Enter）に返す。読み取り専用なのでここでは食べない。
  override func keyDown(with event: NSEvent) {
    guard let editor = focusQueryField() else {
      super.keyDown(with: event)
      return
    }
    editor.keyDown(with: event)
  }

  private func focusQueryField() -> NSText? {
    guard let window, let field = findQueryField(in: window.contentView),
      window.makeFirstResponder(field)
    else { return nil }
    return field.currentEditor()
  }
}

/// 右ペインの本文。選択できるようにするため SwiftUI の `Text` ではなく NSTextView で描く。
private struct PreviewPane: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let textView = PreviewTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    textView.textColor = .secondaryLabelColor
    // 折り返さない（従来の 1 行 1 行の見た目を保つ）。溢れた分は横にスクロールする。
    textView.minSize = .zero
    let unbounded = CGFloat.greatestFiniteMagnitude
    textView.maxSize = NSSize(width: unbounded, height: unbounded)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.autoresizingMask = []
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.size = NSSize(width: unbounded, height: unbounded)

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? PreviewTextView, textView.string != text else {
      return
    }
    // 中身が変わった回だけ差し替える（選択を毎フレーム消さないため）。
    textView.string = text
    scroll.contentView.scroll(to: .zero)
  }
}

struct PaletteView: View {
  @ObservedObject var model: PaletteModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      field
      sigilLegend
      panes
      insertionPreview
      footer
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.regularMaterial)
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          // T22。開いている間も給餌は止めないので「録音中」を出す（HUD の状態表示と揃える）。
          Circle().fill(Color.red.opacity(0.9)).frame(width: 7, height: 7)
          Text("録音は続いています")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Text("ファイルを選ぶ")
          .font(.system(size: 16, weight: .semibold))
        Text("@ ファイル")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 12)
      Text(targetLabel)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(model.targetUnresolved ? Color.orange : Color.secondary)
        .lineLimit(1)
        .truncationMode(.head)
    }
  }

  private var targetLabel: String {
    if model.resolvingTarget { return "検索対象を確認中" }
    if let target = model.target {
      return target.source == .fallback ? "検索対象が決まりません: \(target.root)" : target.root
    }
    return "検索対象が決まりません"
  }

  private var field: some View {
    HStack(spacing: 8) {
      Text(model.sigil.rawValue)
        .font(.system(size: 15, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.accentColor)
      QueryField(model: model)
        .frame(height: 20)
      Text("Esc")
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
  }

  private var sigilLegend: some View {
    HStack(spacing: 12) {
      ForEach(PaletteSigil.allCases, id: \.self) { sigil in
        HStack(spacing: 4) {
          Text(sigil.rawValue)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
          Text(sigil.label)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
          if !sigil.isImplemented {
            Text("拡張")
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
          }
        }
        .opacity(sigil == model.sigil ? 1 : 0.55)
      }
      Spacer(minLength: 0)
    }
  }

  private var panes: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Picker(
            "表示",
            selection: Binding(
              get: { model.fileViewMode },
              set: { model.setFileViewMode($0) }
            )
          ) {
            ForEach(PaletteModel.FileViewMode.allCases, id: \.self) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 132)
          Spacer(minLength: 8)
          if model.fileViewMode == .tree && !model.query.isEmpty {
            Text("検索中は親フォルダを開く")
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
          }
          Text("\(model.changedCount) / \(model.totalCount)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              if model.fileViewMode == .changes {
                changesList
              } else {
                ForEach(Array(model.treeRows.enumerated()), id: \.element.id) { index, row in
                  FileTreeRowView(
                    row: row,
                    selected: index == model.selection,
                    onSelect: { model.select(index) },
                    onToggle: {
                      model.select(index)
                      model.toggleDirectory(at: index)
                    },
                    onActivate: {
                      model.select(index)
                      model.commit(fileNameOnly: false)
                    },
                    directoryToggleEnabled: model.query.isEmpty
                  )
                  .id("tree:" + row.id)
                }
              }
            }
            // Keep each display mode in its own lazy row container.
            .id(model.fileViewMode)
          }
          .onChange(of: model.selection) { _, _ in
            if let rowID = model.selectedDisplayID {
              proxy.scrollTo(rowID, anchor: .center)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)

      VStack(alignment: .leading, spacing: 6) {
        previewLabel
        PreviewPane(text: model.previewText)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxHeight: .infinity)
  }

  /// Changes 表示の行。T38-a の worktree 候補を先頭に置き、選択インデックスは 1 つの空間で数える。
  @ViewBuilder
  private var changesList: some View {
    let candidates = model.visibleWorktrees
    ForEach(Array(candidates.enumerated()), id: \.element.path) { index, candidate in
      WorktreeRowView(
        candidate: candidate,
        selected: index == model.selection,
        onSelect: { model.select(index) },
        onCommit: {
          model.select(index)
          model.commit(fileNameOnly: false)
        }
      )
      .id("worktree:" + candidate.path)
    }
    ForEach(Array(model.rows.enumerated()), id: \.element.file.path) { index, row in
      PaletteRowView(
        row: row,
        selected: index + candidates.count == model.selection,
        onSelect: { model.select(index + candidates.count) },
        onCommit: { fileNameOnly in
          model.select(index + candidates.count)
          model.commit(fileNameOnly: fileNameOnly)
        }
      )
      .id("changes:" + row.file.path)
    }
  }

  /// T22。右ペインのヘッダ。コピーボタンを置き、コピー直後の 1.2 秒だけ表示を差し替える。
  private var previewLabel: some View {
    HStack {
      Text(model.copiedNotice ? "コピーしました" : (model.preview?.title ?? "プレビュー"))
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(model.copiedNotice ? Color.accentColor : Color.secondary)
      Spacer(minLength: 8)
      Text(model.preview?.detail ?? "—")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
      Button {
        model.copyPreview()
      } label: {
        Image(systemName: "doc.on.doc")
          .font(.system(size: 10))
          .foregroundStyle(model.previewText.isEmpty ? Color.secondary : Color.accentColor)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.previewText.isEmpty)
      .help("プレビューをコピー")
    }
  }

  private var insertionPreview: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("貼り付け先")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
      HStack(spacing: 4) {
        if !model.committedTail.isEmpty {
          Text("…" + model.committedTail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        Text(model.selectedRow?.file.path ?? "")
          .font(.system(size: 11, design: .monospaced))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
      }
      Spacer(minLength: 0)
    }
  }

  private var footer: some View {
    HStack(spacing: 14) {
      hint("↑↓", "選択")
      hint("Enter", "パスを入れる") { model.commit(fileNameOnly: false) }
      hint("⌥Enter", "ファイル名のみ")
      hint("Esc", "閉じる") { model.cancel() }
      Spacer(minLength: 0)
    }
  }

  /// `action` を渡したヒントはクリックでも同じ動作をする（キーと同じ経路）。
  private func hint(_ key: String, _ label: String, action: (() -> Void)? = nil) -> some View {
    HStack(spacing: 5) {
      Text(key)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
      Text(label)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .onTapGesture { action?() }
  }
}

private struct FileTreeRowView: View {
  let row: FileTreeRow
  let selected: Bool
  let onSelect: () -> Void
  let onToggle: () -> Void
  let onActivate: () -> Void
  let directoryToggleEnabled: Bool
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 6) {
      rowIcon
      Text(row.name)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
      Spacer(minLength: 6)
      if let status = row.file?.status {
        Text(status.rawValue)
          .font(.system(size: 9, weight: .bold, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, CGFloat(row.depth) * 14)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      selected
        ? Color.accentColor.opacity(0.18) : (hovered ? Color.secondary.opacity(0.10) : .clear),
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture(count: 2) { onActivate() }
    .onTapGesture { onSelect() }
  }

  @ViewBuilder
  private var rowIcon: some View {
    if row.kind == .directory {
      Button(action: onToggle) {
        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 12)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!directoryToggleEnabled)
      .help(directoryToggleEnabled ? "フォルダを開閉" : "検索中は一致したファイルの親フォルダを開きます")
    } else {
      Image(systemName: "doc")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.secondary.opacity(0.65))
        .frame(width: 12)
    }
  }
}

/// T38-a。検索対象を切り替える候補行。パスは挿入しないので `onCommit` に fileNameOnly はない。
private struct WorktreeRowView: View {
  let candidate: WorktreeCandidate
  let selected: Bool
  let onSelect: () -> Void
  let onCommit: () -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      Text("worktree")
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.blue)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
      Text(candidate.path)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 6)
      if let branch = candidate.branch {
        Text(branch)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      selected
        ? Color.accentColor.opacity(0.18) : (hovered ? Color.secondary.opacity(0.10) : .clear),
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture(count: 2) { onCommit() }
    .onTapGesture { onSelect() }
  }
}

private struct PaletteRowView: View {
  let row: PaletteRow
  let selected: Bool
  let onSelect: () -> Void
  /// ダブルクリック。`fileNameOnly` は ⌥ を押していたか。
  let onCommit: (_ fileNameOnly: Bool) -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      Text(attributedPath)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 6)
      if let status = row.file.status {
        Text(status.rawValue)
          .font(.system(size: 9, weight: .bold, design: .monospaced))
          .foregroundStyle(badgeColor(status))
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(badgeColor(status).opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(background, in: RoundedRectangle(cornerRadius: 5))
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    // ダブルクリックを先に置く。単クリックが先に発火しても選択が動くだけで実害はない。
    // ⌥ はジェスチャから取れないので、クリック時点の修飾キーを見る。
    .onTapGesture(count: 2) { onCommit(NSEvent.modifierFlags.contains(.option)) }
    .onTapGesture { onSelect() }
  }

  /// 選択とホバーは別の見た目にする（ホバーは薄く）。
  private var background: Color {
    if selected { return Color.accentColor.opacity(0.18) }
    return hovered ? Color.secondary.opacity(0.10) : Color.clear
  }

  private func badgeColor(_ status: FileChangeStatus) -> Color {
    switch status {
    case .modified: .orange
    case .added: .green
    case .deleted: .red
    case .untracked: .purple
    }
  }

  /// ディレクトリ部分は淡色、ファイル名は通常、一致した文字は強調（モックの `.hit`）。
  private var attributedPath: AttributedString {
    let characters = Array(row.file.path)
    let fileNameStart = characters.lastIndex(of: "/").map { $0 + 1 } ?? 0
    let matched = Set(row.matchedIndices)
    var result = AttributedString()
    for (index, character) in characters.enumerated() {
      var piece = AttributedString(String(character))
      if matched.contains(index) {
        piece.foregroundColor = .accentColor
        piece.inlinePresentationIntent = .stronglyEmphasized
      } else if index < fileNameStart {
        piece.foregroundColor = .secondary
      } else {
        piece.foregroundColor = .primary
      }
      result.append(piece)
    }
    return result
  }
}
