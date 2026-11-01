import AppKit
import SwiftUI
import VoxCore

@MainActor
public final class HudModel: ObservableObject {
  @Published public var status = "準備中"
  /// 淡色より前に確定した分。音声の final と、それ以前に打った文字が入る（T21 で `committed` から改名）。
  @Published public var head = ""
  /// いま出ている淡色。並びは `head` と `tail` の**間**（T21）。
  @Published public private(set) var tentative = ""
  /// 淡色より後ろの確定本文。途中への音声挿入で残した文と、淡色の後ろに打った文字。
  @Published public var tail = ""
  private var caret: Int?
  private enum DeferredUpdate {
    case tentative(String)
    case final(String)
    case insertion(PaletteInsertionPlan)
  }
  private var deferredUpdates: [DeferredUpdate] = []
  var hasDeferredUpdates: Bool { !deferredUpdates.isEmpty }
  var onFinishEditing: (() -> Void)?
  var onTranscriptChange: (() -> Void)?
  /// 中段をテキストの代わりに占める通知（挿入確認の失敗など）。
  @Published public var notice: String?
  /// ADR-017。画像を保存できなかったときの 1 行。キーヒントの行に出す
  /// （`notice` は本文と入れ替わるので、録音中の失敗には使えない）。
  @Published var attachmentNotice: String?
  /// 波形用。tap の RMS。
  @Published public var level = 0.0
  /// HUD を出すたびに増える。テキストビューのフォーカス取得をやり直す合図。
  @Published public var focusToken = 0
  /// `reset` のたびに増える。テキストビューの中身を作り直す合図（前の回の本文を残さない）。
  @Published public var resetToken = 0
  /// T13。パレットが返したパスを caret 位置に差し込む合図。
  @Published public var insertionToken = 0

  /// ユーザーが打った文字数（計測 JSONL の `typed_chars`）。0 なら打っていない。
  public var typedCharacters = 0

  /// T13。`@` の打鍵をパレットの合図として扱ってよい状態か（録音中のみ）。
  public var isRecording = false
  /// T15。テキストビューが IME の変換中（marked text がある）。
  /// 変換中は esc / ⌃P を tap で飲まない（IME のキャンセルと変換操作を優先する）。
  public var isComposing = false
  /// この録音で一度でも打った、変換を始めた、パレットから差し込んだか。消した後も残す（ADR-023）。
  public var hadInput = false
  /// T13。`--no-sigil-trigger` で false。打鍵トリガーを止めて `⌃P` だけにする。
  public var sigilTriggerEnabled = true
  /// T13。sigil が打たれた。第 2 引数は打った caret 位置（UTF-16）。
  public var onSigil: ((PaletteSigil, Int) -> Void)?
  /// T20。ファイルのペーストを相対パスにするための検索対象のルート。
  /// パレットが対象を解決したときに入る（未解決なら nil で、絶対パスを `~` に短縮するだけ）。
  public var repositoryRoot: String?

  /// `insertionToken` と対になる差し込み内容。適用するのはビュー側。
  public private(set) var pendingInsertion: PaletteInsertionPlan?

  /// T18。右上のボタンで HUD を伸ばして全文を見せているか。セッションを越えて覚える。
  @Published public var isExpanded = UserDefaults.standard.bool(forKey: HudModel.expandedKey)
  /// 展開の切り替え後にパネルの高さを引き直す合図（`HudPanel` が入れる）。
  public var onExpandedChange: (() -> Void)?
  public var onSettings: (() -> Void)?
  @Published public var toggleShortcutLabel = "⌘⇧Space"

  public static let expandedKey = "voxHudExpanded"

  public init() {}

  /// 3 区画をこの並びで組むのはここだけ。並びの規則は `TranscriptBuffer` が持つ（T21）。
  public var transcript: TranscriptBuffer {
    TranscriptBuffer(head: head, tentative: tentative, tail: tail, caret: caret)
  }

