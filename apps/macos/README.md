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

次の音声入力がすぐ始められるよう、サーバーへの接続は事前に張っておく (文字起こしの課金は送った音声の長さに対してで、待機中は対象外)。

貼り付け前の整形は、設定 (⌘,) かメニューバーで3通りから選ぶ。

- 高速 (既定): 「えーと」「あのー」などをアプリ内で即座に取り除く。
- 高精度: LLM が言い直しや句読点も直す。貼り付けが遅くなり、1回ごとに課金される。失敗時は高速の整形で貼り付ける。
- オフ: そのまま貼り付ける。

設定の「用語辞書」に登録した読み替え (例: タキオン → Tachyon) は、どのモードでも貼り付け前に適用する。「背景情報」は高精度モードで、聞き間違いを文脈から直す手がかりとして LLM に渡す。文字起こしのモデル自体はプロンプトを受け取れないため、精度はこの後処理で補っている。

文字起こしは Tachyon model gateway が発行する client secret で OpenAI Realtime API (transcription session) に接続する。

## 使い方

macOS 26 以降が必要 (Liquid Glass を使うため)。

1. `./scripts/build-app.sh` でビルドする
2. `open "build/Tachyon AI.app"` で起動する
3. 開いたログイン窓で Tachyon にログインする (あとからはメニューバー >「ログイン…」)
4. マイクとアクセシビリティを許可し、アプリを再起動する
5. システム設定 > キーボード >「🌐キーを押したとき」を「何もしない」にする

## 開発

ソースは `Sources/TachyonAI/Mac` (Mac 専用) と `Sources/TachyonAI/Shared` (iOS 版と共通) に分かれている。iOS 版は `apps/ios`。

`./scripts/dev.sh` を端末で動かしておくと、`./scripts/build-app.sh` で新しいビルドができるたびにアプリが自動で再起動し、開いていた会話も復元される。

## 設定 (任意)

`~/Library/Application Support/TachyonAI/config.json`

| キー | 既定値 | 用途 |
|---|---|---|
| `apiURL` | `https://api.n1.tachy.one` | Tachyon API |
| `realtimeURL` | `wss://api.openai.com/v1/realtime` | Realtime WebSocket |
| `language` | `ja` | `ja` または `en` |
| `chatModel` | `anthropic/claude-sonnet-5` | チャットの既定モデル (入力欄で選ぶまで使われる) |
| `cleanupModel` | `anthropic/claude-haiku-4.5` | 整形のモデル |
| `cognitoDomain` | `https://auth-pool.n1.tachy.one` | ログイン先 |
| `cognitoClientId` | `tachyon` CLI と同じ公開クライアント | OAuth クライアント ID |
| `operatorId` | ログイン時の先頭テナント | テナント ID (`tn_...`) |
| `apiKey` | なし | 指定するとログインの代わりに使う (`operatorId` 必須) |

## 注意

- `./scripts/create-dev-cert.sh` を一度実行すると、自己署名証明書 `Tachyon AI Dev` で署名され、再ビルドしても権限が維持される。証明書がないと ad-hoc 署名になり、ビルドのたびに権限の再許可が必要になる。
- ログイン情報は `~/Library/Application Support/TachyonAI/credentials.json` (所有者のみ読み書き可) に保存する。アクセストークンは期限前に自動更新する。
