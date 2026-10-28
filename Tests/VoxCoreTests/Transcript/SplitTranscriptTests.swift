// ADR-031。本文は本文用の認識器だけから作り、表示用の文字は本文が届くまで淡色に残す。

import Testing
import VoxCore

@Suite("Transcript: 表示用と本文用の認識器")
struct SplitTranscriptTests {
  @Test("表示用の final は本文にせず、淡色に残す")
  func displayFinalStaysTentative() {
    var transcript = SplitTranscript()
    transcript.acceptDisplay("ほんぶん", isFinal: false, endSeconds: 1)
    transcript.acceptDisplay("本文", isFinal: true, endSeconds: 1.2)
    transcript.acceptDisplay("つづき", isFinal: false, endSeconds: 2)
    #expect(transcript.committed == "")
    #expect(transcript.tentative == "本文つづき")
  }

  @Test("本文用の final が届いた区間の表示用は消え、本文用の文字が確定する")
  func committedFinalReplacesCoveredDisplay() {
    var transcript = SplitTranscript()
    transcript.acceptDisplay("一つ目", isFinal: true, endSeconds: 1)
    transcript.acceptDisplay("二つ目", isFinal: true, endSeconds: 3)
    transcript.acceptCommitted("ひとつめ", endSeconds: 1.1)
    #expect(transcript.committed == "ひとつめ")
    #expect(transcript.tentative == "二つ目", "本文がまだ届いていない区間は残る")
  }

  @Test("区切りが少しずれても、同じ区間の表示用は二重に残らない")
  func slightlyLaterDisplayFinalIsDropped() {
    var transcript = SplitTranscript()
    transcript.acceptCommitted("確定", endSeconds: 2)
    transcript.acceptDisplay("確定", isFinal: true, endSeconds: 2.3)
    #expect(transcript.tentative == "")
  }

  @Test("本文用が先に届いた後の表示用の final は淡色に足さない")
  func lateDisplayFinalForCommittedRangeIsIgnored() {
    var transcript = SplitTranscript()
    transcript.acceptDisplay("途中", isFinal: false, endSeconds: 1)
    transcript.acceptCommitted("途中で", endSeconds: 1.5)
    transcript.acceptDisplay("途中で", isFinal: true, endSeconds: 1.5)
    #expect(transcript.committed == "途中で")
    #expect(transcript.tentative == "", "volatile は表示用の final で消える")
  }

  @Test("本文用が終わりまで届いたら、淡色は空になり以後の表示用も足さない")
  func finishingClearsTentative() {
    var transcript = SplitTranscript()
    transcript.acceptDisplay("残り", isFinal: true, endSeconds: 5)
    transcript.acceptDisplay("のこ", isFinal: false, endSeconds: 6)
    transcript.acceptCommitted("全部", endSeconds: 4)
    transcript.finishCommitted()
    transcript.acceptDisplay("遅れて", isFinal: false, endSeconds: 7)
    #expect(transcript.committed == "全部")
    #expect(transcript.tentative == "")
  }

  @Test("本文は追記だけで伸びる")
  func committedIsAppendOnly() {
    var transcript = SplitTranscript()
    transcript.acceptCommitted("あ", endSeconds: 1)
    let first = transcript.committed
    transcript.acceptCommitted("い", endSeconds: 2)
    #expect(transcript.committed.hasPrefix(first))
    #expect(transcript.committed == "あい")
  }
}