  /// T18。右上のボタン。展開状態を反転して覚え、パネル側に高さの引き直しを頼む。
  public func toggleExpanded() {
    isExpanded.toggle()
    UserDefaults.standard.set(isExpanded, forKey: HudModel.expandedKey)
    onExpandedChange?()
  }

  /// 音声のfinal。表示中の淡色を確定し、新しい区間ならカーソル位置へ入れる。
  /// 区画の決め方は `TranscriptBuffer` に任せる（ビューは差分の当て方だけを見る）。
  public func commitFinal(_ suffix: String) {
    guard !suffix.isEmpty else { return }
    guard !deferWhileComposing(.final(suffix)) else { return }
    var buffer = transcript
    buffer.commitFinal(suffix, at: buffer.caret)
    adopt(buffer)
    onTranscriptChange?()
  }

  /// 新しい淡色はカーソル位置から始め、更新中はその挿入位置を保つ。
  public func applyTentative(_ text: String) {
    guard !deferWhileComposing(.tentative(text)) else { return }
    var buffer = transcript
    buffer.applyTentative(text, at: buffer.caret)
    adopt(buffer)
    onTranscriptChange?()
  }

  private func adopt(_ buffer: TranscriptBuffer) {
    head = buffer.head
    tail = buffer.tail
    tentative = buffer.tentative
    caret = buffer.caret
  }

  func setCaret(_ location: Int) {
    caret = transcript.clampCaret(location)
  }

  /// IMEの本文を反映してから、変換中に保留した音声とパスを順に適用する。
  func acceptEdit(_ buffer: TranscriptBuffer) {
    let previous = transcript.text
    adopt(buffer)
    var updates = deferredUpdates
    deferredUpdates = []
    rebaseInsertions(&updates, after: 0, from: previous, to: buffer.text)
    for index in updates.indices {
      let previous = transcript.text
      switch updates[index] {
      case .tentative(let text): applyTentative(text)
      case .final(let text): commitFinal(text)
      case .insertion(let plan): requestInsertion(plan)
      }
      rebaseInsertions(&updates, after: index + 1, from: previous, to: transcript.text)
    }
  }

  private func rebaseInsertions(_ updates: inout [DeferredUpdate], after index: Int, from previous: String, to current: String) {
    guard index < updates.count, let change = TranscriptCaret.replacement(current: previous, desired: current) else { return }
    for position in index..<updates.count {
      guard case .insertion(let plan) = updates[position] else { continue }
      let location = transcript.clampCaret(TranscriptCaret.rebased(plan.location, by: change))
      let text = (current as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: plan.inserted)
      updates[position] = .insertion(PaletteInsertionPlan(text: text, inserted: plan.inserted,
        location: location, caret: location + (plan.inserted as NSString).length))
    }
  }

  private func deferWhileComposing(_ update: DeferredUpdate) -> Bool {
    guard isComposing else { return false }
    if case .tentative = update, case .tentative = deferredUpdates.last {
      deferredUpdates[deferredUpdates.count - 1] = update
    } else {
      deferredUpdates.append(update)
    }
    return true
  }

  /// 3 区画をまとめて空にする（HUD を出し直すとき。前の回の本文を持ち越さない）。
  public func clearText() {
    head = ""
    tentative = ""
    tail = ""
    caret = nil
    deferredUpdates = []
  }

  // MARK: ADR-017 画像の添付

  /// 走っている書き込み。前の分に続けて走らせ、差し込みの順を貼った順に保つ。
  /// 全部持つのは、HUD を出し直すときに**走っている分をすべて**取り消すため
  /// （最後の 1 つを取り消しても、待っている先行分は前の回のパスを入れてしまう）。
  private var attachmentTasks: [Task<Void, Never>] = []
  private var attachmentNoticeTask: Task<Void, Never>?

  func trackAttachment(_ work: @escaping @MainActor @Sendable () async -> Void) {
    let previous = attachmentTasks.last
    attachmentTasks.append(
      Task { @MainActor in
        await previous?.value
        guard !Task.isCancelled else { return }
        await work()
      })
  }

