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
  /// T21。淡色が**出た後に**打った文字（`trailing` から改名し、意味も淡色の前から後ろへ反転した）。
  /// 次の淡色が始まるときに `head` へ合流する（`applyTentative`）。final では動かない。
  @Published public var tail = ""
  /// 中段をテキストの代わりに占める通知（挿入確認の失敗など）。
  @Published public var notice: String?
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
    TranscriptBuffer(head: head, tentative: tentative, tail: tail)
  }

  /// T18。右上のボタン。展開状態を反転して覚え、パネル側に高さの引き直しを頼む。
  public func toggleExpanded() {
    isExpanded.toggle()
    UserDefaults.standard.set(isExpanded, forKey: HudModel.expandedKey)
    onExpandedChange?()
  }

  /// T21。音声の final。`head` の末尾に足すだけで、`tail`（打った文字）は動かさない。
  /// 区画の決め方は `TranscriptBuffer` に任せる（ビューは差分の当て方だけを見る）。
  public func commitFinal(_ suffix: String) {
    guard !suffix.isEmpty else { return }
    var buffer = transcript
    buffer.commitFinal(suffix)
    head = buffer.head
    tail = buffer.tail
    // 淡色はその場で通常色の final に置き換わる（`head` に入った）。
    tentative = buffer.tentative
  }

  /// T21。淡色の更新。空 → 非空になるときだけ `tail` を `head` に合流させる
  /// （打った文字は「その後に喋った音声」より前に確定する）。直接代入せずここを通す。
  public func applyTentative(_ text: String) {
    var buffer = transcript
    buffer.applyTentative(text)
    head = buffer.head
    tail = buffer.tail
    tentative = buffer.tentative
  }

  /// 3 区画をまとめて空にする（HUD を出し直すとき。前の回の本文を持ち越さない）。
  public func clearText() {
    head = ""
    tentative = ""
    tail = ""
  }

  /// パレットの確定。`plan.location` は全文のオフセット（T17）。
  /// どの区画に入るかは `TranscriptBuffer` の規則に任せ、ビューには差分の当て方を渡す。
  public func requestInsertion(_ plan: PaletteInsertionPlan) {
    guard !plan.inserted.isEmpty else { return }
    var buffer = transcript
    guard buffer.insertTyped(plan.inserted, at: plan.location) else { return }
    pendingInsertion = plan
    head = buffer.head
    tail = buffer.tail
    insertionToken += 1
  }
}

