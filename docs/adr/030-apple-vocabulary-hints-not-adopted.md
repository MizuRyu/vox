# ADR-030: Apple の語彙指定（contextualStrings・カスタム言語モデル）は入れず、SpeechTranscriber のままにする

- 状態: **提案**（2026-10-28）
- 関連: [ADR-018](018-no-engine-switch.md)（エンジンを切り替えない）、[ADR-026](026-debug-recording-save.md)（デバッグ録音）、[ADR-008](008-reference-text-convention.md)（正解テキスト）、[02 音声エンジン](../specs/02-speech-engines.md)、[05 テキスト後処理](../specs/05-text-postprocessing.md)

## 文脈

[ADR-018](018-no-engine-switch.md) と仕様 02 / 05 は「Apple には語彙バイアスの公開 API が無い」を前提にしていた。
macOS 26.5 SDK の `Speech` を読み直すと、語彙を渡す口は 2 つある。

- `AnalysisContext.contextualStrings`: `SpeechAnalyzer` に渡す文脈。どの認識器にも渡せる。Apple の文書は `DictationTranscriber` の節でだけ説明している
- `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)`: `SFCustomLanguageModelData`（語句の頻度・テンプレート・発音）から作るカスタム言語モデル。**`SpeechTranscriber` には渡す口が無い**（`contentHints` を持たない）

ja-JP では両方の認識器が使え、カスタム言語モデルも作れた。効くかどうかは測らないと決められない。
また ADR-018 の見直しの条件である「Apple の日本語 CER」も未測定のままだった。

## 測定

デバッグ録音（ADR-026）を材料に、本体を起動せずオフラインで測った。

- 録音: 保存済みの 451 本（約 328 分）から決まった乱数で 100 本。認識は `SpeechAnalyzer.analyzeSequence(from:)` で、実時間を待たずにファイルを渡す
- 設定: SpeechTranscriber（本体と同じ ja-JP）、+ contextualStrings、DictationTranscriber、+ contextualStrings、+ カスタム言語モデル の 5 通り
- 渡した語: 150 語。辞書の右辺と、エージェントへの打鍵でよく打つ英字の語。録音の本文からは取らない
- 正解: 先頭 40 本（9,468 字）。音声は聞かず、5 通りの出力と本体の履歴（認識の生テキスト、HUD で直した本文）をエージェントが突き合わせて決めた。SpeechTranscriber の出力を土台に、誤りと判断した箇所だけを直した
- 採点: ベンチの CER と同じ正規化（NFKC、空白と句読点を除く。ADR-008）。辞書の置換を正解と出力の両方にかける

| 比較（100 本） | 出力が変わった録音 |
|---|---|
| SpeechTranscriber に contextualStrings | 0 |
| DictationTranscriber に contextualStrings | 2 |
| DictationTranscriber にカスタム言語モデル | 13 |

| 設定（40 本） | CER | 言いよどみを両方から除いた CER | 誤り（置換 / 脱落 / 挿入） |
|---|---|---|---|
| 本体のライブ認識（SpeechTranscriber） | 3.04% | 3.07% | 138 / 115 / 35 |
| SpeechTranscriber（ファイル） | 0.95% | 1.00% | 56 / 27 / 7 |
| + contextualStrings | 0.95% | 1.00% | — |
| DictationTranscriber | 17.14% | 15.00% | 400 / 1,167 / 56 |
| + contextualStrings | 17.14% | 15.00% | — |
| + カスタム言語モデル | 17.21% | 15.05% | — |

1 本あたりの処理時間は SpeechTranscriber 1.1 秒、DictationTranscriber 2.7 秒、カスタム言語モデルつき 2.9 秒。
DictationTranscriber は言いよどみを落とすうえ、40 本中 13 本で 20 字以上を丸ごと落とした。

## 判断

1. **認識器は SpeechTranscriber のままにする。** DictationTranscriber は言いよどみを除いても 15 ポイント悪い
2. **contextualStrings を本体に足さない。** SpeechTranscriber の出力を 1 文字も変えなかった
3. **カスタム言語モデルを入れない。** 載せられるのは DictationTranscriber だけで、載せても CER は変わらなかった
4. 辞書は認識後の置換（[05](../specs/05-text-postprocessing.md) の L2）で進める。この結論は ADR-018 と同じだが、理由は「API が無い」から「API はあるが効かない」に変わる
5. **次に詰めるのはライブ認識とファイル認識の差**（3.0% と 1.0%、同じモデル）。差は置換と脱落で、逐次の確定（`.volatileResults` / `.fastResults`）か、無音での区切り（[ADR-020](020-pause-triggered-segment-commit.md)）が候補。どちらかは未確定

## 却下した案

- **DictationTranscriber + カスタム言語モデルに切り替える**: 語彙は寄るが、土台の誤りが 15 ポイント多い。語彙で取り戻せる幅は 13 本の小さな差だけだった
- **contextualStrings だけ入れる（害が無いので）**: 効かない設定は、効いていると誤解させるだけで、不具合の切り分けも難しくする
- **人が正解を書き起こしてから決める**: 差（16 ポイントと 2 ポイント）が正解の偏りより大きく、順位は変わらない。書き起こしの手間に見合わない

## 検証と限界

- 正解の土台が SpeechTranscriber なので、その CER は下限である（判断がつかない箇所は SpeechTranscriber に有利）。他の設定との差はこの偏りより大きい
- 5 通りの出力が揃って誤った箇所は、正解でも見逃している
- 話者は 1 人、マイク環境は録音時のまま。40 本の正解は 2026-10-18〜10-22 の録音
- 測定に使ったスクリプトはリポジトリに置いていない（録音の本文を扱うため。手元の作業用ディレクトリ）

## 見直しの条件

- macOS の更新で、SpeechTranscriber が contextualStrings を受け付けると文書に書かれたとき、または SpeechTranscriber に `contentHints` が増えたとき。確認は SDK の `Speech.swiftinterface` で `SpeechTranscriber` の初期化子と、同じ 100 本で出力が変わる本数
- ライブとファイルの差の原因を直したあと、残る誤りが語彙（固有名・技術用語）に偏ったとき
