# Tachyon AI

Tachyon の macOS アプリ。メニューバーに常駐する。

## チャット

メニューバー >「チャットを開く」、または起動中にアプリをもう一度起動すると、チャット窓が開く。

- Tachyon のエージェントと会話する。返答はストリーミングで、Markdown として表示される。
- 左のサイドバーに過去の会話が並び、選ぶと続きから再開できる。
- 入力欄の下でモデルと思考量を選べる。メニューに出すモデルは設定 (⌘,) で選ぶ (既定は GPT-6 系のみ)。思考量が効くのは OpenAI の gpt-5 / gpt-6 系だけで、他のモデルでは API 側が無視する。
- ⌘+ / ⌘- で文字の大きさを変え、⌘0 で元に戻す (80%〜200%)。
- 入力欄のクリップから、またはドラッグ&ドロップでファイルを添付できる。対応しているのは画像 (JPEG・PNG・GIF・WebP、それ以外は JPEG に変換) とテキスト形式のファイル。PDF などは API が未対応。合計は約3MB まで。
- 使用量 (トークン数、API が返す場合は料金) は設定の「使用量」で確認できる。今の会話の分と、このアプリでの累計が出る。
- エージェントは Web 検索とページの取得を使える。それ以外のツールは使わない。

## 音声入力

fn (🌐) キーを押している間だけ録音し、離すと文字起こし結果をカーソル位置に貼り付ける。設定で「話しながら入力する (アルファ版)」をオンにすると、話しているそばから入力する。

録音が始まったときと fn を離したときに短い音を鳴らす (設定でオフにできる)。fn を別のキーと組み合わせて録音を取り消したときは、終了の音は鳴らさない。

用語辞書には、頼まれなくても語を登録する (設定の「用語を自動で登録する」、既定でオン)。

- チャットで自分が打った文章と背景情報から、大文字を含む英字の語 (`Tachyon Field`、`GitHub`、`iOS`) を拾う。コードブロック、URL、パス、camelCase の識別子は拾わない。直前の音声入力に出てきた語は、モデルの綴りなので拾わない。
- 音声入力で貼り付けたあと、その入力欄を Accessibility で最長90秒見て、書き直された語を拾う (Mac のみ)。拾うのは、カタカナか英字で書かれた語が別の表記に直されたときだけで、漢字やひらがなの直しは同音異義語の選び直しや文の手直しなので拾わない。入力欄の文字はメモリ上で比べるだけで、残すのは書き直された語だけ。
- 拾った語は、まず文字起こしのモデルに出てくる語として伝える。同じ書き直しが2回あって初めて、貼り付け前の置き換えにも使う (1回だけでは言い換えかもしれないため)。
- 設定で削除した語は、二度と登録しない。モデルに渡せる語は100個までで、手で登録した語、背景情報の語、自動で登録した語 (新しい順) の順に入れる。

次の音声入力がすぐ始められるよう、サーバーへの接続は事前に張っておく (文字起こしの課金は送った音声の長さに対してで、待機中は対象外)。

貼り付け前の整形は、設定 (⌘,) かメニューバーで3通りから選ぶ。

- 高速 (既定): 「えーと」「あのー」などをアプリ内で即座に取り除く。
- 高精度: LLM が言い直しや句読点も直す。貼り付けが遅くなり、1回ごとに課金される。失敗時は高速の整形で貼り付ける。
- オフ: そのまま貼り付ける。

設定の「用語辞書」に登録した語の「表記」(例: Tachyon) は、出てくる語として文字起こしのモデルに伝える。製品名や人名はこれで最初から正しく書かれる。それでも「聞こえ方」(例: タキオン) のとおりに書かれたときは、どのモードでも貼り付け前に「表記」へ置き換える。「背景情報」は文字起こしのモデルと、高精度モードの LLM の両方に、聞き間違いを文脈から直す手がかりとして渡す。

文字起こしは Tachyon model gateway が発行する client secret で OpenAI Realtime API (transcription session) に接続する。client secret を頼むときにモデル (`gpt-live-transcribe`)、用語辞書 (`transcription_keywords`)、背景情報と数字を算用数字で書く指定 (`transcription_prompt`) を渡す。gateway の既定の `gpt-realtime-whisper` は語彙もプロンプトも受け取れず、固有名詞を音だけで推測するため使わない。

このモデルをまだ発行できない gateway は既定のセッションを返す。そのときは接続後に `session.update` で同じ設定に切り替え、それも断られたら既定のまま続ける。どれで動いたかは `~/Library/Logs/TachyonAI/dictation.log` の `model=` と `tuning=` (`gateway` / `full` / `model` / `none`) でわかる。

音声は OpenAI に直接送るので、送った秒数は音声入力が終わるたびに gateway へ報告する (`/v1/ai/realtime/transcription-usage`)。gateway はこの秒数で課金する。

## 使い方

macOS 26 以降が必要 (Liquid Glass を使うため)。

1. `./scripts/build-app.sh` でビルドする
2. `open "build/Tachyon AI.app"` で起動する
3. 開いたログイン窓で Tachyon にログインする (あとからはメニューバー >「ログイン…」)
4. マイクとアクセシビリティを許可し、アプリを再起動する
5. システム設定 > キーボード >「🌐キーを押したとき」を「何もしない」にする

## 開発

ソースは `Sources/TachyonAI/Mac` (Mac 専用) と `Sources/TachyonAI/Shared` (iOS 版と共通) に分かれている。iOS 版は `apps/ios`。

文字起こしの設定を比べるときは、同じ音声ファイルを音声入力と同じ経路に流す。

```
afconvert -f WAVE -d LEI16@24000 -c 1 speech.m4a speech.wav
.build/debug/TachyonAI --transcribe speech.wav --keywords "Tachyon Field,Claude Code"
.build/debug/TachyonAI --transcribe speech.wav --gateway
```

`--gateway` は gateway の既定のセッションのまま、`--model` `--keywords` `--prompt` は個別に差し替える。`--verbose` でサーバーからのイベントも出す。用語辞書はアプリとは別の場所から読まれるので、語は `--keywords` で渡す。

`./scripts/dev.sh` を端末で動かしておくと、`./scripts/build-app.sh` で新しいビルドができるたびにアプリが自動で再起動し、開いていた会話も復元される。

## 設定 (任意)

`~/Library/Application Support/TachyonAI/config.json`

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
