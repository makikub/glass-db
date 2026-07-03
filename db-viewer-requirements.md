# DB Viewer for macOS 要件定義書

## 1. 概要

SQLite / MySQL / PostgreSQL に接続し、スキーマの閲覧とデータの編集ができる macOS ネイティブアプリ。DBeaver や JetBrains 内蔵 DB ツールの「接続 → テーブルを開く → グリッドで見る・直す」という中核体験だけを、SwiftUI + Liquid Glass デザインで最小構成として実装する。

- **プロダクト名（仮）**: GlassDB
- **配布方法**: 直接配布（Developer ID 署名 + Notarization）
- **想定ユーザー**: 開発者本人・チーム内エンジニア

## 2. ゴール / 非ゴール

### ゴール
- 3種のDB（SQLite / MySQL / PostgreSQL）への接続と切り替えがストレスなくできる
- テーブルデータの閲覧・インライン編集・行の追加/削除ができる
- 生SQLを実行して結果をグリッドで確認できる
- macOS 26 の Liquid Glass デザイン言語に沿ったモダンなUI

### 非ゴール（v1では作らない）
- ER図・ビジュアルスキーマ設計
- DDL編集（テーブル作成/変更のGUI）
- データのエクスポート/インポート（CSV等）
- SSHトンネル / SSL証明書の詳細設定UI（SSLは接続文字列レベルの対応のみ）
- クエリ履歴の全文検索、クエリプラン可視化
- 複数結果タブ、比較ビュー
- ユーザー/権限管理

## 3. 動作環境・技術スタック

| 項目 | 内容 |
|---|---|
| 対応OS | macOS 26 (Tahoe) 以降 ※Liquid Glass API を全面採用するため |
| 言語 | Swift 6（strict concurrency） |
| UI | SwiftUI（`NavigationSplitView`, `Table`, `.glassEffect()`, `GlassEffectContainer`, `Inspector`） |
| SQLite | GRDB.swift（ローカルファイル直接オープン） |
| MySQL | MySQLNIO（pure Swift, SwiftNIOベース） |
| PostgreSQL | PostgresNIO（pure Swift, SwiftNIOベース） |
| 資格情報保存 | Keychain Services |
| 配布 | Developer ID + Hardened Runtime + Notarization |
| サンドボックス | App Sandbox 有効を推奨（`com.apple.security.network.client` + user-selected file read/write） |

> pure Swift ドライバ（NIO系）を採用することで libpq / libmysqlclient の同梱・署名問題を回避し、Notarization を単純化する。

## 4. アーキテクチャ方針

### 4.1 ドライバ抽象化

3エンジンを統一的に扱うため、プロトコルで抽象化する。

```swift
protocol DatabaseDriver: Sendable {
    func connect(config: ConnectionConfig) async throws
    func schemas() async throws -> [SchemaInfo]          // DB/スキーマ一覧
    func tables(in schema: String) async throws -> [TableInfo]
    func columns(of table: TableRef) async throws -> [ColumnInfo]  // PK情報含む
    func query(_ sql: String, limit: Int?) async throws -> ResultSet
    func execute(_ sql: String) async throws -> Int      // 影響行数
    func disconnect() async
}
```

- 値の型は共通の `DBValue` enum（null / int / double / text / blob / date / json / unknown）に正規化する
- エンジン固有の識別子クオート（`` ` `` vs `"`）とプレースホルダ差はドライバ層で吸収する

### 4.2 レイヤ構成

```
SwiftUI Views
  └─ ViewModels (@Observable, MainActor)
       └─ ConnectionSession (actor, 1接続=1セッション)
            └─ DatabaseDriver (SQLite / MySQL / PostgreSQL 実装)
```

- 1ウィンドウ = 1接続セッション。複数接続は複数ウィンドウで扱う（タブ管理を作らないことで最小化）

## 5. 機能要件

### F1. 接続管理
- **F1-1** 接続の新規作成・編集・削除・複製ができる
- **F1-2** 接続設定項目: 名前 / 種別 / ホスト / ポート / DB名 / ユーザー / パスワード（SQLiteはファイルパスのみ）
- **F1-3** パスワードは Keychain に保存し、設定ファイル（接続一覧はJSONでApplication Supportに保存）には含めない
- **F1-4** 「接続テスト」ボタンで疎通確認ができる
- **F1-5** SQLite はファイル選択ダイアログ（security-scoped bookmark で再オープン可能に）
- **F1-6** 起動時はウェルカム画面に接続一覧を表示し、ダブルクリックで接続

### F2. スキーマブラウザ（サイドバー）
- **F2-1** 接続先のスキーマ/データベース → テーブル・ビューをツリー表示
- **F2-2** テーブル名のインクリメンタル検索フィルタ
- **F2-3** テーブル選択でデータグリッドを開く
- **F2-4** テーブルのコンテキストメニュー: 「データを開く」「行数を数える」「名前をコピー」
- **F2-5** 手動リフレッシュ（自動監視はしない）

