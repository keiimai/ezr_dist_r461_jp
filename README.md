# EZR と RStudio の実行環境（R 4.6.1）

ブラウザーの中で [EZR](https://www.jichi.ac.jp/usr/hema/EZR/statmed.html) と RStudio を使える環境を、Zip で配るためのリポジトリです（日本語版）。使う人のパソコンに入れるのは Docker Desktop だけで、R・RStudio・EZR は入れません。

> この環境は、EZR の開発元とは関係の無い、非公式の配布環境です。EZR の開発元が作ったり、確かめたり、勧めたりしたものではありません。この環境についての問い合わせは、EZR の開発元には送らず、この環境を配った人に送ってください。

## 使い方

配られた Zip（`EZR_jp_r461_<版>.zip`）を展開し、中の手順書を開きます。起動から、EZR を開いて解析し、終わるまでを、写真付きで説明しています。

| パソコン | 手順書 |
|---|---|
| Mac（Apple シリコン・Intel） | `HOW_TO_USE_Mac.html` |
| Windows | `HOW_TO_USE_Windows.html` |

## できること

- クリックだけで EZR を開けます。
- 研究ごとに「プロジェクト」を作り、データ（CSV・Excel）と記録を分けて置けます。
- EZR の操作の記録（R スクリプト・R マークダウン・出力・グラフ）が自動で残り、EZR を閉じると、図の入った報告書（`markdown.html`）ができます。使ったデータの指紋（SHA-256）と、R とパッケージの版も残ります。

## 仕組み

EZR（R のパッケージ RcmdrPlugin.EZR）は、Docker のコンテナの中で、公式の手順と同じく、RStudio とは別の普通の R で開きます。EZR の画面はコンテナの中の仮想ディスプレイに描かれ、RStudio Server の中継を通して、ブラウザーの別のタブに出ます。

```
ブラウザ ─ http://localhost:<番号>（RStudio Server）
コンテナ ezr-r461（/app ＝ このフォルダ）
  ├─ RStudio の R ─「EZR を開く」の窓 → ezr_open()
  ├─ Xvnc :1 ＋ fluxbox ─ EZR の R（普通の R）─ R Commander + EZR
  ├─ websockify :6080（noVNC）─ RStudio の中継 /p/<鍵>/ でブラウザへ
  └─ projects/<名前>/ ─ data/・outputs/<YYYYMMDDHHMM>_<4桁>/
```

RStudio を開くと、`.Rprofile` の余白が「EZR を開く」の窓を一度だけ出す。窓でプロジェクトを選ぶと、`ezr_open()` が仮想ディスプレイを起こし、普通の R に EZR を読ませて、ブラウザーの別のタブに出す。

## プロジェクトと記録

プロジェクトは `projects/<名前>/` で、窓で選んだデータは `data/` に写す（CSV・Excel、1 つ 15 MiB まで。上書きしない）。EZR を開くたびに、記録のフォルダ `outputs/<YYYYMMDDHHMM>_<4桁>/` を 1 つ作る。

| ファイル | 中身 |
|---|---|
| `script.R`・`markdown.Rmd`・`output.txt` | EZR の欄の写し（書き換わるたびに書き出す） |
| `plots/` | グラフの PNG |
| `console.log` | EZR の R の出力 |
| `meta.json` | 環境・データの SHA-256・乱数の状態・記録のハッシュ |
| `markdown.html` | EZR を閉じると作る報告書（作れなければ `markdown.log`） |

「停止」は、記録のハッシュと報告書ができるまで待つ。「停止」の前に切れた回（Docker Desktop が終わった・電源を切った・「待たずに止める」）は、書き出したファイルは残るが、ハッシュは確定せず、報告書も作り直さない。

## 配る

利用者が入れるのは Docker Desktop だけ。Zip を展開して起動用のファイルをダブルクリックすると、イメージがその PC で作られ、RStudio が開く。

| 項目 | 中身 |
|---|---|
| 作る | `ezr_dist/tools/make_zip.sh r461 jp`（Git 外）が、push 済みのコミットから Zip を作る（道具の説明 → `ezr_dist/tools/README.md`） |
| 入る | 動かすのに要るファイルと、RStudio で使うテンプレートの部品。Zip を作るときに `Start EZR.app`・`TEMPLATE_VERSION.txt` を足す |
| 入らない | `tests/test_gui_worker.py`・`launcher/MacLauncher.swift`・検査と開発の設定（一覧は `make_zip.sh` の除外） |
| 渡す | ダウンロード（`ezr_dist_release` の Release）か USB |
| 差し替える | `ezr_dist/tools/distribute.sh r461`（Git 外）が、両版の Zip を作り直して Release の下書きに入れる |

## 環境診断と起動の記録

| 記録 | 中身 |
|---|---|
| 環境診断 | 保守者用。`bash diagnose_mac.command`（Windows は `diagnose_windows.bat`）が、Docker には触らずに環境を調べ、`outputs/environment_check_<日時>_<ID>.json` に残す（終了コードとオプションは `--help`） |
| `outputs/runtime_<ID>.jsonl` | 起動の段階ごとの記録 |
| `outputs/incident_<ID>.json` | 失敗・時間切れ・遅いときだけ残す記録 |

## リポジトリから直接動かす

リポジトリには `Start EZR.app` が無い。次を実行し（Windows は PowerShell）、出た番号の `http://localhost:<番号>` を開く。止めるのは `docker compose down`。

```bash
docker build --target dev -t ezr-r461:dev .
docker compose up -d dev
docker compose port dev 8787
```

x64 の PC では、先に同じ窓で `PLATFORM` を `linux/amd64` にする（→ [`docs/DOCKER.md`](docs/DOCKER.md) 1 節）。コンソールからは `source("R/project_ezr.R")` のあと `ezr_open("studyA")`。保守者のコマンドは `make help`。

## 試験

`make test`（`check`・`verify` にも入る）が `tests/testthat` をすべて走らせる。EZR の試験だけを走らせる命令（`ezr-test`、amd64 で試す `ezr-test-amd64`、Mac の側で起動の流れを試す `ezr-test-launcher`）は、`make help` に出る。

## コードの説明

コメントは `R/project_ezr.R` と `tests/testthat/test-project_ezr.R` にだけ、関数とテストごとに 1 行置く。

| ファイル | 役割 |
|---|---|
| `start_mac.command`・`start_windows.bat` | 起動用のファイル。イメージを作ってコンテナを起こし、画面を出す |
| `launcher/MacLauncher.swift` | Mac の画面（`Start EZR.app`）の元。Zip を作るときにアプリにする |
| `launcher/windows_gui.ps1` | Windows の画面 |
| `launcher/start_messages.txt` | 起動と画面の文の一覧（日英で中身が違う） |
| `diagnose_mac.command`・`diagnose_windows.bat` | 保守者用の環境診断 |
| `ezr_start.R` | 「EZR を開く」の窓を出す |
| `R/project_ezr.R` | EZR を開き、記録を残す関数 |
| テンプレートの余白（`docker/project_*`・`project.mk`・`.Rprofile` の末尾など） | EZR に要るパッケージ・設定・命令 |
| `tests/testthat/test-project_ezr.R` | `R/project_ezr.R` と起動用のファイルの試験 |
| `tests/test_gui_worker.py` | Mac の起動の流れの試験 |

## ライセンスと引用

- コードは [MIT](https://opensource.org/license/mit)（`LICENSE`）です。
- 利用者向けの手順書（`HOW_TO_USE_*.html` とその中の写真）とデモ動画は [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/deed.ja)（`LICENSE-docs`）です。写真に写るソフトウェアの画面の権利は、それぞれの作者にあります。
- 環境を作るときに取ってくるもの（R、EZR を含む R のパッケージ、RStudio Server など）は、配るものに入れていません。それぞれの作者の条件に従います。
- この環境を引用するときは、`CITATION.cff` の情報を使ってください。作者への問い合わせ先も、`CITATION.cff` にあります。

## AI の使用

コードと文書は、AI のコーディング支援（Anthropic の [Claude Opus 5.5](https://www.anthropic.com/claude/opus) を [Claude Code](https://code.claude.com/docs/en/overview) で使った）を道具として使って書いた。

## 困ったとき

| こんなとき | こうします |
|---|---|
| EZR のタブが開かず、RStudio に「Popup Blocked」と出た | ブラウザーが新しいタブを止めました。窓の「Try Again」を押すと、EZR のタブが開きます。 |
| 「Docker Desktop が見つかりません」と出る | 手順書の 1 の案内に従って、Docker Desktop を入れてください。 |
| 「Docker Desktop の準備ができませんでした」と出る | Docker Desktop の画面を開き、左下に「Engine running」と出るまで待ってから、もう一度起動します（手順書の 3）。 |
| 「環境を用意できませんでした」や「パッケージの一覧を作り直せませんでした」と出る | インターネットにつながっているか、ディスクの空きがあるかを確かめて、もう一度起動します（手順書の 3）。 |
| ブラウザーに RStudio が開かない | 「EZR 実行環境」の画面の「ブラウザーを開く」を押します。それでも開かないときは、「アドレスをコピー」を押し、ブラウザーのアドレス欄を右クリックして「貼り付けて移動」を押します（Safari では「ペーストして移動」、Edge では「貼り付けて localhost:8787 に移動」のように、アドレスの入った名前で出ます）。 |
| EZR の画面が固まった・窓が見当たらない | 手順書の 4 の (3) で窓を出し、同じプロジェクトを選びます。それでも直らないときは、手順書の 7 で止めてから、3 で起動し直します（記録は残ります）。 |
| 別のプロジェクトを選んだら、RStudio の左下（Console）に、前の EZR を閉じられないと赤字で出た | 前の EZR で、ファイルを選ぶ窓などが開いたままか、計算の途中です。EZR のタブでその窓を閉じる（計算なら終わるのを待つ）と、前の EZR が閉じるので、もう一度手順書の 4 の (3) を行います（記録は残ります）。 |
| 「EZR を開く」の窓に、「前の回の報告書（markdown.html）を作っています。…」と赤字で出た | 前の回の報告書ができるまで、少し待ってから、もう一度「EZR を開く」を押します。 |
| 別のプロジェクトを選んだら、RStudio の左下（Console）に「前の回の報告書を作っています。できたら「…」を開きます…」と出て、すぐには開かない | 前の回の報告書ができると、自動で開きます。そのまま待ちます。 |
| 準備や停止の途中に「EZR 実行環境」の画面を閉じようとしたら、「準備・停止処理が終わるまでお待ちください」と出た | Mac は「戻る」、Windows は「OK」を押し、終わるまで待ちます。 |
| 「停止」を押しても止まらない | 手順書の 7 のとおり、少し待ってから、もう一度「停止」を押します。 |
| 「停止できませんでした」と出る | Docker Desktop が動いているかを確かめてから、もう一度「停止」を押します。 |
| EZR の「ツール」→「オプション...」で「R Commanderの再起動」を押した | 「終了?」は OK、「スクリプトファイルを保存?」などは「No」を押します。新しい設定で開き直したら、データを「データセット:」のボタンで選び直します（データと記録は続きます）。 |
| Mac で、2 回目からも `start_mac.command` を開けないという警告が出る | 出た表示をそのまま、この環境を配った人に伝えてください（初めてのときは、手順書の 3 の A か B で起動します）。 |
| Mac で、「このアプリだけでは起動できません」と出る | `Start EZR.app` ではなく、`start_mac.command` から起動します（手順書の 3）。アプリだけを別の場所に写したときにも出ます。 |
| Windows で、「このファイルは、解析のフォルダ（docker-compose.yml のあるフォルダ）の中に置いて使ってください。」と出る | Zip を展開せずに中を開いているか、`start_windows.bat` だけを別の場所に動かしています。手順書の 2 のとおり展開し、`EZR_r461` フォルダの中の `start_windows.bat` をダブルクリックします。 |
| Windows で、「Windows によって PC が保護されました」と出る | 「詳細情報」を押し、出てきた「実行」を押します（手順書の 3）。 |
| Windows で、「このフォルダは、すでに起動しています。」と出る | 開いている「EZR 実行環境」の画面（タスクバーにあります）に戻ります。 |
| RStudio のタブに「R Session Disconnected」と出た | RStudio は、ブラウザーのタブ 1 つにしかつながりません。別のタブで RStudio を開くと（「ブラウザーを開く」など）、前のタブがこの表示になります。このタブは閉じます。「EZR を開く」の窓が出ていたときは、残ったタブに窓が出ます。出ないときは、手順書の 4 の (3) のとおり、`ezr_start.R` の「Source」を押します。Console が反応しないときは、先に Console の右上の赤い停止のボタンを押します。 |
| RStudio に「R is taking longer to start than usual」と出て進まない | 「Reload」を押します。 |
| 「EZR を開く」の窓が出たまま RStudio のページを読み込み直したら、窓が出ず、Console も使えない | Console の右上の赤い停止のボタンを押してから、`ezr_start.R` の「Source」を押します。窓がもう一度出ます。 |
| ブラウザーが「翻訳しますか?」と尋ねる | 翻訳はせず、× で閉じます。 |
| 狭い画面で、RStudio の「Source」・［Render］の文字が見えない | ボタンが矢印のアイコンだけになっています。隣のチェック（「Source on Save」・「Render on Save」）ではなく、矢印のアイコンを押します。 |
| パッケージ（依存関係）を変えたい | 今の `EZR_r461` フォルダは変えずに、配られた Zip をもう一度展開して新しい `EZR_r461` フォルダを作り、そちらで変えます。今のフォルダの解析は、今までと同じパッケージのまま続けられます。 |
| 「起動または停止に失敗しました（終了コード…）」と出る | 「EZR 実行環境」の画面の下の欄に出た表示をそのまま、この環境を配った人に伝えてください。 |
