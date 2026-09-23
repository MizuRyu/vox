# ADR-015 検索対象は「アプリ固有 → ターミナル汎用 → 最近使ったフォルダ」の 3 方式で決める

- 状態: 承認
- 日付: 2026-09-23
- 関連: ADR-011（挿入先・検索対象をトグル ON 時の前面アプリで決める）、[04 コマンドパレット](../specs/04-command-palette.md)、T38-d

## 文脈

R15（ADR-011）は「パレットの検索対象はトグル ON 時の前面アプリから導く」と決めた。
実装できていたのは 2 つだけで、どちらもアプリ固有の仕掛けだった。

- Orca: `orca worktree ps --json` に聞く。
- Terminal.app: AppleScript（`tty of selected tab of front window`）で tty を取り、その tty の最前景プロセスの cwd から git のルートを出す。

残りは全部 `--repo`（無ければカレントディレクトリ）に落ちる。利用者が実際に前面に置くのは Zed と
複数のターミナル（Ghostty / cmux / iTerm2 / Warp）で、ここが決まらないと録音のたびにヘッダから
フォルダを選び直すことになる（T23 の切り替えは救済であって解決ではない）。

アプリを足せない理由は 2 つある。

1. **AppleScript 経路はアプリごとに別物**。Terminal.app の `selected tab of front window` に相当する
   語彙は Ghostty と cmux にはない（AppleScript 辞書を持たない）。iTerm2 は持つが語彙が違う。
   アプリの数だけ別の照会を書くことになり、しかも Automation 権限のダイアログが増える。
2. **Zed はプロセスから cwd を取れない**。Zed の cwd は起動した場所であって、開いているプロジェクトではない。
   プロジェクトは Zed の workspace DB にしか無い。

一方で、ターミナルに共通する事実がある。**どのターミナルも、シェルを自分の子孫プロセスとして
起動し、そのシェルに tty を割り当てる**。この 1 つの事実だけで cwd までたどれる。

## 決定

前面アプリの bundle identifier で 3 つの方式に振り分ける。方式の選択と出力の解釈は VoxCore の純粋関数、
プロセス起動と DB 読み取りは VoxApp（`PaletteTargetResolver`）に置く。

| 方式 | 仕組み | 対象 | 計測の `palette_target_source` |
|---|---|---|---|
| A アプリ固有 | アプリが持つ「いま開いているプロジェクト」に直接聞く | Orca（CLI）、Zed（workspace DB） | `orca` / `zed` |
| B ターミナル汎用 | 前面アプリの PID から子孫プロセスの tty を集め、最後に使われた tty の cwd から git のルートを出す | Terminal.app、Ghostty、cmux、iTerm2、Warp | `terminal` |
| C 決まらないとき | `--repo` → 最近使ったフォルダの最新（T23）→ カレントディレクトリ | 上記以外 | `fallback` / `recent` / `fallback` |

bundle identifier から方式への対応は `PaletteTargetAdapter` の表 1 か所に置く。
新しいターミナルへの対応はその表に 1 行足すだけで済む（B の実装には触らない）。

### B の「最後に使われた tty」

1. `ps -axo pid,ppid,tty,comm` を 1 回だけ実行し、前面アプリの PID から ppid をたどって子孫を集める。
2. 子孫のうち tty を持つものの `/dev/<tty>` の mtime を見て、最も新しいものを選ぶ。
3. その tty で `ps -t <tty> -o pid=,comm=` を実行し、最後の行（= 最も新しく起動したプロセス）の cwd を
   `proc_pidinfo(PROC_PIDVNODEPATHINFO)` で取る。
4. その cwd を含む git のルート、無ければ cwd そのものを検索対象にする。

2 は推定である。tty の mtime はそのタブに書き込みがあった時刻なので、「利用者が見ているタブ」とは
厳密には違う（バックグラウンドのタブでビルドが流れていれば、そちらの mtime が新しい）。
それでも 1 タブしか開いていない場合は必ず当たり、複数タブでも直前に操作したタブが当たる。

**Terminal.app も B に移す**。AppleScript の `selected tab of front window` は「見ているタブ」を
正確に返すので、Terminal.app だけは精度が落ちる。それでも 2 つの仕掛けを並べて持たないほうを選んだ
（Automation 権限のダイアログも消える）。見直しの条件に入れた。

### A の Zed

`~/Library/Application Support/Zed/db/0-<channel>/db.sqlite` を**読み取り専用**で開き、3 回問い合わせる。

