# Tachyon AI

Tachyon の Mac アプリと iPhone / iPad アプリ。どちらも `TachyonAI.xcodeproj` から作り、App Store Connect では同じアプリ (`com.quantumbox.tachyonai`) として配る。macOS 26 / iOS 26 以降が必要 (Liquid Glass を使うため)。

- `Mac/`: Mac 専用 (メニューバー、fn キーの音声入力、チャット窓)
- `iOS/`: iOS 専用の画面とマイク入力
- `Shared/`: 共通のコード (ログイン、API、チャットの状態、Markdown 表示、整形、設定の各項目)。`apps/aithinkin` も Markdown 表示の 2 ファイルを参照している
- `Assets/`: アプリのアイコン (両方)
- `Config/`: Mac 版のエンタイトルメント、開発ビルドの Info.plist、TestFlight の書き出し設定

フォルダはプロジェクトにそのまま同期されていて、ファイルを足せば自動でビルド対象になる。

Mac 版はメニューバーに常駐する。

## チャット

メニューバー >「チャットを開く」、または起動中にアプリをもう一度起動すると、チャット窓が開く。

- Tachyon のエージェントと会話する。返答はストリーミングで、Markdown として表示される。
- 左のサイドバーに過去の会話が並び、選ぶと続きから再開できる。
- 入力欄の下でモデルと思考量を選べる。メニューに出すモデルは設定 (⌘,) で選ぶ (既定は GPT-6 系のみ)。思考量が効くのは OpenAI の gpt-5 / gpt-6 系だけで、他のモデルでは API 側が無視する。
- ⌘+ / ⌘- で文字の大きさを変え、⌘0 で元に戻す (80%〜200%)。
- 入力欄のクリップから、またはドラッグ&ドロップでファイルを添付できる。対応しているのは画像 (JPEG・PNG・GIF・WebP、それ以外は JPEG に変換) とテキスト形式のファイル。PDF などは API が未対応。合計は約3MB まで。
- 使用量 (トークン数、API が返す場合は料金) は設定の「使用量」で確認できる。今の会話の分と、このアプリでの累計が出る。
- エージェントは Web 検索とページの取得を使える。それ以外のツールは使わない。
- ツールバー右端のボタン (⇧⌘B) で、右にブラウザを出す (⌘B は左の会話一覧の開閉)。幅はドラッグで変えられ、次に開くときもその幅になる (Mac のみ)。返答の中のリンクはここの新しいタブで開く (⌘クリックなら既定のブラウザ)。＋ (⌘T) で空のタブを開き、URL か検索語を入れる。⌘L でアドレス欄に移り、⌘W で今のタブを閉じる (タブがなければ窓を閉じる。窓を閉じるのは ⇧⌘W)。タブは会話ごとに残り、会話を切り替えると入れ替わり、再起動後も戻る (空のタブは残さない)。ブラウザを出すと、窓は会話一覧とチャットとブラウザが並ぶ幅まで広がる (画面に収まる範囲で)。
- 右のペインには Web ページのほかに、返答の全文 (返答の下の「右で開く」、Markdown で表示) と、この起動中に送った添付ファイル (メッセージの添付をクリック、画像はそのまま、テキストは等幅) も開ける。これらのタブは会話に残さない。
- エージェントには、ページを右のペインで開くツール (`open_in_browser`、API の `client_tools` で渡す fire-and-forget のツール) も渡している。「〜を開いて」と頼むと、エージェントがページを右に開く。
- エージェントは、右のペインで選んでいるタブのページの文字 (タイトル、URL、本文。6万字まで) も読める (`read_browser_page`、結果を `/v1/llms/sessions/{id}/agent/tool-result` に返すツール)。渡す前に「渡す」「(サイト) は常に許可」「渡さない」を聞く。常に許可はホスト単位 (`mail.google.com` を許可しても `docs.google.com` は聞く) で、ペインの「…」>「ページの読み取りの常に許可を解除」でまとめて解除できる。
- ブラウザの「…」とメニューバーの「ファイル」から Tachyon のサービス (Tachyon `https://app.n1.tachy.one`、Field `https://fieldv2.txcloud.app`、Library `https://library.n1.tachy.one`) を開ける。エージェントもこの一覧を知っていて、「field を開いて」なら URL を聞かずに開く。一覧は config.json の `sites` (`[{"name", "url", "aliases"}]`) で差し替えられる。アプリのログインとは別なので、最初の1回はペインの中でログインする。
- ブラウザの「…」>「Chrome からログイン状態を読み込む…」で、選んだ Google Chrome のプロフィールの Cookie をすべてコピーする。値を復号する鍵 (キーチェーンの「Chrome Safe Storage」) を読むときに macOS が許可を求める。パスワードは読まない。App Sandbox の中でも Chrome のフォルダ (`~/Library/Application Support/Google/Chrome`) を読めるよう、エンタイトルメントに読み取りの例外を入れている。

