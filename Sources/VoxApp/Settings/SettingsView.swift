import AppKit
import SwiftUI
import VoxCore

public struct SettingsView: View {
  @ObservedObject private var model: SettingsModel
  private let onClose: () -> Void

  public init(model: SettingsModel, onClose: @escaping () -> Void = {}) {
    self.model = model
    self.onClose = onClose
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 12) {
          Image(systemName: "waveform")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
          VStack(alignment: .leading, spacing: 3) {
            Text("voxの設定").font(.title2.weight(.semibold))
          }
        }

        GroupBox {
          VStack(spacing: 16) {
            shortcutRow(
              "録音の開始と確定", detail: "押すたびに録音の開始と確定を切り替えます。",
              value: $model.toggleKey, override: model.overrides.toggle)
            Divider()
            shortcutRow(
              "ファイル検索", detail: "録音中にファイルのパスを本文に入れます。",
              value: $model.paletteKey, override: model.overrides.palette)
          }
          .padding(10)
        } label: {
          Text("ショートカット").font(.headline)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 5) {
            Toggle("貼り付け後にEnterを押す", isOn: $model.autoEnterEnabled)
              .disabled(model.loadFailed)
            Toggle(
              "ターミナルでもEnterを押す",
              isOn: $model.autoEnterUnverified)
              .disabled(model.loadFailed || !model.autoEnterEnabled)
            Text(autoEnterDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(10)
        } label: {
          Text("貼り付け").font(.headline)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            microphonePicker
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 3) {
                Text("macOSの既定入力")
                  .font(.caption).foregroundStyle(.secondary)
                Text(defaultMicrophoneName)
                  .font(.body.weight(.medium))
                  .lineLimit(1).truncationMode(.middle)
                  .help(defaultMicrophoneName)
              }
              Spacer(minLength: 12)
              Button("更新") { model.refreshMicrophones() }
            }

            Divider()
            Text("接続中の入力デバイス")
              .font(.caption).foregroundStyle(.secondary)
            microphoneList

            Divider()
            Toggle("通話向けの音声処理（実験的）", isOn: $model.voiceProcessingEnabled)
              .disabled(model.loadFailed)
            Text("再生中の音楽が小さくなることがあります。音楽やほかの人の声は完全には分けられません。次の録音から反映されます。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(10)
        } label: {
          Text("マイク").font(.headline)
        }

        GroupBox {
          DictionaryEditor(model: model).padding(10)
        } label: {
          Text("辞書").font(.headline)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("キー表示をクリックして、新しい組み合わせを押します。")
          Text("録音中の変更は次の録音から反映されます。Escで取り消せます。")
          if model.overrides.toggle != nil || model.overrides.palette != nil {
            Text("起動引数で指定したキーは、その起動中は変更できません。")
          }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if let error = model.errorMessage {
          Label(error, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if let message = model.savedMessage {
          Label(message, systemImage: "checkmark.circle")
            .font(.callout).foregroundStyle(.secondary)
        }

        HStack {
          Button("初期値に戻す") { model.resetDraft() }
            .disabled(model.loadFailed)
          if model.loadFailed || model.errorMessage != nil {
            Button("再読み込み") { model.reload() }
          }
          Spacer()
          Button("閉じる", action: onClose).keyboardShortcut(.cancelAction)
          Button("保存") { model.save() }
            .keyboardShortcut(.defaultAction)
            .disabled(model.loadFailed)
        }
      }
      .padding(24)
    }
    .frame(width: 520)
  }

  private var autoEnterDescription: String {
    model.autoEnterUnverified
      ? "貼り付けた内容を読み取れないアプリでは、同じウィンドウのまま0.5秒待ってから押します。コマンドの実行になる場合があります。"
      : "貼り付けた内容を入力欄で確認できたときだけEnterを押します。アプリによっては送信になります。"
  }

  private var defaultMicrophoneName: String {
    guard case .available(let devices, let defaultDeviceID) = model.microphoneSnapshot else {
      return "取得できませんでした"
    }
    guard let defaultDeviceID else { return "確認できません" }
    return devices.first(where: { $0.id == defaultDeviceID })?.name ?? "名前を取得できません"
  }