1. `kv_store` の `session_window_stack`（JSON 配列。先頭が最前面のウィンドウ id）
2. `scoped_kv_store`（namespace `multi_workspace_state`、key = ウィンドウ id）の `active_workspace_id`
3. `workspaces.paths`（複数ルートは改行区切り。索引は 1 ルートなので先頭を採る）

`workspaces.timestamp` の最新を見ないのは、Zed が背面のウィンドウの timestamp も更新するため
（LSP・自動保存・ファイルを開いただけ）。ウィンドウの焦点順を見ればそれに引っかからない。
参考実装は `mzed`（`src/zed.rs`）で、同じ 3 段をたどっている。

Zed の DB は WAL なので、書き込み中の読み取りが起こる。`sqlite3_open_v2` に `SQLITE_OPEN_READONLY` だけを
渡し、書き込みも `PRAGMA` も一切しない。**Zed が開いているプロジェクトのパスを検索対象にする**
（`git rev-parse` でリポジトリのルートまで広げない）。Zed が見せているのはその workspace であって、
それを含むリポジトリではない。

リモート接続の workspace（`workspaces.remote_connection_id` が非 NULL）は対象にしない。`paths` は接続先の
パスなので、同じ絶対パスが手元にあると無関係なフォルダを検索してしまう。

対応する channel は `dev.zed.Zed`（stable）/ `dev.zed.Zed-Preview` / `dev.zed.Zed-Nightly`。
`dev.zed.Zed-Dev`（手元ビルド）は入れない。

### 共通の約束

- 待ち上限は既存の 500ms（`PaletteTargetResolver.timeoutMilliseconds`）。A / B が期限内に返らなければ C に落ちる。
  Zed の DB 読み取りは問い合わせごとに期限を見る（`sqlite3_busy_timeout` はロック待ちの上限でしかなく、
  処理全体の期限にはならない）。
- DB が無い・ロックされている・スキーマが違う・`ps` が読めない — どの失敗も**黙って C に落ちる**。
  「Zed の DB が読めません」のような案内は出さない（利用者に打てる手が無く、ヘッダのパスが答えになっている）。
- 診断ログに出すのは方式の名前と失敗の種類だけ。ウィンドウ名・プロジェクト名・パスは既存方針どおり
  `--log-text` の回にしか出さない（`voxLoggable(path:)` を通す）。

## 却下した案

- **ウィンドウ名からの推定（T38-d の元案）**: ウィンドウタイトルにパスやプロジェクト名を出すアプリなら
  拾えるが、誤検出したときの見え方が決まらない。ヘッダに「近いが違うパス」が出ても利用者は気づけず、
  索引だけが静かに別のリポジトリになる。Accessibility でタイトルを読む形も同じ理由で入れない。
- **Terminal.app だけ AppleScript を残す**: 同じ目的の仕掛けを 2 つ持つことになる。
  精度は上がるが、ターミナルを足すたびに「どちらの経路か」を判断する分岐が増える。
- **各ターミナルの専用 API**（iTerm2 の Python API、Warp の launch configuration 等）:
  アプリの数だけ実装と権限が増える。B が当たらないアプリが出てから考える。
- **Zed の `workspaces.timestamp` 最新へ後退する**（`mzed` のフォールバック）: 前面でないウィンドウの
  プロジェクトを拾う。黙って違うリポジトリを見るより、C の最近使ったフォルダのほうが素性が分かる。
- **`lsof` で前面アプリの開いているファイルから推定**: 数百行を毎回読むので 500ms に収まらず、
  エディタが開いているのは「プロジェクトのルート」ではない。
- **アプリ別の対応表を設定ファイルに出す**: 対応表は「このアプリはターミナルか」という事実であって
  利用者の好みではない。設定に出すと、足すべきなのは表なのに設定を書かせることになる。

## 見直しの条件

- **Terminal.app で「見ていないタブ」の cwd が対象になったと報告が出たとき**。Terminal.app だけ
  AppleScript 経路に戻す（削除した実装は git 履歴にある）。同じことが他のターミナルで起きたら、
  mtime ではなく「そのアプリの前面ウィンドウのタイトルに出る tty」等の別の手掛かりを探す。
- **Zed の DB スキーマが変わって `session_window_stack` か `multi_workspace_state` が消えたとき**。
  黙って C に落ちるので壊れはしないが、Zed の解決が効かなくなる。`ZedWorkspaceReaderTests` の
  fixture がそのときの正本になる。
- **Zed が「いま開いているプロジェクト」を照会する CLI か API を出したとき**。DB 読み取りをやめてそれに移す。
- **B で当たらないターミナルが出たとき**（シェルを別プロセスツリーで起動する、tty を使わない）。
  そのアプリだけ A に置く。
