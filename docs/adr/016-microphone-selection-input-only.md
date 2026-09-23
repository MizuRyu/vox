# ADR-016 マイクをVox内で選び、通常録音を入力専用 AUHAL で開く

- 状態: 承認
- 日付: 2026-09-23
- 関連: [03 アーキテクチャ](../specs/03-architecture.md#マイクの選択と録音出力)、[使い方](../usage.md#マイクと実験的な音声処理)

## 文脈

従来の Vox は AVAudioEngine の既定入力で録音し、設定画面では機器を表示するだけだった。Bluetooth ヘッドセットで音楽を再生しながら録音すると、ヘッドセットのマイクが開かれて通話用プロファイル（HFP）に切り替わり、音楽が止まるか音質が落ちていた。同じ状況で Codex アプリの音声入力は音楽を止めない。

AVAudioEngine の `inputNode` は、既定の入力と出力をまとめた集約デバイス `CADefaultDeviceAggregate-<pid>-0` に AUHAL をつなぎ、変換器まで組み上げる（2026-09-23 の系統ログ `com.apple.coreaudio:AUHAL` / `com.apple.avfaudio:avae` で確認）。既定の入出力がヘッドセットなら、そのマイクも開かれる。組み上がった後に CurrentDevice を別の機器へ書き換えると、`engine.start()` の直後に engine 自身が `iounit configuration changed` を出して止まる。

Codex アプリ（`com.openai.codex` 26.915、Chromium 153）を静的に調べた。未指定時は、内蔵ディスプレイがあり、既定の入出力がともに Bluetooth / Bluetooth LE で、既定出力の `DeviceIsRunningSomewhere` が 1 のときに内蔵マイクを `getUserMedia({deviceId: {exact}})` で開く。Chromium は入力専用の AUHAL を自分で作り、初期化前に入力 IO 有効・出力 IO 無効・入力機器の順で設定する（[対象 revision の入力処理](https://chromium.googlesource.com/chromium/src/+/79460ebecaa5625e57a5fb679a735659e73dc687/media/audio/apple/audio_low_latency_input.cc)、[Apple TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)）。音楽を信号処理で取り除く仕組みは見つからなかった（`system-audio-spectrum` は波形表示用、`voice-dsp` の ducking は自身の読み上げ音量用）。

同じ構成の検証用コマンドで、AirPods に Music を再生したまま内蔵マイクを開いた。既定出力は 48kHz・稼働のままで構成変更はなく、毎秒約 48,000 フレームを受け取り、音楽は止まらなかった。

## 決定

1. `microphone_input` に自動・macOSの既定・UIDによる個別指定を保存する。既定と旧設定は自動。指定機器が不在なら開始エラーにする。
2. 自動は既定の入出力が Bluetooth / Bluetooth LE、出力が稼働中、内蔵入力が利用可能な場合だけ内蔵を選ぶ。それ以外は既定入力。出力の稼働は再生の近似として用い、アプリ名や楽曲情報は取得しない。
3. 設定は録音セッションに固定し、機器は録音準備時に解決する。OS 全体の既定デバイスを変更しない。
4. 通話向け処理がオフの録音は、Vox が作る入力専用 AUHAL（`HALInputCapture`）で選んだ機器だけを開く。初期化前に入力 IO 有効 → 出力 IO 無効 → CurrentDevice の順で設定し、開始後に読み戻す。不一致は開始失敗として終了する。
5. AUHAL からは機器のサンプルレートとチャンネル数の float32 非インターリーブで受け取り、既存の給餌経路（モノラル化 → analyzer 形式への変換）へ渡す。選んだ機器の `DeviceIsAlive` と `NominalSampleRate` の変化を録音の中断として扱う。
6. 通話向け処理（実験的・既定オフ）は VoiceProcessingIO が要るため AVAudioEngine で開く。AGC 無効・ducking 最小を保ち、音量低下の完全な無効化は保証しない。選んだ機器が既定入力と異なる場合だけ、有効化後の Audio Unit の入力 element 1 に機器を設定する。この場合は構成変更で止まりうる。
7. UID は保存設定だけに置き、診断ログは選択方式・実際に選んだ機器名と transport・一時 ID・経路（`route=input_only` / `voice_processing`）を記録する。

Codex の内蔵ディスプレイ条件や機器名の部分一致は移植しない。Vox は CoreAudio の入力の有無と ID を直接扱えるため、内蔵入力の存在確認と UID の一致で足りる。指定失敗時の既定入力への復帰も、利用者の選択を守るため採用しない。

## 却下した案

- **AVAudioEngine のまま CurrentDevice や EnableIO を書き換える**: engine が組み上げた後の変更は構成変更として通知され、録音が止まる（実機で 5 回中 4 回）。
- **自分で起こした構成変更は engine の再起動で吸収する**: 集約デバイスに既定出力が含まれる構造は残り、非公開の挙動に依存する。
- **AVCaptureSession**: 機器は指定できるが、内部の経路が見えず、Codex で実績のある構成と一致しない。
- **OS の既定入力を書き換える**: 他アプリまで入力先が変わる。
- **WebRTC を導入して AEC を移植する**: 別プロセスの音楽を除去できるという実測がなく、参照信号の収集と依存が増える。入力選択から独立した判断が必要。

## 検証と限界

入力選択・後方互換・UIDによる再接続・設定の固定は純粋な値と合成機器で検査する。Audio Unit の設定順序・失敗・読戻し不一致と、受け取る形式は合成のプロパティ読み書きで検査する。Vox 本体やマイクはエージェントが起動しない。AUHAL の開始・停止、Bluetooth 再生の継続、認識精度は [REC-09〜12](../MANUAL-VERIFICATION.md#rec-09-自動選択で音楽再生と録音を併用する) で利用者が確認する。入力専用の構成はマイクへ物理的に入る音楽を除かない。コールバックは IO スレッドで毎回バッファを確保する。

## 見直しの条件

- 入力専用 AUHAL でも Bluetooth 再生が止まる、またはフレームが欠ける実機ログが得られたとき。確認は上記 TC と `audio_input_verified ... route=input_only` / `audio_configuration_changed`、回帰検証は `nix develop -c just verify`。
- 内蔵入力の認識品質が用途を満たさないとき。自動選択の既定と条件を見直す。
- 通話向け処理を常用する要件が出たとき。Vox が作る VoiceProcessingIO へ移し、決定 6 の制約を外す。
- 音楽をマイク信号から除く要件と評価用音声が用意されたとき。AEC の参照信号・品質・権限・依存を別の判断として扱う。