  private var selectableMicrophones: [MicrophoneDevice] {
    guard case .available(let devices, _) = model.microphoneSnapshot else { return [] }
    return devices.filter { $0.uid?.isEmpty == false }
  }

  private var microphonePicker: some View {
    VStack(alignment: .leading, spacing: 5) {
      Picker("使用するマイク", selection: $model.microphoneInput) {
        Text("自動").tag(MicrophoneInput.automatic)
        Text("macOSの既定").tag(MicrophoneInput.systemDefault)
        ForEach(selectableMicrophones) { device in
          if let uid = device.uid {
            Text(device.name).tag(MicrophoneInput.device(uid))
          }
        }
        if case .device(let uid) = model.microphoneInput,
          !selectableMicrophones.contains(where: { $0.uid == uid }) {
          Text("指定したマイク（未接続）").tag(model.microphoneInput)
        }
      }
      .disabled(model.loadFailed)
      Text("自動では、既定の入出力がBluetoothで再生中のとき、内蔵マイクがあれば使用します。macOSの設定は変更しません。")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if case .device = model.microphoneInput {
        Text("指定したマイクが未接続のときは録音を開始しません。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var microphoneList: some View {
    switch model.microphoneSnapshot {
    case .unavailable:
      Text("マイクの情報を取得できませんでした。「更新」で再取得できます。")
        .font(.callout).foregroundStyle(.secondary)
    case .available(let devices, let defaultDeviceID):
      if devices.isEmpty {
        Text("入力デバイスが見つかりません。接続してから「更新」を押してください。")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(devices) { device in
              HStack(spacing: 8) {
                Image(systemName: device.id == defaultDeviceID ? "checkmark.circle.fill" : "mic")
                  .foregroundStyle(
                    device.id == defaultDeviceID ? Color.accentColor : Color.secondary
                  )
                  .frame(width: 18)
                Text(device.name)
                  .lineLimit(1).truncationMode(.middle)
                  .help(device.name)
                if let transport = device.transport.displayLabel {
                  Text(transport).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
              }
            }
          }
          .padding(.vertical, 2)
        }
        .frame(maxHeight: 120)
      }
    }
  }

  private func shortcutRow(
    _ title: String, detail: String, value: Binding<String>, override: String?
  ) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      ShortcutRecorder(value: value, override: override, label: title) { error in
        model.errorMessage = error
        model.savedMessage = nil
      }
      .frame(width: 152, height: 30)
      .disabled(model.loadFailed || override != nil)
    }
  }
}

/// 辞書の表（ADR-021）。セルの確定（Enter またはフォーカスを外す）ごとにファイルへ書く。
private struct DictionaryEditor: View {
  private struct Row: Identifiable {
    let id: Int
    let entry: DictionaryEntry
  }

  @ObservedObject var model: SettingsModel
  @State private var selection: Int?
  @State private var focusRequest: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("認識された表記を、入れたい表記に置き換えます。Enterを押すか別の欄に移ると保存し、次の録音から反映されます。")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Table(rows, selection: $selection) {
        TableColumn("認識される表記") { row in
          DictionaryCell(title: "認識される表記", text: row.entry.from, autofocus: autofocus(row)) {
            model.updateDictionaryEntry(
              at: row.id, replacing: row.entry, from: $0, to: row.entry.to)
          }
        }
        TableColumn("入れたい表記") { row in
          DictionaryCell(title: "入れたい表記", text: row.entry.to, autofocus: .constant(false)) {
            model.updateDictionaryEntry(
              at: row.id, replacing: row.entry, from: row.entry.from, to: $0)
          }
        }
      }
      .frame(height: tableHeight)
      .disabled(!model.dictionaryEditable)
      HStack {
        Button("追加") {
          model.addDictionaryEntry()
          selection = nil
          focusRequest = model.dictionaryEntries.count - 1
        }
        .disabled(!model.dictionaryEditable)
        Button("削除") {
          guard let selection else { return }
          self.selection = nil
          model.removeDictionaryEntry(at: selection)
        }
        .disabled(!model.dictionaryEntries.indices.contains(selection ?? -1))
        Spacer(minLength: 12)
        Button("辞書ファイルを開く") { model.openDictionaryFile() }
        Button("更新") { model.refreshDictionary() }
      }
      Text(model.dictionaryMessage).font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// 「追加」で足した行の左のセルだけが、表示されたときに 1 度フォーカスを取る。
  private func autofocus(_ row: Row) -> Binding<Bool> {
    Binding(get: { focusRequest == row.id }, set: { if !$0 { focusRequest = nil } })
  }

