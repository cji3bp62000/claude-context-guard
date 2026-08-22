# context-guard

*[English](README.md) | 日本語*

Claude Code のトークン消費は、作業量ではなく **コンテキストサイズ** にほぼ比例します。
長いセッションを畳まずに続けると、ほんの数語の微調整でも毎ターン全文脈ぶんが再課金されます。

このプラグインは、その課金が発生する **前** に割り込んで止めます。

## 何が起きるのか（実測）

3時間畳まずに作業し、コンテキストが 27.5万トークンまで膨らんだセッションの記録:

| 時間帯 | API呼出 | cache読込 | 消費シェア |
|---|---|---|---|
| 実装フェーズ | 104 | 14.1M | 28% |
| **微調整フェーズ（32分）** | **47** | **10.3M** | **20〜32%** |

「ふわっと動かして」「ease out にして」程度の指示47回が、5時間枠の 2〜3割を消費しています。
内訳は cache読込が 68%、cache書込が 23%。書込が膨らんだのは2時間の離席で
プロンプトキャッシュ（TTL 1時間）が失効し、再開1発目に 20.7万トークンを丸ごと書き直したためです。

**モデル自身はこれを警告できません。** プロンプトを読んだ時点で、その高額な読み込みはすでに課金済みだからです。
`UserPromptSubmit` フックは API 呼び出しの前に走るので、ここでしか止められません。

## 動作

**送信前（UserPromptSubmit）** — コンテキストが **8万トークンを超え、かつ前回のやり取りから 55分以上経過**している（＝プロンプトキャッシュが失効している）ときに送信をブロックします。ブロック時は API 呼び出しが発生しないため、警告自体のコストはゼロです。

```
⚠ Context 243,000 tokens / 134 min since last activity
  The prompt cache (1h TTL) has expired, so sending this will rewrite about 243,000 tokens.

  [1] /compact      Continuing this work (keeps the thread; pays off in 2-3 turns)
  [2] /clear        Switching topics (free)
  [3] Continue      Send the same text again (no warning for the next 30 min)
```

3択目が肝です。**同じ内容をもう一度送ることが「続行」の意思表示**になり、以後30分はスヌーズされます。
入力内容は ↑ キーで復元できます。復元できなかった場合は先にスラッシュコマンドを打ってください
（`/compact` や `/clear` などは常に素通りします）。

### /compact と /clear の使い分け

| | コスト |
|---|---|
| そのまま続行 | 1ターンあたり全文脈ぶん（27.5万なら約28k相当）が延々と続く |
| `/compact` | 一度きり約2ターン分、以降は1ターン3k程度 |
| `/clear` | 0、以降も3k程度。ただし文脈は消える |

- **`/compact`** — 作業が地続きで、直前の設計判断や経緯を引き継ぎたいとき。2〜3ターン続けるなら元が取れます。
- **`/clear`** — 話題が変わるとき、または「このファイルのここを直す」で完結するとき。

**離席する前に畳むのが最も効きます。** 戻ってから畳んでも、失効ぶんの書き直しコストはもう払い終わっています。

## インストール

```
/plugin marketplace add cji3bp62000/claude-context-guard
/plugin install context-guard
```

反映されないときは `/hooks` を一度開く（設定がリロードされます）か、Claude Code を再起動してください。

## 設定

```
/context-guard:config                          現在のしきい値を表示
/context-guard:config 下限を6万にして          変更（settings.json を書き換えます）
```

中身は環境変数です。手で書いてもかまいません。**変更の反映には Claude Code の再起動が必要です**（環境変数はプロセス起動時に読まれるため）。

```json
{
  "env": {
    "CONTEXT_GUARD_STALE_TOKENS": "60000",
    "CONTEXT_GUARD_STALE_MINUTES": "50"
  }
}
```

| 環境変数 | 既定値 | 意味 |
|---|---|---|
| `CONTEXT_GUARD_STALE_TOKENS` | 80000 | 「キャッシュ失効かつ中規模」と判定する下限 |
| `CONTEXT_GUARD_STALE_MINUTES` | 55 | この分数以上空いたらキャッシュ失効とみなす |
| `CONTEXT_GUARD_SNOOZE_MINUTES` | 30 | 一度警告したら次はこの時間スルー |
| `CONTEXT_GUARD_TEST` | — | `1` にするとしきい値が1になり必ず発火。動作確認用 |

### しきい値の決め方

**実測した被害に直接対応しているのがキャッシュ失効**（`STALE_TOKENS` + `STALE_MINUTES`）で、
このプラグインが発火するのはこの条件だけです。`STALE_MINUTES` はキャッシュ TTL（1時間）の
少し手前に置いてください。もっと小さいセッションでも警告してほしいなら `STALE_TOKENS` を下げます。
ブロック自体のコストはゼロなので、うるさいと感じるかどうかだけが判断材料です。

状態は `~/.claude/context-guard-state.json`（Windows）/ `context-guard-state.tsv`（mac/Linux）に保存され、7日で自動的に掃除されます。

## 動作確認

しきい値を無視して必ず発火させます。

```
CONTEXT_GUARD_TEST=1 claude          # macOS / Linux
$env:CONTEXT_GUARD_TEST='1'; claude  # Windows
```

何か送信すればブロックされるはずです。確認できたら環境変数を外してください。

## プラットフォーム対応

| OS | スクリプト | 状態 |
|---|---|---|
| Windows | `scripts/context-guard.ps1` | 動作確認済み |
| macOS / Linux | `scripts/context-guard.sh` | ロジックは Git Bash 上で検証済み（ブロック / スヌーズ / スラッシュ素通りが PowerShell 版と一致）。**実機 macOS / Linux では未検証** |

macOS では GNU `date` が無いため BSD `date` にフォールバックする経路を通ります。ここだけは実機で踏まれていません。

両方がフックに登録され、それぞれ自分の担当外プラットフォームでは即座に何もせず終了します。

- **mac/Linux で PowerShell (`pwsh`) を入れていない場合**、powershell 側のフックエントリが毎ターン起動に失敗します。動作はブロックされませんが気になる場合は、フォークして `hooks/hooks.json` から powershell エントリを削除してください。
- **Windows で Git Bash が無い場合**、bash 側のエントリが同様に失敗します。ガード本体は PowerShell 版が担当するので保護は効いています。
- mac/Linux 版は `jq` があればそれを使い、無ければ簡易的な文字列抽出にフォールバックします。

## 仕組み

`transcript_path` で渡される JSONL の末尾から、直近の `usage`（`cache_read_input_tokens` + `cache_creation_input_tokens` + `input_tokens`）と `timestamp` を読み、現在のコンテキストサイズと最終活動からの経過時間を求めています。

フック自身の失敗でセッションを止めないよう、想定外のことが起きた場合は必ず exit 0 で素通りします。

## ライセンス

[Unlicense](LICENSE)（パブリックドメイン）。自由に使い、改変し、再配布してください。
