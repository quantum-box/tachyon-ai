# Tachyon AI (iOS)

Tachyon の iPhone / iPad アプリ。iOS 26 以降が必要 (Liquid Glass を使うため)。

## できること

- Tachyon のエージェントとチャットする。返答はストリーミングで、Markdown として表示される。
- 過去の会話を一覧から開いて、続きから再開する。
- モデルと思考量を選ぶ。
- 写真やファイルを添付する (画像とテキスト形式。合計 約3MB まで)。
- 設定の「使用量」で、今の会話とアプリ累計のトークン数と料金を見る。
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

## TestFlight への自動配信

`main` に iOS アプリか共通コードの変更が入ると、GitHub Actions (`.github/workflows/testflight.yml`) がビルドして TestFlight にアップロードする。`v*` タグと手動実行でも動く。ビルド番号には実行回数を使う。

最初に一度だけ、次の設定が必要。

1. App Store Connect で、バンドル ID `com.quantumbox.tachyonai` のアプリを作る (Apple Developer で同じバンドル ID の登録も必要)。
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

署名用の証明書は保存しない。アーカイブは署名なしで作り、書き出しのときに Xcode がクラウド上で管理する配布用証明書で署名する (API キーで認証)。

アプリのアイコンは仮のもの。`swift scripts/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` で作り直せる。

バージョン (`MARKETING_VERSION`) はプロジェクトの設定で上げる。同じバージョンのまま何度アップロードしてもよいが、App Store に出したバージョンより上である必要がある。

## 構成

- `Sources/`: iOS 専用の画面とマイク入力。
- `../macos/Sources/TachyonAI/Shared/`: Mac 版と共通のコード (ログイン、API、チャットの状態、Markdown 表示、整形、設定の各項目)。プロジェクトはこのフォルダをそのまま参照していて、ファイルを足せば自動でビルド対象になる。
