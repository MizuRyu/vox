# benchmarks

M0（認識エンジンの比較）ハーネス。Apple / Nemotron / Parakeet を同じ入力で測り、CER と遅延を集計する。

本体とは別 package。FluidAudio に依存するのはここだけで、本体の `Package.swift` は外部依存を持たない
（[ADR-013](../docs/adr/013-library-app-and-test-targets.md)）。本体のコードには依存しない。

```sh
just bench-run <engine> <manifest> <output>   # 測定
just bench-normalize <input> <output.wav>     # 音声の正規化
just bench-jsut                               # JSUT basic5000 の取得と manifest 生成
just bench-report                             # results/*.jsonl を m0-results.md に集計
```

検査は `just bench-test`（`m0-core-tests` と `Tests/BenchmarkReport`）。`just verify` には含まれない。