## 音声入力

fn (🌐) キーを押している間だけ録音し、離すと文字起こし結果をカーソル位置に貼り付ける。設定で「話しながら入力する (アルファ版)」をオンにすると、話しているそばから入力する。

録音が始まったときと fn を離したときに短い音を鳴らす (設定でオフにできる)。fn を別のキーと組み合わせて録音を取り消したときは、終了の音は鳴らさない。

用語辞書には、頼まれなくても語を登録する (設定の「用語を自動で登録する」、既定でオン)。

- チャットで自分が打った文章と背景情報から、大文字を含む英字の語 (`Tachyon Field`、`GitHub`、`iOS`) を拾う。コードブロック、URL、パス、camelCase の識別子は拾わない。直前の音声入力に出てきた語は、モデルの綴りなので拾わない。
- 音声入力で貼り付けたあと、その入力欄を Accessibility で最長90秒見て、書き直された語を拾う (Mac のみ)。拾うのは、カタカナか英字で書かれた語が別の表記に直されたときだけで (語の途中の文字の足し引きや、大文字小文字だけの直しも含む)、漢字やひらがなの直しは同音異義語の選び直しや文の手直しなので拾わない。入力欄の文字はメモリ上で比べるだけで、残すのは書き直された語だけ。
- 拾った語は、まず文字起こしのモデルに出てくる語として伝える。同じ書き直しが2回あって初めて、貼り付け前の置き換えにも使う (1回だけでは言い換えかもしれないため)。この置き換えは語として独立しているところだけに効く (`Aws` → `AWS` を覚えても `draws` は変えない)。手で登録した置き換えは、これまでどおり語の途中にも効く。
- 設定で削除した語は、二度と登録しない。モデルに渡せる語は100個までで、手で登録した語、背景情報の語、自動で登録した語 (新しい順) の順に入れる。

音声入力した文字は、履歴としてこのデバイスにだけ残す (設定の「履歴」、メニューバー >「音声入力の履歴…」)。貼り付けに失敗したときも、そこからコピーできる。保存先は `Application Support/TachyonAI/dictation-history.json` (所有者のみ読み書き可) で、音声は保存しない。保持する期間は「保存しない」「24時間」「1週間」「30日間」「無期限」(既定) から選ぶ。iOS 版でも設定の「音声入力の履歴」で同じものが見られる。

貼り付けには、アクセシビリティとは別に「キー操作を送る権限」が要る。権限がないときは貼り付けずに、文字をクリップボードと履歴に残して、その旨を表示する。

次の音声入力がすぐ始められるよう、サーバーへの接続は事前に張っておく (文字起こしの課金は送った音声の長さに対してで、待機中は対象外)。

貼り付け前の整形は、設定 (⌘,) かメニューバーで3通りから選ぶ。

- 高速 (既定): 「えーと」「あのー」などをアプリ内で即座に取り除く。
- 高精度: LLM が言い直しや句読点も直す。貼り付けが遅くなり、1回ごとに課金される。失敗時は高速の整形で貼り付ける。
- オフ: そのまま貼り付ける。