  /// 確定はここで書き込みを待つ。待っている間に貼られた分も終わるまで待つ。
  func awaitPendingAttachments() async {
    while let task = attachmentTasks.first {
      await task.value
      if attachmentTasks.first == task { attachmentTasks.removeFirst() }
    }
  }

  /// 2.5 秒でキーヒントに戻す（他の通知と同じ長さ）。
  func showAttachmentNotice(_ message: String) {
    attachmentNotice = message
    attachmentNoticeTask?.cancel()
    attachmentNoticeTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(2500))
      guard !Task.isCancelled else { return }
      self?.attachmentNotice = nil
    }
  }

  /// HUD を出し直すとき。通知を消し、走っている書き込みも捨てる（前の回のパスを次の本文に入れない）。
  func resetAttachments() {
    attachmentNoticeTask?.cancel()
    attachmentNoticeTask = nil
    attachmentNotice = nil
    for task in attachmentTasks { task.cancel() }
    attachmentTasks = []
  }

  /// パレットの確定。`plan.location` は全文のオフセット（T17）。
  /// どの区画に入るかは `TranscriptBuffer` の規則に任せ、ビューには差分の当て方を渡す。
  public func requestInsertion(_ plan: PaletteInsertionPlan) {
    guard !plan.inserted.isEmpty else { return }
    guard !deferWhileComposing(.insertion(plan)) else { return }
    var buffer = transcript
    guard buffer.insertTyped(plan.inserted, at: plan.location) else { return }
    hadInput = true
    pendingInsertion = plan
    adopt(buffer)
    insertionToken += 1
    onTranscriptChange?()
  }
}

/// 本文のテキストビュー。head + tentative + tail を 1 本のテキストとして描く（T21）。
///
/// **ビュー側を壊さないことが最優先**。SwiftUI の再描画は波形の更新で毎秒 15 回ほど走るので、
/// モデルの値でビューを全置換するとユーザーが打った文字が消える。
/// 差分だけを textStorage に当てる:
/// - final: 淡色域 `[headEnd, tentativeEnd)` を通常色の final で差し替える（`tail` は動かない）
/// - tentative: 発話を始めた位置の淡色だけを差し替える
/// - tail: 挿入位置より後ろの本文と手入力を通常色で残す
/// どちらもユーザー起点の変更ではないので `shouldChangeTextIn` を通さない。caret は保存して戻す。
public struct TranscriptEditor: NSViewRepresentable {
  let model: HudModel
  // SwiftUI は representable の格納プロパティの差分で updateNSView を呼ぶ。`model` は参照型で
  // 値が変わらないため、テキストの更新を値として持たせないと sync が走らない
  // （T11 でラベルを消したあと、実機で「音声が表示されない」不具合として出た）。
  let head: String
  let tentative: String
  let tail: String
  let resetToken: Int
  let focusToken: Int
  let insertionToken: Int

  public init(model: HudModel) {
    self.model = model
    self.head = model.head
    self.tentative = model.tentative
    self.tail = model.tail
    self.resetToken = model.resetToken
    self.focusToken = model.focusToken
    self.insertionToken = model.insertionToken
  }

  public func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  public func makeNSView(context: Context) -> NSScrollView {
    Self.makeScrollView(coordinator: context.coordinator)
  }

  /// T20。⌘V でのファイルのペーストを拾うために `TranscriptTextView` を自分で組む
  /// （`NSTextView.scrollableTextView()` は素の `NSTextView` を返すので paste を差し替えられない）。
  /// 構成は scrollableTextView と同じ（幅追従・縦だけリサイズ可）。
  public static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
    let size = NSSize(width: 320, height: 44)
    let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
    scrollView.borderType = .noBorder
    scrollView.hasHorizontalScroller = false
    scrollView.autoresizingMask = [.width, .height]
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false