/// 本文のテキストビュー。head + tentative + tail を 1 本のテキストとして描く（T21）。
///
/// **ビュー側を壊さないことが最優先**。SwiftUI の再描画は波形の更新で毎秒 15 回ほど走るので、
/// モデルの値でビューを全置換するとユーザーが打った文字が消える。
/// 差分だけを textStorage に当てる:
/// - final: 淡色域 `[headEnd, tentativeEnd)` を通常色の final で差し替える（`tail` は動かない）
/// - tentative: 古い淡色を消し、新しい淡色を `headEnd` に入れる（合流した回は `tail` の後ろになる）
/// - tail: 淡色の後ろに通常色で残る（ユーザーが打った分。打鍵以外では触らない）
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
    // ⌘Z 用。Edit メニュー (main.swift) と組で効く。
    textView.allowsUndo = true
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

  private static let font = NSFont.systemFont(ofSize: 14)
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
    private var insertionToken = 0
    var focusAttempts = 0
    var focusToken = -1

    public init(model: HudModel) {
      self.model = model
    }

    // MARK: モデル → ビュー

    public func sync(_ textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      // T15。IME の変換中は何も当てない。未確定文字列は committed 末尾に置かれるので、
      // その直後の淡色域を差し替えると変換中の文字列と選択が壊れる。保留分はモデルに溜まっており、
      // 変換が終わった次の sync（波形更新で毎秒 15 回来る）で一括で当たる。
      guard !textView.hasMarkedText() else {
        setComposing(true)
        return
      }
      setComposing(false)

      if resetToken != model.resetToken {
        resetToken = model.resetToken
        insertionToken = model.insertionToken
        buffer = model.transcript
        storage.setAttributedString(rendered(buffer))
        setSelection(textView, to: NSRange(location: buffer.caret, length: 0))
        return
      }

      var changed = false
      // T13 パレットの差し込み。全文のオフセットに入るので音声の final の追記とは別に当てる。
      // final より先に当てる（final はこの後、淡色域を置き換えて入る）。
      if insertionToken != model.insertionToken {
        insertionToken = model.insertionToken
        if let plan = model.pendingInsertion {
          // ビューが追いついていない場合に備えて編集可能域に丸める（淡色の内部なら全体の末尾に寄る）。
          let location = buffer.clampCaret(plan.location)
          buffer.replace(range: NSRange(location: location, length: 0), with: plan.inserted)
          storage.replaceCharacters(
            in: NSRange(location: location, length: 0),
            with: attributed(plan.inserted, TranscriptEditor.committedAttributes))
          changed = true
        }
      }

      if let suffix = TranscriptCaret.pendingSuffix(current: buffer.head, desired: model.head) {
        // T21。final は淡色域をそのまま置き換える（`tail` は動かない）。
        // ただしモデル側で `tail` が `head` に合流していることがある（新しい淡色が始まった回）。
        // 合流はモデルでは final の**後**に起きる（`head += final` → `head += tail`）ので、
        // 合流した回の suffix は「final + tail」で終わりが `tail`。その分を落とす。
        let merged =
          !buffer.tail.isEmpty && model.tail.isEmpty && suffix.hasSuffix(buffer.tail)
        let voice = merged ? String(suffix.dropLast(buffer.tail.count)) : suffix
        if !voice.isEmpty {
          let dim = NSRange(
            location: buffer.headEnd, length: (buffer.tentative as NSString).length)
          buffer.commitFinal(voice)
          storage.replaceCharacters(
            in: dim, with: attributed(voice, TranscriptEditor.committedAttributes))
          changed = true
        }
        // `tail` の合流そのものはビューでは文字が動かない（この後の淡色の更新で buffer も合流する）。
      }
      // 分岐している（ユーザーが途中を編集した）ときはビューに触らない。

      if model.tentative != buffer.tentative {
        // 古い淡色を消してから、新しい淡色を `headEnd` に入れる。合流した回は `headEnd` が
        // `tail` の後ろまで進んでいるので、この 2 段でしか正しい位置に置けない。
        let previous = NSRange(
          location: buffer.headEnd, length: (buffer.tentative as NSString).length)
        buffer.applyTentative(model.tentative)
        storage.replaceCharacters(in: previous, with: "")
        storage.replaceCharacters(
          in: NSRange(location: buffer.headEnd, length: 0),
          with: attributed(model.tentative, TranscriptEditor.tentativeAttributes))
        changed = true
      }

      guard changed else { return }
      setSelection(textView, to: NSRange(location: buffer.caret, length: 0))
      // caret が淡色の直前なら流れ込む先を、途中を打っているならその手元を見せる。
      let visible = buffer.caret == buffer.headEnd ? buffer.length : buffer.caret
      textView.scrollRangeToVisible(NSRange(location: visible, length: 0))
      debugTrace(textView, storage: storage)
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

      let before = buffer.head
      let beforeTyped = buffer.head.count + buffer.tail.count
      // 受理した編集を buffer に当てた回だけ、並びの食い違いを直す（想定外の経路の保険）。
      var appliedEdit = false
      if let edit = pendingEdit {
        pendingEdit = nil
        buffer.replace(range: edit.range, with: edit.text)
        model.typedCharacters += edit.text.count
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
        }
      }
      // T15。変換中はモデルにだけ音声の final が溜まる（sync を止めているので view には無い）。
      // 打った文字でモデルを上書きすると溜まった分が消えるので、head 末尾に付いた分は残す。
      // 次の sync が pendingSuffix としてビューに当てる。
      let pendingVoice =
        model.head.hasPrefix(before) ? String(model.head.dropFirst(before.count)) : ""
      model.head = buffer.head + pendingVoice
      // T21。溜まった分の末尾には、新しい淡色が始まって `head` に合流した `tail` が入っている
      // （モデルは `head += final` → `head += tail` の順で積む）。その分を落としてから書き戻す
      // （そのまま書き戻すと同じ文字が `head` と `tail` に二重に載る）。
      let mergedTyped = pendingVoice.hasSuffix(buffer.tail) && !buffer.tail.isEmpty
      model.tail = mergedTyped ? "" : buffer.tail
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

  public override func paste(_ sender: Any?) {
    guard let coordinator,
      let value = TranscriptFilePaste.pathText(
        from: NSPasteboard.general, repositoryRoot: coordinator.model.repositoryRoot),
      let insertion = coordinator.filePathInsertion(for: value, selection: selectedRange())
    else {
      super.paste(sender)
      return
    }
    // `insertText` は shouldChangeTextIn / textDidChange を通るので、
    // buffer と typed_chars は通常の打鍵と同じ経路で更新される。
    insertText(insertion.text, replacementRange: insertion.range)
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
