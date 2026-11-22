# Tachyon AI (iOS)

Tachyon の iPhone / iPad アプリ。iOS 26 以降が必要 (Liquid Glass を使うため)。

## できること

- Tachyon のエージェントとチャットする。返答はストリーミングで、Markdown として表示される。
- 過去の会話を一覧から開いて、続きから再開する。
- モデルと思考量を選ぶ。
- 入力欄のマイクボタンで音声入力する (もう一度押すと終了し、文字が入力欄に入る)。
- 設定で、文字起こしの整形、用語辞書、背景情報、表示するモデルを変える。

Mac 版にある「fn キーを押している間の音声入力 (他のアプリへの貼り付け)」は、iOS にはない。iOS ではアプリが他のアプリに文字を入力できないため。

## ビルド

`TachyonAI.xcodeproj` を Xcode で開いて実行する。コマンドラインでは次のとおり。

```bash
xcodebuild -project TachyonAI.xcodeproj -scheme TachyonAI \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build build
```

実機で動かすときは、Xcode の Signing & Capabilities で開発チームを選ぶ。

## 構成

- `Sources/`: iOS 専用の画面とマイク入力。
- `../macos/Sources/TachyonAI/Shared/`: Mac 版と共通のコード (ログイン、API、チャットの状態、Markdown 表示、整形、設定の各項目)。プロジェクトはこのフォルダをそのまま参照していて、ファイルを足せば自動でビルド対象になる。
