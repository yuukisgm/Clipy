<div align="center">
  <img src="./Resources/clipy_logo.png" width="400">
</div>

<br>

Clipy は macOS 用のクリップボード拡張アプリです。
このリポジトリは [Clipy/Clipy](https://github.com/Clipy/Clipy) / [harryzjm/Clipy](https://github.com/harryzjm/Clipy) からのフォークで、**日本語環境での実用性向上・UI 統一・安定化** を中心に独自改修を加えています。

---

## 動作要件

- macOS 10.15 Catalina 以降（Apple Silicon / Intel 両対応）
- Xcode 12.3 以上 / Swift 5

## このフォークの変更点

### UI / 表示
- **ダーク外観に正式対応**（Apple HIG 準拠 / 可読性を改善）
- **ステータスアイコンに「なし」を追加**（メニューバーから完全に隠せる）
- 環境設定のタブを等間隔レイアウトに調整
- 「Beta」表記を「拡張」にリネーム
- スニペットメニューの見た目・フォントサイズ・表示位置を履歴メニューと統一
- 環境設定のラベル誤記を修正

### ポップアップ動作
- 履歴 / スニペットのポップアップを **入力欄（キャレット）位置基準** で表示
  - キャレットが取れない場合はマウス位置にフォールバック
- スニペットフォルダ別ホットキーの popUp も入力欄基準に統一
- ポップアップの初期ハイライトを修正
- **AX キャレット座標のバリデーション追加**（左下に飛ぶバグを修正）

### 履歴 / ペースト
- 履歴の重複・取り違えを修正
- 拡張（旧 Beta）修飾キーの即応化
- ペースト処理の最適化、arm64 リリース対応

### ローカライズ
- 日本語ローカライズを追加・整備

### リカバリーコマンド
- ステータス非表示時のリカバリーコマンドを絶対パスに変更
- バンドル ID を実際の値（`com.clipy-app.Clipy`）に修正

メニューバーからアイコンを完全に隠して見失った場合は、ターミナルから以下で再表示できます。

```sh
defaults delete com.clipy-app.Clipy kCPYPrefShowStatusItemKey
/Applications/Clipy.app/Contents/MacOS/Clipy &
```

## ビルド方法

1. リポジトリ直下に移動
2. `pod install --repo-update` を実行
3. `Clipy.xcworkspace` を Xcode で開く
4. ビルド

ビルド成果物（`Clipy.app`）はデスクトップに上書き出力する運用にしています。

## スニペットの移行（旧版からの取り込み）

```sh
./script/translate.py snippets.xml
```

## ライセンス

MIT License。詳細は [LICENSE](./LICENSE) を参照。アイコンの著作権は各作者に帰属します。

## Special Thanks

- [@naotaka](https://github.com/naotaka) — オリジナルの [ClipMenu](https://github.com/naotaka/ClipMenu) 作者
- [Clipy/Clipy](https://github.com/Clipy/Clipy) — 本家
- [harryzjm/Clipy](https://github.com/harryzjm/Clipy) — 検索機能などを追加したフォーク元
