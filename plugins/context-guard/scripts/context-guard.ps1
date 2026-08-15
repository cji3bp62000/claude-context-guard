<#
.SYNOPSIS
  コンテキスト肥大とプロンプトキャッシュ失効による無駄なトークン消費を防ぐフック（Windows / PowerShell 版）。

.DESCRIPTION
  -Mode Submit (UserPromptSubmit):
    送信前に走る。文脈が大きい / キャッシュが失効していると exit 2 で送信をブロックし、
    /compact・/clear・そのまま続行 の3択を提示する。ブロック時はAPI呼び出しが発生しない。
    同じ内容をもう一度送ればスヌーズ期間中はスルーされる（＝「そのまま続ける」）。

  -Mode Stop (Stop):
    ターン終了時に走る。ブロックはせず、文脈が一定量を超えたときだけ1行通知する。

  入力は stdin の JSON（transcript_path, session_id, prompt など）。
  しきい値は環境変数で上書きできる（README 参照）。
#>
[CmdletBinding()]
param(
    [ValidateSet('Submit', 'Stop')]
    [string]$Mode = 'Submit'
)

# 非Windowsでは何もしない（同梱の .sh 版が担当する）
if ($null -ne $IsWindows -and -not $IsWindows) { exit 0 }

function Get-Threshold {
    param([string]$Name, [int]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($v, [ref]$parsed)) { return $parsed }
    return $Default
}

# --- しきい値（環境変数で上書き可） -----------------------------------------
$BlockCtx      = Get-Threshold 'CONTEXT_GUARD_BLOCK_TOKENS'   150000  # これを超えたら無条件でブロック
$StaleCtx      = Get-Threshold 'CONTEXT_GUARD_STALE_TOKENS'    80000  # 「キャッシュ失効かつ中規模」の下限
$StaleMinutes  = Get-Threshold 'CONTEXT_GUARD_STALE_MINUTES'      55  # プロンプトキャッシュのTTLは1時間
$SnoozeMinutes = Get-Threshold 'CONTEXT_GUARD_SNOOZE_MINUTES'     30  # 一度警告したら次はこの時間スルー
$NotifyCtx     = Get-Threshold 'CONTEXT_GUARD_NOTIFY_TOKENS'  200000  # Stop通知の下限
$NotifyBucket  = Get-Threshold 'CONTEXT_GUARD_NOTIFY_BUCKET'   50000  # Stop通知はこの刻みで1回だけ

# 動作確認用: CONTEXT_GUARD_TEST=1 でしきい値を極端に下げ、必ず発火させる
if ($env:CONTEXT_GUARD_TEST -eq '1') {
    $BlockCtx = 1; $StaleCtx = 1; $StaleMinutes = 0; $SnoozeMinutes = 1
    $NotifyCtx = 1; $NotifyBucket = 1
}

$StateDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$StatePath = Join-Path $StateDir 'context-guard-state.json'

# 日本語がターミナルで化けないように
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding  = [Text.UTF8Encoding]::new($false)
} catch { }