設定の「用語辞書」に登録した語の「表記」(例: Tachyon) は、出てくる語として文字起こしのモデルに伝える。製品名や人名はこれで最初から正しく書かれる。それでも「聞こえ方」(例: タキオン) のとおりに書かれたときは、どのモードでも貼り付け前に「表記」へ置き換える。「背景情報」は文字起こしのモデルと、高精度モードの LLM の両方に、聞き間違いを文脈から直す手がかりとして渡す。

文字起こしは Tachyon model gateway が発行する client secret で OpenAI Realtime API (transcription session) に接続する。client secret を頼むときにモデル (`gpt-live-transcribe`)、用語辞書 (`transcription_keywords`)、背景情報と数字を算用数字で書く指定 (`transcription_prompt`) を渡す。gateway の既定の `gpt-realtime-whisper` は語彙もプロンプトも受け取れず、固有名詞を音だけで推測するため使わない。

このモデルをまだ発行できない gateway は既定のセッションを返す。そのときは接続後に `session.update` で同じ設定に切り替え、それも断られたら既定のまま続ける。どれで動いたかは `~/Library/Logs/TachyonAI/dictation.log` の `model=` と `tuning=` (`gateway` / `full` / `model` / `none`) でわかる。

音声は OpenAI に直接送るので、送った秒数は音声入力が終わるたびに gateway へ報告する (`/v1/ai/realtime/transcription-usage`)。gateway はこの秒数で課金する。

## iOS 版

- Tachyon のエージェントとチャットする。返答はストリーミングで、Markdown として表示される。
- 過去の会話を一覧から開いて、続きから再開する。
- モデルと思考量を選ぶ。
- 写真やファイルを添付する (画像とテキスト形式。合計 約3MB まで)。
- 設定の「使用量」で、今の会話とアプリ累計のトークン数と料金を見る。
- 入力欄のマイクボタンで音声入力する (もう一度押すと終了し、文字が入力欄に入る)。
- 設定で、文字起こしの整形、用語辞書、背景情報、表示するモデルを変える。

Mac 版にある「fn キーを押している間の音声入力 (他のアプリへの貼り付け)」は、iOS にはない。iOS ではアプリが他のアプリに文字を入力できないため。

## Mac 版を手元で動かす

TestFlight で入れるのがいちばん早い。手元でビルドするときは、Swift Package (`Package.swift`) で開発用のアプリを作る。こちらはサンドボックスなし、バンドル ID `one.tachy.ai` で、TestFlight 版とは別のアプリとして並んで入る。

1. `./scripts/build-app.sh` でビルドする
2. `open "build/Tachyon AI.app"` で起動する
3. 開いたログイン窓で Tachyon にログインする (あとからはメニューバー >「ログイン…」)
4. マイクとアクセシビリティを許可し、アプリを再起動する
5. システム設定 > キーボード >「🌐キーを押したとき」を「何もしない」にする

## 開発

`TachyonAI.xcodeproj` を Xcode で開くと、スキーム `TachyonAI` (iOS) と `TachyonAIMac` (Mac) がある。コマンドラインでは次のとおり。

```bash
xcodebuild -project TachyonAI.xcodeproj -scheme TachyonAI \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build build
xcodebuild -project TachyonAI.xcodeproj -scheme TachyonAIMac \
  -destination 'generic/platform=macOS' -derivedDataPath build build
```

実機や署名つきで動かすときは、Xcode の Signing & Capabilities で開発チームを選ぶ。Xcode で作る Mac 版は App Sandbox が有効 (TestFlight 版と同じ)。

文字起こしの設定を比べるときは、同じ音声ファイルを音声入力と同じ経路に流す。

```
afconvert -f WAVE -d LEI16@24000 -c 1 speech.m4a speech.wav
.build/debug/TachyonAI --transcribe speech.wav --keywords "Tachyon Field,Claude Code"
.build/debug/TachyonAI --transcribe speech.wav --gateway
```

`--gateway` は gateway の既定のセッションのまま、`--model` `--keywords` `--prompt` は個別に差し替える。`--verbose` でサーバーからのイベントも出す。用語辞書はアプリとは別の場所から読まれるので、語は `--keywords` で渡す。