    let textView = TranscriptTextView(frame: NSRect(origin: .zero, size: size))
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
      width: size.width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.coordinator = coordinator
    scrollView.documentView = textView

    textView.delegate = coordinator
    textView.drawsBackground = false
    textView.isRichText = false
    textView.isEditable = true
    textView.font = Self.font
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
    textView.typingAttributes = TranscriptEditor.committedAttributes
    textView.textContainerInset = NSSize(width: 0, height: 0)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    // ⌘Z 用。HUD では VoxPanel が undo: を直接送る（HudEditCommand）。
    textView.allowsUndo = true
    coordinator.model.onFinishEditing = { [weak coordinator, weak textView] in
      guard let coordinator, let textView else { return }
      coordinator.finishEditing(textView)
    }
    // SwiftUIの再描画を待つ間の打鍵が、まだ表示していない音声を上書きしないようにする。
    coordinator.model.onTranscriptChange = { [weak coordinator, weak textView] in
      guard let coordinator, let textView else { return }
      coordinator.sync(textView)
    }
    coordinator.sync(textView)
    return scrollView
  }

  public func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    coordinator.sync(textView)

    if coordinator.focusToken != model.focusToken {
      coordinator.focusToken = model.focusToken
      coordinator.focusAttempts = 0
    }
    focusIfNeeded(textView, coordinator)
  }

  /// updateNSView は毎秒 15 回ほど走る。毎回 async を積むと main を溢れさせて
  /// CGEventTap がタイムアウトで落ちる。同期で、HUD を出すごとに回数を区切って試す。
  private func focusIfNeeded(_ textView: NSTextView, _ coordinator: Coordinator) {
    guard coordinator.focusAttempts < 5, let window = textView.window,
      window.firstResponder !== textView
    else { return }
    coordinator.focusAttempts += 1
    window.makeFirstResponder(textView)
  }

  static let font = NSFont.systemFont(ofSize: 14)
  /// 通常色（committed）と淡色（tentative）。この 2 つで編集可能域の境目を見せる。
  public static let committedAttributes: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor.labelColor
  ]
  public static let tentativeAttributes: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor.secondaryLabelColor
  ]

  @MainActor
  public final class Coordinator: NSObject, NSTextViewDelegate {
    let model: HudModel
    /// テキストビューに実際に入っている内容。モデルとの差分はここを基準に取る。
    private var buffer = TranscriptBuffer()
    /// `shouldChangeTextIn` で受理した変更。`textDidChange` で buffer に反映する。
    private var pendingEdit: (range: NSRange, text: String)?
    /// 自分で選択を戻している間の再入を止める。
    private var isAdjustingSelection = false
    /// T15。IME の変換中か。`model.isComposing` の元。sync / delegate で写す。
    private var isComposing = false
    private var resetToken = -1
    var focusAttempts = 0
    var focusToken = -1

    public init(model: HudModel) {
      self.model = model
    }

    // MARK: モデル → ビュー

    public func sync(_ textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      // 変換中の文字列と選択を守る。認識結果はモデルで保留し、変換確定後に適用する。
      guard !textView.hasMarkedText() else {
        setComposing(true)
        return
      }
      if isComposing || model.hasDeferredUpdates {
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
      }
      setComposing(false)

      let desired = model.transcript
      if resetToken != model.resetToken {
        resetToken = model.resetToken
        buffer = desired
        storage.setAttributedString(rendered(buffer))
        setSelection(textView, to: NSRange(location: buffer.caret, length: 0))
        return
      }

      let change = TranscriptCaret.replacement(current: buffer.text, desired: desired.text)
      guard change != nil || buffer.headEnd != desired.headEnd || buffer.tentativeEnd != desired.tentativeEnd else { return }
      let previous = buffer
      if let change {
        storage.replaceCharacters(in: change.range,
          with: attributed(change.text, TranscriptEditor.committedAttributes))
      }
      // 同じ文字が淡色から通常色へ変わる場合も、該当する区画だけを塗り直す。
      let start = min(previous.headEnd, desired.headEnd)
      let end = min(storage.length, max(previous.tentativeEnd + desired.length - previous.length, desired.tentativeEnd))
      if end > start {
        storage.setAttributes(TranscriptEditor.committedAttributes, range: NSRange(location: start, length: end - start))
      }
      if !desired.tentative.isEmpty {
        storage.setAttributes(TranscriptEditor.tentativeAttributes,
          range: NSRange(location: desired.headEnd, length: desired.tentativeEnd - desired.headEnd))
      }
      buffer = desired
      setSelection(textView, to: NSRange(location: buffer.caret, length: 0))
      textView.scrollRangeToVisible(NSRange(location: buffer.caret, length: 0))
      debugTrace(textView, storage: storage)
    }

    func finishEditing(_ textView: NSTextView) {
      if textView.hasMarkedText() { textView.unmarkText() }
      if isComposing || model.hasDeferredUpdates || !buffer.text.utf16.elementsEqual(textView.string.utf16) {
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
      }
      sync(textView)
    }

    /// 実機診断 (T12)。VOX_HUD_DEBUG=1 のとき、同期後のテキストビューの状態を stderr に出す。
    private func debugTrace(_ textView: NSTextView, storage: NSTextStorage) {
      guard ProcessInfo.processInfo.environment["VOX_HUD_DEBUG"] == "1" else { return }
      let frame = textView.frame
      let superFrame = textView.superview?.frame ?? .zero
      let scrollFrame = textView.enclosingScrollView?.frame ?? .zero
      let windowVisible = textView.window?.isVisible ?? false
      let hidden = textView.isHiddenOrHasHiddenAncestor
      let line =
        "hud_sync storage_length=\(storage.length) buffer_head=\(buffer.headEnd) "
        + "text_frame=\(Int(frame.width))x\(Int(frame.height)) clip_frame=\(Int(superFrame.width))x\(Int(superFrame.height)) "
        + "scroll_frame=\(Int(scrollFrame.width))x\(Int(scrollFrame.height)) window_visible=\(windowVisible) hidden=\(hidden) "
        + "color=\(textView.textColor?.description ?? "nil")\n"
      voxWrite(Data(line.utf8), to: .standardError)
    }

    // MARK: ビュー → モデル

    /// ユーザー起点の変更だけがここを通る（textStorage への差し込みは通らない）。
    /// 淡色域に掛かる変更は拒否する。`typed_chars` は変換確定時に `textDidChange` で数える。
    public func textView(
      _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      // T15。変換中は marked 範囲（committed 末尾からの n 文字）への置換を許可する。
      let isComposing = textView.hasMarkedText()
      let markedLength = isComposing ? textView.markedRange().length : 0
      guard buffer.canEdit(range: affectedCharRange, markedLength: markedLength) else {
        // T21。「文字が打てなくなった」の再発を検知するため、拒否した回を残す。
        logEditRejected(affectedCharRange)
        return false
      }
      let replacement = replacementString ?? ""
      // T13。`@` などの sigil はパレットの合図として食べる（文字としては入れない）。
      // 変換中の `@` は変換操作の一部なので合図にしない。
      switch SigilTrigger.classify(
        replacement: replacement, isRecording: model.isRecording,
        hasOption: NSEvent.modifierFlags.contains(.option),
        enabled: model.sigilTriggerEnabled && model.onSigil != nil,
        isComposing: isComposing) {
      case .open(let sigil):
        model.onSigil?(sigil, affectedCharRange.location)
        return false
      case .ignore:
        return false
      case .insertLiteral:
        break
      }
      // 変換中の受理は buffer に当てない（確定後の実文字列から取り直す）。
      pendingEdit = isComposing ? nil : (affectedCharRange, replacement)
      return true
    }

    public func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let wasComposing = isComposing
      let composing = textView.hasMarkedText()
      setComposing(composing)
      // T15。変換中は buffer もモデルも動かさない。marked text は committed に入れない。
      guard !composing else {
        pendingEdit = nil
        return
      }

      let beforeTyped = buffer.head.count + buffer.tail.count
      // 受理した編集を buffer に当てた回だけ、並びの食い違いを直す（想定外の経路の保険）。
      var appliedEdit = false
      if let edit = pendingEdit {
        pendingEdit = nil
        buffer.replace(range: edit.range, with: edit.text)
        model.typedCharacters += edit.text.count
        model.hadInput = true
        appliedEdit = true
      } else if let recovered = editableParts(of: textView.string) {
        // 変換の確定・取り消し（T15）、および shouldChangeTextIn を通らない経路（想定外）。
        // marked text が無くなった時点の実文字列から編集可能域（head / tail）を読み直す。
        buffer = TranscriptBuffer(
          head: recovered.head, tentative: buffer.tentative,
          tail: recovered.tail, caret: textView.selectedRange().location)
        // 変換確定で増えた分だけを typed_chars に数える（取り消しなら 0）。
        if wasComposing {
          let after = buffer.head.count + buffer.tail.count
          model.typedCharacters += max(0, after - beforeTyped)
          model.hadInput = true
        }
      }
      model.acceptEdit(buffer)
      textView.typingAttributes = TranscriptEditor.committedAttributes
      // ビューの並びが buffer とずれたら buffer を正として描き直す（3 区画の順を戻す）。
      if appliedEdit, textView.string != buffer.text, let storage = textView.textStorage {
        storage.setAttributedString(rendered(buffer))
        setSelection(textView, to: NSRange(location: buffer.caret, length: 0))
      }
    }

    /// caret の保護。選択が淡色域に掛かったら編集可能域に丸める（T17）。
    public func textViewDidChangeSelection(_ notification: Notification) {
      guard !isAdjustingSelection, let textView = notification.object as? NSTextView else { return }
      // T15。変換中の選択は IME のもの（marked 範囲の中を指す）。丸めない。
      guard !textView.hasMarkedText() else {
        setComposing(true)
        return
      }
      setComposing(false)
      // 打鍵の直後は選択の通知が `textDidChange` より先に来ることがある。その時点の buffer は
      // まだ打った文字を知らないので、丸めると caret が打った文字の**前**に戻ってしまう（T17）。
      // 長さが食い違っている間は触らない。buffer 側の caret は `replace` が入れる。
      guard (textView.string as NSString).length == buffer.length else { return }
      let range = textView.selectedRange()
      let clamped = buffer.clampSelection(range)
      if clamped != range {
        setSelection(textView, to: clamped)
      }
      buffer.setCaret(textView.selectedRange().location)
      model.setCaret(buffer.caret)
      textView.typingAttributes = TranscriptEditor.committedAttributes
    }

    // MARK: T20 ファイルのペースト

    /// `⌘V` でファイルが来たときの差し込み。パレットと同じ空白規則（`PaletteInsertion`）で入れる。
    /// caret が淡色の内部を指していたら全体の末尾に寄せる（T21。そこが次に打つ場所）。
    public func filePathInsertion(for value: String, selection: NSRange)
      -> (range: NSRange, text: String)? {
      guard !value.isEmpty else { return nil }
      let clamped = buffer.clampSelection(selection)
      let plan = PaletteInsertion.insert(value, into: buffer.text, at: clamped.location)
      guard !plan.inserted.isEmpty else { return nil }
      return (NSRange(location: plan.location, length: clamped.length), plan.inserted)
    }

    // MARK: 補助

    /// T21。編集を拒否した回を stderr に残す（`Vox` の `voxLog` と同じ行形式）。
    private func logEditRejected(_ range: NSRange) {
      let line =
        "edit_rejected range=\(range.location)+\(range.length) caret=\(buffer.caret) "
        + "head=\(buffer.headEnd) gray=\((buffer.tentative as NSString).length) "
        + "tail=\((buffer.tail as NSString).length)\n"
      voxWrite(Data(line.utf8), to: .standardError)
    }

    private func setComposing(_ value: Bool) {
      isComposing = value
      model.isComposing = value
      if value { model.hadInput = true }
    }

    private func setSelection(_ textView: NSTextView, to range: NSRange) {
      isAdjustingSelection = true
      textView.setSelectedRange(range)
      isAdjustingSelection = false
      buffer.setCaret(range.location)
      textView.typingAttributes = TranscriptEditor.committedAttributes
    }

    /// 実文字列から編集可能域を読み直す（T21）。淡色は 3 区画の真ん中なので、
    /// 淡色を含む「変わっていない側」の一致で境目を決める。
    /// - `tail` 側を打っていた: 先頭が `head + 淡色` のままで、残りが新しい `tail`
    /// - `head` 側を打っていた: 末尾が `淡色 + tail` のままで、その前が新しい `head`
    /// どちらとも読めないとき（淡色が壊れている）は nil を返してビューに触らない。
    private func editableParts(of string: String) -> (head: String, tail: String)? {
      let prefix = buffer.head + buffer.tentative
      let suffix = buffer.tentative + buffer.tail
      let fromTail: (head: String, tail: String)? =
        string.hasPrefix(prefix) ? (buffer.head, String(string.dropFirst(prefix.count))) : nil
      let fromHead: (head: String, tail: String)? =
        string.hasSuffix(suffix) && string.count >= suffix.count
        ? (String(string.dropLast(suffix.count)), buffer.tail) : nil
      if buffer.caret >= buffer.tentativeEnd {
        return fromTail ?? fromHead
      }
      return fromHead ?? fromTail
    }

    private func rendered(_ buffer: TranscriptBuffer) -> NSAttributedString {
      let result = NSMutableAttributedString(
        attributedString: attributed(buffer.head, TranscriptEditor.committedAttributes))
      result.append(attributed(buffer.tentative, TranscriptEditor.tentativeAttributes))
      result.append(attributed(buffer.tail, TranscriptEditor.committedAttributes))
      return result
    }

    private func attributed(_ text: String, _ attributes: [NSAttributedString.Key: Any])
      -> NSAttributedString {
      NSAttributedString(string: text, attributes: attributes)
    }
  }
}

