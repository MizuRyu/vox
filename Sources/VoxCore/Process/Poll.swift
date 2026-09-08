import Foundation

public enum VoxPoll {
  /// 条件が立つか期限が過ぎるまで待つ。刻み幅は待つものごとに違うので呼び出し側が渡す。
  /// 時計も呼び出し側のもの（`deadline` と同じ尺度で読めるのは呼び出し側だけ）。
  /// `isolation` は条件と時計を呼び出し側の隔離のまま読むために要る（渡す値は無い）。
  public static func wait(
    until condition: () -> Bool, deadline: Double, step: Duration, now: () -> Double,
    isolation: isolated (any Actor)? = #isolation
  ) async {
    while !condition(), now() < deadline {
      // 取り消されたら待つのをやめる。sleep が即返るだけの空回りで期限まで回らない。
      do { try await Task.sleep(for: step) } catch { return }
    }
  }
}