`./scripts/dev.sh` を端末で動かしておくと、`./scripts/build-app.sh` で新しいビルドができるたびにアプリが自動で再起動し、開いていた会話も復元される。

## TestFlight への自動配信

`main` に `apps/tachyon` の変更が入ると、GitHub Actions (`.github/workflows/testflight.yml`) が iOS 版と Mac 版をビルドして TestFlight にアップロードする。`v*` タグと手動実行でも動く。ビルド番号には実行回数を使う。

最初に一度だけ、次の設定が必要。

1. App Store Connect で、バンドル ID `com.quantumbox.tachyonai` のアプリを作り、プラットフォームに iOS と macOS の両方を追加する (Apple Developer で同じバンドル ID の登録も必要)。
2. App Store Connect の「ユーザとアクセス > 統合 > App Store Connect API」で、App Manager 以上の権限の API キーを作り、`.p8` をダウンロードする。
3. このリポジトリに次を設定する。

| 種類 | 名前 | 値 |
|---|---|---|
| Variable | `APPLE_TEAM_ID` | Apple Developer のチーム ID |
| Secret | `APP_STORE_CONNECT_KEY_ID` | API キーの Key ID |
| Secret | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
| Secret | `APP_STORE_CONNECT_PRIVATE_KEY` | `.p8` ファイルの中身 |

```bash
gh variable set APPLE_TEAM_ID --body "<チーム ID>"
gh secret set APP_STORE_CONNECT_KEY_ID --body "<Key ID>"
gh secret set APP_STORE_CONNECT_ISSUER_ID --body "<Issuer ID>"
gh secret set APP_STORE_CONNECT_PRIVATE_KEY < AuthKey_XXXXXXXXXX.p8
```

署名用の証明書は保存しない。アーカイブは署名なし (Mac 版はエンタイトルメントを残すため ad-hoc 署名) で作り、書き出しのときに Xcode がクラウド上で管理する配布用証明書で署名する (API キーで認証)。

iOS と macOS はスパークル付きの Tachyon アイコンを使用する。共有の `icon-1024.png` を更新したら、`./scripts/make-icons.sh` で Mac 用の各サイズを再生成する。

バージョン (`MARKETING_VERSION`) はプロジェクトの設定で上げる。同じバージョンのまま何度アップロードしてもよいが、App Store に出したバージョンより上である必要がある。

## 設定 (任意)

`~/Library/Application Support/TachyonAI/config.json`。TestFlight 版 (サンドボックス) では `~/Library/Containers/com.quantumbox.tachyonai/Data/Library/Application Support/TachyonAI/config.json`。

| キー | 既定値 | 用途 |
|---|---|---|
| `apiURL` | `https://api.n1.tachy.one` | Tachyon API |
| `realtimeURL` | `wss://api.openai.com/v1/realtime` | Realtime WebSocket |
| `language` | `ja` | `ja` または `en` |
| `transcriptionModel` | `gpt-live-transcribe` | 文字起こしのモデル。空文字列にすると gateway の既定 (`gpt-realtime-whisper`) を使い、用語辞書と背景情報は渡らない |
| `chatModel` | `anthropic/claude-sonnet-5` | チャットの既定モデル (入力欄で選ぶまで使われる) |
| `cleanupModel` | `anthropic/claude-haiku-4.5` | 整形のモデル |
| `cognitoDomain` | `https://auth-pool.n1.tachy.one` | ログイン先 |
| `cognitoClientId` | `tachyon` CLI と同じ公開クライアント | OAuth クライアント ID |
| `operatorId` | ログイン時の先頭テナント | テナント ID (`tn_...`) |
| `apiKey` | なし | 指定するとログインの代わりに使う (`operatorId` 必須) |

## 注意

- `./scripts/create-dev-cert.sh` を一度実行すると、自己署名証明書 `Tachyon AI Dev` で署名され、再ビルドしても権限が維持される。証明書がないと ad-hoc 署名になり、ビルドのたびに権限の再許可が必要になる。
- ログイン情報は `~/Library/Application Support/TachyonAI/credentials.json` (所有者のみ読み書き可) に保存する。アクセストークンは期限前に自動更新する。
