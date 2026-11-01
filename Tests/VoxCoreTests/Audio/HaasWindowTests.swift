import Foundation
import Testing
import VoxCore

@Suite("Haas: 音声の分割")
struct HaasWindowTests {
  @Test("12秒の直前にある静かな位置を選び、境界の前後に全フレームを残す")
  func quietBoundaryPreservesAudio() {
    var samples = [Int16](repeating: 10000, count: 14 * 16000)
    for index in (11 * 16000)..<(11 * 16000 + 320) { samples[index] = 0 }
    let input = samples.withUnsafeBytes { Data($0) }
    var window = HaasAudioWindow()
    window.append(input)
    let cut = window.quietCutFrames()
    #expect(cut >= 11 * 16000 && cut < 11 * 16000 + 320)
    let prefix = window.prefix(frames: cut)
    window.consume(frames: cut)
    #expect(prefix + window.pcm == input)
    #expect(window.startFrame == cut)
    #expect(window.endFrame == samples.count)
  }

  @Test("短い入力と空入力は長さを変えない")
  func shortAndEmpty() {
    var window = HaasAudioWindow()
    #expect(window.quietCutFrames() == 0)
    window.append(Data(repeating: 0, count: 320))
    #expect(window.quietCutFrames() == 160)
    window.consume(frames: 160)
    #expect(window.frameCount == 0)
    #expect(window.startFrame == 160 && window.endFrame == 160)
  }

  @Test("すでに表示した音声より前には区切りを戻さない")
  func cutAfterDisplayedAudio() {
    var window = HaasAudioWindow()
    window.append(Data(repeating: 0, count: 13 * 32000))
    let displayed = 11 * 16000 + 8000
    #expect(window.quietCutFrames(minimumFrames: displayed) >= displayed)
    #expect(window.quietCutFrames(minimumFrames: 12 * 16000 - 100) == 12 * 16000)
  }
}
