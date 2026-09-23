import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// 入力専用 AUHAL で指定の機器から録音する（ADR-016）。
/// AVAudioEngine は既定の入出力をまとめた集約デバイスで開くため、Bluetooth ヘッドセットが既定だと
/// 通話用プロファイルへ切り替わり音楽が止まる。出力を持たない AUHAL で選んだ機器だけを開く。
final class HALInputCapture: @unchecked Sendable {
  let format: AVAudioFormat
  private let unit: AudioUnit
  private let deviceID: AudioObjectID
  private let builder: AsyncStream<BufferBox>.Continuation
  private let levels: AudioLevelTracker
  private let onInterrupted: @Sendable () -> Void
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var isStopped = false

  /// 開始まで行う。失敗したら作った Audio Unit を片付けてから投げる。
  init(
    deviceID: AudioObjectID, builder: AsyncStream<BufferBox>.Continuation,
    levels: AudioLevelTracker, onInterrupted: @escaping @Sendable () -> Void
  ) throws {
    let unit = try Self.makeUnit()
    let format: AVAudioFormat
    do {
      try AudioInputConfiguration.prepare(CoreAudioInputUnit(unit), deviceID: deviceID, route: .inputOnly)
      format = try Self.applyClientFormat(to: unit)
    } catch {
      AudioComponentInstanceDispose(unit)
      throw error
    }
    self.unit = unit
    self.format = format
    self.deviceID = deviceID
    self.builder = builder
    self.levels = levels
    self.onInterrupted = onInterrupted
    do {
      try installCallback()
      try Self.check(AudioUnitInitialize(unit))
      try Self.check(AudioOutputUnitStart(unit))
      try AudioInputConfiguration.validate(CoreAudioInputUnit(unit), deviceID: deviceID, route: .inputOnly)
    } catch {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
      throw error
    }
    watchDevice()
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    for (address, block) in listeners {
      var address = address
      AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
    }
    listeners = []
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
  }

  private static func makeUnit() throws -> AudioUnit {
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw AudioInputConfigurationError.missingUnit
    }
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &unit))
    guard let unit else { throw AudioInputConfigurationError.missingUnit }
    return unit
  }

  /// 機器側の形式（入力 element 1 の入力 scope）のレートとチャンネル数で、float32 非インターリーブを受け取る。
  private static func applyClientFormat(to unit: AudioUnit) throws -> AVAudioFormat {
    var hardware = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
    guard let format = clientFormat(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) else {
      throw SpeechLaneError.noAudioInputDevice
    }
    var client = format.streamDescription.pointee
    try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size))
    return format
  }

  static func clientFormat(sampleRate: Double, channels: UInt32) -> AVAudioFormat? {
    // 3ch 以上はレイアウトがないと作れない。モノラル化は変換側で全チャンネル平均する。
    guard sampleRate > 0, channels > 0,
      let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
    else { return nil }
    return AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
  }

  private func installCallback() throws {
    var callback = AURenderCallbackStruct(
      inputProc: { refCon, flags, timeStamp, bus, frames, _ in
        Unmanaged<HALInputCapture>.fromOpaque(refCon).takeUnretainedValue()
          .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
      },
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try Self.check(AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
      UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
  }

  /// IO スレッドから呼ばれる。受け取った分を tap と同じ `BufferBox` で流す。
  private func render(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32, frames: UInt32
  ) -> OSStatus {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
    buffer.frameLength = frames
    let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
    guard status == noErr else { return status }
    levels.accept(rms: SpeechLane.rms(of: buffer), atMilliseconds: voxNowMilliseconds())
    builder.yield(BufferBox(buffer: buffer))
    return noErr
  }

  /// 機器が外れた、または形式が変わったら録音の終わりとして上へ渡す（AVAudioEngine の構成変更と同じ扱い）。
  private func watchDevice() {
    for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      let block: AudioObjectPropertyListenerBlock = { [onInterrupted] _, _ in onInterrupted() }
      guard AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr else { continue }
      listeners.append((address, block))
    }
  }

  private static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw AudioInputConfigurationError.propertyFailed(status) }
  }
}