/// T20。本文のテキストビュー。`⌘V` でファイルが来たら、そのパスをテキストとして入れる
/// （`NSTextView` の既定はファイルを読めずに何も起きない）。それ以外のペーストは素の挙動に任せる。
public final class TranscriptTextView: NSTextView {
  weak var coordinator: TranscriptEditor.Coordinator?
  /// why: 検査が利用者のクリップボードを読まないため（`save` の `store` と同じ理由）。
  var pasteboard = NSPasteboard.general

  public override func paste(_ sender: Any?) {
    guard let coordinator else {
      super.paste(sender)
      return
    }
    if let value = TranscriptFilePaste.pathText(
      from: pasteboard, repositoryRoot: coordinator.model.repositoryRoot),
      let insertion = coordinator.filePathInsertion(for: value, selection: selectedRange()) {
      // `insertText` は shouldChangeTextIn / textDidChange を通るので、
      // buffer と typed_chars は通常の打鍵と同じ経路で更新される。
      insertText(insertion.text, replacementRange: insertion.range)
      return
    }
    // ADR-017。クリップボードに画像だけがある回。ファイルに書いてからパスを入れる。
    switch TranscriptImagePaste.request(from: pasteboard) {
    case .image(let data, let kind): save(data, kind: kind, coordinator: coordinator)
    case .unsupported: coordinator.model.showAttachmentNotice(
        TranscriptImagePaste.unsupportedNotice)
    case nil: super.paste(sender)
    }
  }