### F3. データグリッド（閲覧）
- **F3-1** `SELECT * FROM <table>` をページネーション付きで表示（既定 200行/ページ、LIMIT/OFFSET）
- **F3-2** 列ヘッダクリックでソート（ORDER BY をサーバ側に反映）
- **F3-3** 簡易フィルタ: 1カラム + 演算子（= / != / LIKE / IS NULL 等）のWHERE条件を1つ指定できる
- **F3-4** NULL は視覚的に区別して表示（イタリック `NULL` バッジ等）
- **F3-5** 長大なテキスト/BLOBはセル内では省略表示、選択時にインスペクタ（右パネル）で全文表示
- **F3-6** セル値のコピー（単一セル / 行）

### F4. データ編集
- **F4-1** 主キー（またはSQLiteのrowid）を持つテーブルのみ編集可。持たない場合は読み取り専用と明示する
- **F4-2** セルのダブルクリックでインライン編集。型に応じた入力検証（数値/日付/NULL設定）
- **F4-3** 編集は即時反映ではなく「保留変更」としてマークし、ツールバーの「適用」でトランザクション実行 / 「破棄」で取り消し
- **F4-4** 行の追加・削除（削除は確認ダイアログ必須、適用時は影響行数を検証し1行でなければロールバック）
- **F4-5** 適用時に発行するSQLをプレビュー表示できる

### F5. SQLエディタ
- **F5-1** フリーフォームのSQL入力欄（等幅フォント、キーワードの簡易シンタックスハイライト）
- **F5-2** ⌘↩ で実行。SELECT系は結果グリッド表示、更新系は影響行数を表示
- **F5-3** 複数文は非対応（1文のみ）。SELECTには安全のため既定で LIMIT 1000 を自動付与（トグルで解除可）
- **F5-4** 実行中クエリのキャンセル
- **F5-5** 直近のクエリ履歴をセッション内で保持（永続化はしない）

### F6. その他
- **F6-1** ライト/ダークモード対応（システム追従）
- **F6-2** 接続断の検知とワンクリック再接続
- **F6-3** エラーはDBからのメッセージをそのまま提示（変に丸めない）

## 6. UI/UX 要件（Liquid Glass）

- **U1** レイアウトは `NavigationSplitView` の3ペイン構成: サイドバー（スキーマツリー）/ メイン（グリッド or SQLエディタ）/ インスペクタ（セル詳細・列情報）
- **U2** ツールバー・フローティングコントロール（ページャ、適用/破棄バー）に `.glassEffect()` を適用し、`GlassEffectContainer` で近接する要素のガラスをまとめる
- **U3** 保留変更バー（「3件の変更 — 適用 / 破棄」）は画面下部にフローティングのガラスカプセルとして表示
- **U4** グリッド本体は可読性優先でガラスを使わない（ガラスはナビゲーション/コントロール層のみ、というHIGの原則に従う）
- **U5** ウィンドウ状態（サイドバー幅、開いていたテーブル）を復元する
- **U6** 主要操作にキーボードショートカット: ⌘T 新規SQLエディタ、⌘R リフレッシュ、⌘S 変更適用、⌘F テーブルフィルタ

## 7. 非機能要件

| 分類 | 要件 |
|---|---|
| パフォーマンス | 10万行テーブルでも初期表示1秒以内（ページネーション前提）。UIスレッドをブロックしない（全DB I/Oはactor内でasync実行） |
| 安全性 | UPDATE/DELETE は必ず主キー条件で発行。適用はトランザクションで包み、想定外の影響行数ならロールバック |
| セキュリティ | パスワードはKeychainのみ。ログにSQL中のリテラル値やパスワードを残さない。App Sandbox + Hardened Runtime |
| 信頼性 | クエリタイムアウト既定30秒。接続断時にアプリがクラッシュしない |
| 保守性 | ドライバはプロトコル準拠で追加可能。ユニットテストはドライバ層とSQL生成（UPDATE文組み立て）を重点対象 |

## 8. 画面一覧

1. **ウェルカム / 接続一覧**: 保存済み接続のリスト + 新規作成
2. **接続編集シート**: 接続パラメータ入力 + 接続テスト
3. **メインウィンドウ**: サイドバー + データグリッド/SQLエディタ + インスペクタ
4. **設定**: 既定ページサイズ、クエリタイムアウト、LIMIT自動付与の既定値

## 9. マイルストーン案

| フェーズ | 内容 |
|---|---|
| M1 | ドライバ抽象化 + SQLite 接続・スキーマ表示・読み取り専用グリッド |
| M2 | PostgreSQL / MySQL ドライバ実装、接続管理 + Keychain |
| M3 | インライン編集（保留変更 → トランザクション適用）、行追加/削除 |
| M4 | SQLエディタ、フィルタ/ソート |
| M5 | Liquid Glass 仕上げ、ウィンドウ復元、Notarization パイプライン（CI） |

## 10. リスクと対応

- **Liquid Glass API が macOS 26 専用** → 最小ターゲットを26に固定して分岐コードを排除（社内/個人配布なら許容）
- **MySQLNIO のメンテ状況・認証方式（caching_sha2_password 等）** → M2 冒頭に接続検証スパイクを1日確保。問題があれば代替ドライバを検討
- **`Table`（SwiftUI）の大量行・動的カラム性能** → ページネーションで行数を抑制。不足なら `NSTableView` ラップにフォールバック
- **編集の安全性（PKなしテーブル）** → v1では読み取り専用に倒す。回避策は作らない