  private var rows: [Row] {
    model.dictionaryEntries.enumerated().map { Row(id: $0.offset, entry: $0.element) }
  }

  /// why: 行数に合わせて伸ばし、8行を超えたら表の中でスクロールする。
  private var tableHeight: CGFloat {
    CGFloat(min(max(model.dictionaryEntries.count, 2), 8)) * 24 + 28
  }
}

/// 1 つのセル。打ち込み中の文字はセルが持ち、確定したときだけ設定に渡す。
/// 保存できなかった文字はそのまま残る（ADR-021 の打ち込み途中の行）。
private struct DictionaryCell: View {
  let title: String
  let text: String
  @Binding var autofocus: Bool
  let commit: (String) -> Void
  @State private var draft: String
  @FocusState private var focused: Bool

  init(title: String, text: String, autofocus: Binding<Bool>, commit: @escaping (String) -> Void) {
    self.title = title
    self.text = text
    _autofocus = autofocus
    self.commit = commit
    _draft = State(initialValue: text)
  }

  var body: some View {
    TextField(title, text: $draft)
      .textFieldStyle(.plain)
      .focused($focused)
      .onSubmit(save)
      .onChange(of: focused) { _, focused in
        if !focused { save() }
      }
      // why: 保存や「更新」・削除で行の中身が変わったら、打ち込み中の文字を表示中の値に揃える。
      .onChange(of: text) { _, text in draft = text }
      .onAppear {
        guard autofocus else { return }
        autofocus = false
        focused = true
      }
  }

  private func save() {
    guard draft != text else { return }
    commit(draft)
  }
}

private struct ShortcutRecorder: NSViewRepresentable {
  @Binding var value: String
  let override: String?
  let label: String
  let onError: (String?) -> Void

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton(frame: .zero)
    button.bezelStyle = .rounded
    button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    return button
  }

  func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
    button.value = override ?? value
    button.isEnabled = context.environment.isEnabled
    button.setAccessibilityLabel(label + "のショートカット")
    button.onChange = { value = $0 }
    button.onError = onError
    button.refreshTitle()
  }
}

private final class ShortcutRecorderButton: NSButton {
  var value = ""
  var onChange: ((String) -> Void)?
  var onError: ((String?) -> Void)?
  private var recording = false
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    target = self
    action = #selector(beginRecording)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func beginRecording() {
    guard isEnabled, window?.makeFirstResponder(self) == true else { return }
    recording = true
    onError?(nil)
    refreshTitle()
  }

  func refreshTitle() {
    title = recording ? "キーを押す" : ((try? HotkeyBinding.parse(value).label) ?? value)
    setAccessibilityValue(title)
  }

  override func resignFirstResponder() -> Bool {
    recording = false
    refreshTitle()
    return super.resignFirstResponder()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard recording else {
      super.keyDown(with: event)
      return
    }
    guard !event.isARepeat else { return }
    if event.keyCode == 53 {
      recording = false
      refreshTitle()
      return
    }
    do {
      let flags = event.modifierFlags
      let binding = try HotkeyBinding.recorded(
        keyCode: Int64(event.keyCode),
        command: flags.contains(.command), shift: flags.contains(.shift),
        control: flags.contains(.control), option: flags.contains(.option))
      value = binding.spec
      recording = false
      onChange?(value)
      onError?(nil)
      refreshTitle()
    } catch {
      onError?(error.localizedDescription)
    }
  }
}
