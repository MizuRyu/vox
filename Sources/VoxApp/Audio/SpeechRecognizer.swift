import AVFoundation
import VoxCore

struct RecognitionUpdate {
  let text: String
  let isFinal: Bool
  var timings: [TimedText] = []
  var completesSentence = false
}

/// マイク・HUD・録音保存は SpeechLane が持ち、ここには認識に必要な音声だけを渡す。
@MainActor
protocol SpeechRecognizer: AnyObject {
  var onUpdate: ((RecognitionUpdate) -> Void)? { get set }
  var isSegmentFinalizePending: Bool { get }
  func start(onAssetInstallStarted: (() -> Void)?) async throws -> AVAudioFormat
  func append(_ buffer: AVAudioPCMBuffer) throws
  func finalizeSegment(reason: SegmentFinalizeReason) async
  func finish() async throws
  func abort() async
}
