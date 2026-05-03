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

## このフォークの主な改良点

- **日本語ローカライズ** を追加・整備
- **ダーク外観に正式対応**（Apple HIG 準拠 / 可読性改善）
- **履歴 / スニペットのポップアップをキャレット位置に表示**（入力欄基準、取れない場合はマウス位置にフォールバック）
- **ステータスアイコンに「なし」を追加**（メニューバーから完全に隠せる）
- スニペットメニューの見た目・フォントサイズ・表示位置を履歴メニューと統一
- 環境設定の UI 整理（タブの等間隔化、「Beta」→「拡張」リネーム）
- ペースト処理の最適化と Apple Silicon（arm64）リリース対応
- 履歴メニューの検索機能を削除（日本語入力下で動作が不安定だったため）

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