  /// 書き込みが終わってからパスを入れる（本文にパスがあるならファイルがある、を保つ）。
  /// 確定はこの仕事を `awaitPendingAttachments()` で待つ。
  /// `store` を渡せるのは、検査が実際の保存先を触らないため（`Injector` の pasteboard と同じ理由）。
  func save(
    _ data: Data, kind: AttachmentImageKind, coordinator: TranscriptEditor.Coordinator,
    store: AttachmentStore = .standard
  ) {
    coordinator.model.trackAttachment { [weak self] in
      let outcome = await Task.detached { store.save(data, kind: kind) }.value
      guard !Task.isCancelled, let self, let coordinator = self.coordinator else { return }
      switch TranscriptImagePaste.result(
        for: outcome, repositoryRoot: coordinator.model.repositoryRoot,
        homeDirectory: NSHomeDirectory()) {
      case .insert(let path):
        // 選択は置き換えない。書き込みの間に選んだ文字を消さないため、長さ 0 の位置に入れる
        // （同期のファイルペーストは選択を置き換えるが、そちらは打鍵と同じ瞬間の操作）。
        let caret = NSRange(location: selectedRange().location, length: 0)
        guard let insertion = coordinator.filePathInsertion(for: path, selection: caret)
        else { return }
        self.insertText(insertion.text, replacementRange: insertion.range)
      case .notice(let message):
        coordinator.model.showAttachmentNotice(message)
      }
    }
  }
}

