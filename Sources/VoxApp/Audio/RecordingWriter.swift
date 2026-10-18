// 録音 1 回分の wav と JSON を書く（ADR-026）。呼ぶのは main actor、書くのは直列キュー。
// why: main で I/O すると CGEventTap がタイムアウトする（仕様 03「実装上の落とし穴」）。

import AVFoundation
import Foundation
import VoxCore

final class RecordingWriter: @unchecked Sendable {
  /// 1 回の録音で書く上限。超えた分は捨てて `truncated` を残す。
  static let maximumSeconds = 30.0 * 60

  let wav: URL
  let json: URL
  /// 全録音で 1 本。終了時に `drain()` で書き終わりを待てるように共有する。
  private static let queue = DispatchQueue(label: "local.vox.recording-writer")
  // 以下は queue の中だけで触る。
  private var file: AVAudioFile?
  private var format: AVAudioFormat?
  private var frames: Int64 = 0
  private var truncated = false
  private var failed = false
  private var closed = false

  init(wav: URL, json: URL) {
    self.wav = wav
    self.json = json
  }

  /// それまでに頼んだ書き込み・削除が終わるまで待つ。終了の前に呼ぶ（途中の wav や空の JSON を残さない）。
  static func drain() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }

  /// analyzer に渡したバッファを写して書く。渡した側はこの後もバッファを使ってよい。
  func append(_ buffer: AVAudioPCMBuffer) {
    guard let copy = Self.copy(buffer) else { return }
    let box = BufferBox(buffer: copy)
    Self.queue.async { self.write(box.buffer) }
  }

  /// wav を閉じて JSON を書く。`make` は wav の形式を受け取って JSON の中身を作る。
  func finish(_ make: @escaping @Sendable (RecordingSidecar.Audio?) -> RecordingSidecar) {
    Self.queue.async {
      guard !self.closed else { return }
      self.closed = true
      let audio = self.audioSummary()
      self.file = nil
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try PrivateFileIO.write(try encoder.encode(make(audio)), to: self.json)
        voxLog("recording_saved frames=\(audio?.frames ?? 0) truncated=\(audio?.truncated ?? false)")
      } catch {
        voxLog("recording_save_failed \(String(describing: error))")
      }
    }
  }

  /// 残さない回。書きかけの wav と押さえた JSON を消す。`finish` の後なら何もしない。
  func discard() {
    Self.queue.async {
      guard !self.closed else { return }
      self.closed = true
      self.file = nil
      try? FileManager.default.removeItem(at: self.wav)
      try? FileManager.default.removeItem(at: self.json)
    }
  }

  private func write(_ buffer: AVAudioPCMBuffer) {
    guard !closed, !failed, !truncated else { return }
    do {
      let file = try self.file ?? open(buffer.format)
      let limit = Int64(Self.maximumSeconds * buffer.format.sampleRate)
      guard frames + Int64(buffer.frameLength) <= limit else {
        truncated = true
        return
      }
      try file.write(from: buffer)
      frames += Int64(buffer.frameLength)
    } catch {
      failed = true
      voxLog("recording_write_failed \(String(describing: error))")
    }
  }

  private func open(_ format: AVAudioFormat) throws -> AVAudioFile {
    let file = try AVAudioFile(
      forWriting: wav, settings: format.settings, commonFormat: format.commonFormat,
      interleaved: format.isInterleaved)
    // AVAudioFile は作り直したファイルの権限を既定に戻しうる。押さえた 0600 に揃え直す。
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wav.path)
    self.file = file
    self.format = format
    return file
  }

  private func audioSummary() -> RecordingSidecar.Audio? {
    guard let format, !failed else { return nil }
    return RecordingSidecar.Audio(
      file: wav.lastPathComponent, sampleRate: format.sampleRate,
      channels: Int(format.channelCount), frames: frames, truncated: truncated)
  }

  private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard source.frameLength > 0,
      let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
    else { return nil }
    copy.frameLength = source.frameLength
    let from = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: source.audioBufferList))
    let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (target, origin) in zip(to, from) {
      guard let destination = target.mData, let data = origin.mData else { return nil }
      memcpy(destination, data, Int(min(target.mDataByteSize, origin.mDataByteSize)))
    }
    return copy
  }
}
