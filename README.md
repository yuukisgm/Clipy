<div align="center">
  <img src="./Resources/clipy_logo.png" width="400">
</div>

<br>

Clipy は macOS 用のクリップボード拡張アプリです。
このリポジトリは [Clipy/Clipy](https://github.com/Clipy/Clipy) / [harryzjm/Clipy](https://github.com/harryzjm/Clipy) からのフォークで、**日本語環境での実用性向上・UI 統一・安定化** を中心に独自改修を加えています。

---

## ダウンロード

最新ビルドは [Releases](https://github.com/yuukisgm/Clipy/releases/latest) から取得できます。お使いの Mac に合わせて以下をダウンロードし、開いて `Clipy.app` を `Applications` フォルダにドラッグしてください。

| Mac | ファイル |
|---|---|
| Apple Silicon（M1 以降） | `Clipy_<version>_AppleSilicon.dmg` |
| Intel | `Clipy_<version>_Intel.dmg` |

> **⚠️ 初回起動時の必須手順**
> 本アプリは未署名のため、ダウンロード後そのまま開くと「壊れているため開けません」と表示されます。
> アプリケーションフォルダにコピーした後、**必ずターミナルで以下を実行**してください。
>
> ```sh
> xattr -cr /Applications/Clipy.app
> ```
>
> 実行後はダブルクリックで起動できます。

## 動作要件

- macOS 11 Big Sur 以降（Apple Silicon / Intel 両対応）
- ソースからビルドする場合: Xcode 12.3 以上 / Swift 5

## このフォークの主な改良点

- **日本語ローカライズ** を追加・整備
- **ダーク外観に正式対応**（Apple HIG 準拠 / 可読性改善）
- **履歴 / スニペットのポップアップをキャレット位置に表示**（入力欄基準、取れない場合はマウス位置にフォールバック）
- **履歴メニューの検索機能を復活**（日本語 IME 入力に対応したフローティング検索パネル）
- **ステータスアイコンに「なし」を追加**（メニューバーから完全に隠せる）
- スニペットメニューの見た目・フォントサイズ・表示位置を履歴メニューと統一
- メニュー / サブメニュー / ツールチップの外観を Light / Dark 両対応で統一
- 環境設定の UI 整理（タブの等間隔化、「Beta」→「詳細」リネーム）
- ペースト処理の最適化と Apple Silicon（arm64）リリース対応

メニューバーからアイコンを完全に隠して見失った場合は、Finder から Clipy.app をもう一度開くとアイコンが復活します。

それでも解決しない場合はターミナルから以下を実行してください。

```sh
defaults write com.yuuki.clipy kCPYPrefStatusTypeItemKey -int 1; open /Applications/Clipy.app
```

## ソースからビルド

1. リポジトリ直下に移動
2. `pod install --repo-update` を実行
3. `Clipy.xcworkspace` を Xcode で開いてビルド

### 配布用 DMG の作成

`script/build_dmg.sh` で arm64 / x86_64 を別々の単一アーキバイナリとしてビルドし、Applications へドラッグ&ドロップ用の DMG を生成します。

```sh
./script/build_dmg.sh both    # 両方
./script/build_dmg.sh arm64   # Apple Silicon のみ
./script/build_dmg.sh x86_64  # Intel のみ
```

成果物は `dist/Clipy_<version>_AppleSilicon.dmg` / `dist/Clipy_<version>_Intel.dmg`。

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
