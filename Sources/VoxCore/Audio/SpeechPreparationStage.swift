public enum SpeechPreparationStage: Sendable, Equatable {
  case checkingFiles
  case downloading
  case loadingModel
  case startingCapture

  public var title: String {
    switch self {
    case .checkingFiles: "モデルを確認中"
    case .downloading: "モデルをダウンロード中"
    case .loadingModel: "モデルを読み込み中"
    case .startingCapture: "録音を開始中"
    }
  }

  public var detail: String {
    switch self {
    case .checkingFiles: "保存済みのファイルを確認しています。まだ録音していません。"
    case .downloading: "音声認識に必要なファイルを取得しています。まだ録音していません。"
    case .loadingModel: "音声認識モデルを読み込んでいます。まだ録音していません。"
    case .startingCapture: "準備ができると録音を開始します。まだ音声は取り込んでいません。"
    }
  }
}