# 何があってもセッションを壊さない。異常時は素通り（exit 0）。
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $transcript = $payload.transcript_path
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }

    $sessionId = if ($payload.session_id) { $payload.session_id } else { 'unknown' }
    $prompt    = if ($payload.prompt) { [string]$payload.prompt } else { '' }

    # スラッシュコマンド自体（/compact, /clear など）は止めない
    if ($Mode -eq 'Submit' -and $prompt.TrimStart().StartsWith('/')) { exit 0 }

    # --- transcript から最新の文脈サイズと最終活動時刻を拾う ---------------
    # 末尾だけ読む。1行が巨大なことがあるので usage を含む行だけ JSON にする。
    $tail = Get-Content -LiteralPath $transcript -Tail 60 -Encoding UTF8 -ErrorAction Stop

    # ISO文字列はConvertFrom-Jsonに Kind=Unspecified のDateTimeへ変換され、Zが落ちる。
    # それをToUniversalTime()に渡すと更にUTC変換されて時差ぶんずれるので、生の文字列から読む。
    $nowSec = [int64]([datetimeoffset](Get-Date)).ToUnixTimeSeconds()

    $ctx     = 0
    $lastSec = $null
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $line = $tail[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '"usage"') { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        $usage = $entry.message.usage
        if (-not $usage) { continue }
        $read  = [int]($usage.cache_read_input_tokens     | ForEach-Object { $_ })
        $write = [int]($usage.cache_creation_input_tokens | ForEach-Object { $_ })
        $inp   = [int]($usage.input_tokens                | ForEach-Object { $_ })
        $ctx   = $read + $write + $inp
        if ($line -match '"timestamp"\s*:\s*"([^"]+)"') {
            try { $lastSec = [int64]([datetimeoffset]::Parse($matches[1])).ToUnixTimeSeconds() } catch { }
        }
        break
    }
    if ($ctx -le 0) { exit 0 }

    $gapMin = if ($null -ne $lastSec) { [int](($nowSec - $lastSec) / 60) } else { 0 }

    # --- 状態ファイル -------------------------------------------------------
    # 状態も epoch 秒で持つ（ISO文字列はJSON往復でDateTime化されて壊れる）
    $state = @{}
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $loaded = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { }
    }
    $entryKey = "$Mode`:$sessionId"
    $mine     = $state[$entryKey]

    function Save-State {
        param($Table, $Now)
        # 古いセッションが溜まらないよう7日で掃除
        $cutoff = $Now - (7 * 24 * 60 * 60)
        $keep = @{}
        foreach ($k in $Table.Keys) {
            $at = $Table[$k].at
            if ($null -eq $at) { continue }
            if ([int64]$at -gt $cutoff) { $keep[$k] = $Table[$k] }
        }
        $dir = Split-Path -Parent $StatePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($keep | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }

    $ctxK = '{0:N0}' -f $ctx

    if ($Mode -eq 'Stop') {
        # ---- ターン終了時: ブロックせず1行だけ ----------------------------
        if ($ctx -lt $NotifyCtx) { exit 0 }
        $bucket = [math]::Floor($ctx / $NotifyBucket)
        if ($mine -and [int]$mine.bucket -ge $bucket) { exit 0 }
        $state[$entryKey] = @{ at = $nowSec; bucket = $bucket }
        Save-State $state $nowSec

        $msg = "コンテキストが $ctxK トークンです。次の話題に移るなら /clear、続きなら /compact を検討してください（1ターンあたりこの全量が再課金されます）"
        Write-Output (@{ systemMessage = $msg } | ConvertTo-Json -Compress)
        exit 0
    }

    # ---- 送信前: 条件を満たさなければ素通り --------------------------------
    $stale  = ($gapMin -ge $StaleMinutes -and $ctx -ge $StaleCtx)
    $tooBig = ($ctx -ge $BlockCtx)
    if (-not ($stale -or $tooBig)) { exit 0 }

    # 直近で警告済みなら「そのまま続ける」の意思表示とみなして通す
    if ($mine -and $null -ne $mine.at) {
        $sinceMin = ($nowSec - [int64]$mine.at) / 60.0
        if ($sinceMin -lt $SnoozeMinutes) { exit 0 }
    }

    $state[$entryKey] = @{ at = $nowSec; bucket = 0 }
    Save-State $state $nowSec

    # ---- 警告してブロック（API呼び出しは発生しない） -----------------------
    $head = if ($stale) {
        "コンテキスト $ctxK トークン / 前回のやり取りから ${gapMin}分経過`n" +
        "  プロンプトキャッシュ(TTL 1時間)が失効しているため、このまま送ると約 $ctxK トークンの書き直しが発生します。"
    } else {
        "コンテキスト $ctxK トークン`n" +
        "  このまま続けると、小さな修正でも毎ターン $ctxK トークンぶんが再課金されます。"
    }

    $lines = @(
        ''
        "⚠ $head"
        ''
        '  [1] /compact          作業の続きなら（経緯を引き継ぐ。2〜3ターンで元が取れる）'
        '  [2] /clear            話題が変わるなら（コスト0）'
        "  [3] そのまま続ける     同じ内容をもう一度送信（以後${SnoozeMinutes}分は警告しません）"
        ''
    )
    [Console]::Error.WriteLine(($lines -join "`n"))
    exit 2
}
catch {
    # フック自身の失敗でユーザーを止めない
    exit 0
}
