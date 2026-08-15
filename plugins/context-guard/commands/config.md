---
description: context-guard のしきい値を確認・変更する
allowed-tools: Read, Edit, Write
---

context-guard のしきい値を確認・変更します。

ユーザーの要望: $ARGUMENTS

## 手順

1. `~/.claude/settings.json`（Windows は `%USERPROFILE%\.claude\settings.json`）を Read する。
   環境変数 `CLAUDE_CONFIG_DIR` が設定されていればそちらを優先。
2. `env` オブジェクトの中の `CONTEXT_GUARD_*` を読み取り、現在値を表にして示す。
   未設定のものは既定値を「（既定）」と添えて示す。
3. 変更の要望があれば `env` にマージする。**既存のキーを消さないこと。**
   値は必ず文字列（例: `"180000"`）で書く。
4. 変更したら「反映には Claude Code の再起動が必要」と伝える。
   環境変数はプロセス起動時に読み込まれるため。

## しきい値一覧

| 環境変数 | 既定値 | 意味 |
|---|---|---|
| `CONTEXT_GUARD_BLOCK_TOKENS` | 150000 | これを超えたら無条件でブロック |
| `CONTEXT_GUARD_STALE_TOKENS` | 80000 | 「キャッシュ失効かつ中規模」と判定する下限 |
| `CONTEXT_GUARD_STALE_MINUTES` | 55 | この分数以上空いたらキャッシュ失効とみなす |
| `CONTEXT_GUARD_SNOOZE_MINUTES` | 30 | 一度警告したら次はこの時間スルー |
| `CONTEXT_GUARD_NOTIFY_TOKENS` | 200000 | Stop 通知の下限 |
| `CONTEXT_GUARD_NOTIFY_BUCKET` | 50000 | Stop 通知はこの刻みで1回だけ |

書き込み例:

```json
{
  "env": {
    "CONTEXT_GUARD_BLOCK_TOKENS": "180000"
  }
}
```
