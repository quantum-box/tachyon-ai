# AIシンくん (iOS)

英語名は aithinkin。

端末の中で動く AI とチャットする iPhone / iPad アプリ。iOS 26 以降が必要。モデルは次の 2 つから選べる。

| モデル | 必要なもの |
|---|---|
| Apple Intelligence (Foundation Models) | Apple Intelligence に対応したデバイス。追加のダウンロードなし |
| Gemma 4 (E2B) | 初回に 2.6 GB のモデルをダウンロード。Apple Intelligence 非対応のデバイスでも動く |

一般のユーザー向けのアプリ。法人向けの Tachyon AI (`../tachyon`) とは別の製品で、ログインもネットワークも使わない。会話はデバイスの外に出ない。

## できること

- 入力欄のメニューでモデルを選び、端末内のモデルとチャットする。返答はストリーミングで、Markdown として表示される。
- 過去の会話を一覧から開いて、続きから再開する。履歴はこのデバイスに保存される。
- 設定で、AI への指示 (口調や答え方) を変える。

## Apple Intelligence を使えないとき

モデルの状態を確認し、使えないときは入力欄の上に理由を表示する。どの場合も、Gemma 4 に切り替えれば使える。

| 表示 | 対処 |
|---|---|
| このデバイスでは使えません | Apple Intelligence に対応したデバイスで開く |
| Apple Intelligence がオフです | 「設定」>「Apple Intelligence と Siri」でオンにする |
| モデルを準備中です | ダウンロードが終わるまで待つ (終わると自動で使えるようになる) |

シミュレータでは、Mac 本体のモデルを使う。Mac で Apple Intelligence がオンになっている必要がある。

## Gemma 4

Google の [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) (Swift Package) で動かす。モデルは [Hugging Face](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) の `gemma-4-E2B-it.litertlm` で、アプリには同梱せず、ユーザーが「ダウンロード」を押したときに取得して Application Support に保存する。設定から削除できる。

実機では GPU、シミュレータでは CPU で動く。LiteRT-LM が Apple シリコン用のシミュレータにしか対応していないので、シミュレータ向けビルドは arm64 のみ。

## ビルド

`AIThinkin.xcodeproj` を Xcode で開いて実行する。コマンドラインでは次のとおり。

```bash
xcodebuild -project AIThinkin.xcodeproj -scheme AIThinkin \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build build
```

実機で動かすときは、Xcode の Signing & Capabilities で開発チームを選ぶ。バンドル ID は `one.tachy.aithinkin` (仮。あとで変える予定)。

## 構成

- `Sources/InfoPlist.xcstrings`: ホーム画面に出るアプリ名 (日本語は「AIシンくん」、英語は「aithinkin」)。
- `Sources/ChatStore.swift`: 会話の状態、保存、モデルとのやり取り。
- `Sources/GemmaDownload.swift`: Gemma 4 のモデルファイルのダウンロードと削除。
- `Sources/ChatScreen.swift`, `Sources/SettingsScreen.swift`: 画面。
- `../tachyon/Shared/MarkdownView.swift`, `Zoom.swift`: Mac 版・iOS 版と共通の Markdown 表示。プロジェクトはこの 2 ファイルだけを参照している。

端末内モデルが一度に扱える文章量は小さい。長い会話を再開するときは、直近のやり取りだけをモデルに渡す。

アプリのアイコンは仮のもの。`swift scripts/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` で作り直せる。
