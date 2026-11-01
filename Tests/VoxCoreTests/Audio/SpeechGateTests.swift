import Testing
import VoxCore

@Suite("Speech gate: 無発話中の更新を止める")
struct SpeechGateTests {
  @Test("雑音だけなら認識せず、語頭の余白と末尾を含む発話区間だけを渡す")
  func speechAndSilence() {
    var gate = SpeechGate()
    gate.begin(windowStartFrame: 0)
    #expect(gate.recognitionRanges(regions: [], speakingFrom: nil, availableFrames: 8000) == nil)
    #expect(gate.recognitionRanges(regions: [], speakingFrom: 3200, availableFrames: 16000) == [3200..<16000])
    #expect(gate.recognitionRanges(regions: [3200..<15000], speakingFrom: nil, availableFrames: 32000) == [3200..<15000])
    #expect(gate.recognitionRanges(regions: [3200..<15000], speakingFrom: nil, availableFrames: 48000) == nil)
    #expect(gate.recognitionRanges(
      regions: [3200..<15000], speakingFrom: 50000, availableFrames: 64000) == [3200..<15000, 50000..<64000])
  }

  @Test("次の窓と次の録音へ発話判定を持ち越さない")
  func reset() {
    var gate = SpeechGate()
    gate.begin(windowStartFrame: 0)
    _ = gate.recognitionRanges(regions: [], speakingFrom: 0, availableFrames: 16000)
    gate.advance(to: 16000)
    gate.begin(windowStartFrame: 16000)
    #expect(gate.processedFrames == 0)
    #expect(gate.recognitionRanges(regions: [], speakingFrom: nil, availableFrames: 16000) == nil)
    #expect(gate.recognitionRanges(regions: [], speakingFrom: 0, availableFrames: 8000) == [0..<8000])
  }
}