/// ADR-017。ペーストボードの画像を読み、保存の後始末を決める。形式の表と優先順は VoxCore。
enum TranscriptImagePaste {
  static let unsupportedNotice = "この形式の画像には対応していません"
  static let saveFailedNotice = "画像を保存できませんでした"

  enum Request: Equatable {
    case image(Data, AttachmentImageKind)
    /// 画像は載っているが、保存できる形式が無い。
    case unsupported
  }

  enum Result: Equatable {
    /// 本文に入れるパスの表記。保存が終わってからしか返らない。
    case insert(String)
    case notice(String)
  }

  /// テキストかファイルが同時にあるときは何も返さない（通常のペーストを壊さない）。
  static func request(from pasteboard: NSPasteboard) -> Request? {
    let types = pasteboard.types?.map(\.rawValue) ?? []
    guard !AttachmentPaste.carriesTextOrFiles(availableTypes: types) else { return nil }
    guard let kind = AttachmentPaste.imageKind(availableTypes: types) else {
      // 対応外でも画像が載っているかは AppKit に聞く（読める形式の一覧を自分で持たない）。
      return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        ? .unsupported : nil
    }
    // 型はあるのにデータが取れない（promise が撤回された）回は AppKit のペーストに任せる。
    guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(kind.pasteboardType))
    else { return nil }
    return .image(data, kind)
  }

  static func result(
    for outcome: AttachmentStore.SaveOutcome, repositoryRoot: String?, homeDirectory: String
  ) -> Result {
    switch outcome {
    case .saved(let path):
      .insert(
        FilePathFormat.display(
          path: path, repositoryRoot: repositoryRoot, homeDirectory: homeDirectory))
    case .failed: .notice(saveFailedNotice)
    }
  }
}

/// T20。ペーストボードからファイルのパスを読む。表記の決定は `FilePathFormat`。
public enum TranscriptFilePaste {
  /// ファイルが無いか、テキストが同時にあるときは nil（通常のペーストを壊さない）。
  /// 複数ファイルは半角空白区切り。
  public static func pathText(from pasteboard: NSPasteboard, repositoryRoot: String?) -> String? {
    if pasteboard.availableType(from: [.string, .rtf, .rtfd, .html]) != nil { return nil }
    guard pasteboard.availableType(from: [.fileURL]) != nil else { return nil }
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      !urls.isEmpty
    else { return nil }
    let text = FilePathFormat.insertion(
      paths: urls.map(\.path), repositoryRoot: repositoryRoot, homeDirectory: NSHomeDirectory())
    return text.isEmpty ? nil : text
  }
}
