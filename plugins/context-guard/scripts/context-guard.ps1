<#
.SYNOPSIS
  Hook that prevents wasted tokens from context bloat and prompt-cache expiry (Windows / PowerShell).

.DESCRIPTION
  -Mode Submit (UserPromptSubmit):
    Runs before the prompt is sent. If the context is large or the cache has expired,
    exits 2 to block the send and offers three choices: /compact, /clear, or continue.
    Blocking costs nothing because no API call happens.
    Re-sending the same text within the snooze window passes through (= "continue").

  -Mode Stop (Stop):
    Runs at the end of a turn. Never blocks; prints a single line when the context
    exceeds a threshold.

  Input is JSON on stdin (transcript_path, session_id, prompt, ...).
  Thresholds can be overridden with environment variables (see README).
#>
[CmdletBinding()]
param(
    [ValidateSet('Submit', 'Stop')]
    [string]$Mode = 'Submit'
)

# Do nothing on non-Windows; the bundled .sh handles those platforms.
if ($null -ne $IsWindows -and -not $IsWindows) { exit 0 }

function Get-Threshold {
    param([string]$Name, [int]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($v, [ref]$parsed)) { return $parsed }
    return $Default
}

# --- Thresholds (overridable via environment variables) ----------------------
$BlockCtx      = Get-Threshold 'CONTEXT_GUARD_BLOCK_TOKENS'   250000  # block unconditionally above this
$StaleCtx      = Get-Threshold 'CONTEXT_GUARD_STALE_TOKENS'    80000  # floor for "cache expired and non-trivial"
$StaleMinutes  = Get-Threshold 'CONTEXT_GUARD_STALE_MINUTES'      55  # the prompt cache TTL is one hour
$SnoozeMinutes = Get-Threshold 'CONTEXT_GUARD_SNOOZE_MINUTES'     30  # stay quiet this long after a warning
$NotifyCtx     = Get-Threshold 'CONTEXT_GUARD_NOTIFY_TOKENS'  200000  # floor for the Stop notice
$NotifyBucket  = Get-Threshold 'CONTEXT_GUARD_NOTIFY_BUCKET'   50000  # notify once per bucket of this size

# For verification: CONTEXT_GUARD_TEST=1 drops every threshold so the hook always fires.
if ($env:CONTEXT_GUARD_TEST -eq '1') {
    $BlockCtx = 1; $StaleCtx = 1; $StaleMinutes = 0; $SnoozeMinutes = 1
    $NotifyCtx = 1; $NotifyBucket = 1
}

$StateDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$StatePath = Join-Path $StateDir 'context-guard-state.json'

# Keep non-ASCII output (the warning glyph) readable in the terminal.
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding  = [Text.UTF8Encoding]::new($false)
} catch { }

# Never break the session. On anything unexpected, fall through with exit 0.
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $transcript = $payload.transcript_path
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }

    $sessionId = if ($payload.session_id) { $payload.session_id } else { 'unknown' }
    $prompt    = if ($payload.prompt) { [string]$payload.prompt } else { '' }

    # Never block slash commands themselves (/compact, /clear, ...).
    if ($Mode -eq 'Submit' -and $prompt.TrimStart().StartsWith('/')) { exit 0 }

    # --- Read the current context size and last activity from the transcript --
    # Only the tail is read. Lines can be huge, so parse only those carrying usage.
    $tail = Get-Content -LiteralPath $transcript -Tail 60 -Encoding UTF8 -ErrorAction Stop

    # ConvertFrom-Json turns an ISO string into a DateTime with Kind=Unspecified,
    # dropping the trailing Z. Passing that to ToUniversalTime() shifts it again by
    # the local offset, so timestamps are parsed from the raw string instead.
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

    # --- State file ----------------------------------------------------------
    # State is stored as epoch seconds; ISO strings get mangled on a JSON round trip.
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
        # Drop entries older than 7 days so old sessions do not accumulate.
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
        # ---- End of turn: notify only, never block --------------------------
        if ($ctx -lt $NotifyCtx) { exit 0 }
        $bucket = [math]::Floor($ctx / $NotifyBucket)
        if ($mine -and [int]$mine.bucket -ge $bucket) { exit 0 }
        $state[$entryKey] = @{ at = $nowSec; bucket = $bucket }
        Save-State $state $nowSec

        $msg = "Context is $ctxK tokens. Consider /clear if you are switching topics, or /compact to carry the work forward - this full amount is re-billed every turn."
        Write-Output (@{ systemMessage = $msg } | ConvertTo-Json -Compress)
        exit 0
    }

    # ---- Before sending: pass through unless a condition matches ------------
    $stale  = ($gapMin -ge $StaleMinutes -and $ctx -ge $StaleCtx)
    $tooBig = ($ctx -ge $BlockCtx)
    if (-not ($stale -or $tooBig)) { exit 0 }

    # Already warned recently: treat the re-send as "continue anyway" and let it through.
    if ($mine -and $null -ne $mine.at) {
        $sinceMin = ($nowSec - [int64]$mine.at) / 60.0
        if ($sinceMin -lt $SnoozeMinutes) { exit 0 }
    }

    $state[$entryKey] = @{ at = $nowSec; bucket = 0 }
    Save-State $state $nowSec

    # ---- Warn and block (no API call is made) -------------------------------
    $head = if ($stale) {
        "Context $ctxK tokens / $gapMin min since last activity`n" +
        "  The prompt cache (1h TTL) has expired, so sending this will rewrite about $ctxK tokens."
    } else {
        "Context $ctxK tokens`n" +
        "  Keep going and every turn is re-billed for all $ctxK tokens, even a one-word tweak."
    }

    $lines = @(
        ''
        "⚠ $head"
        ''
        '  [1] /compact      Continuing this work (keeps the thread; pays off in 2-3 turns)'
        '  [2] /clear        Switching topics (free)'
        "  [3] Continue      Send the same text again (no warning for the next $SnoozeMinutes min)"
        ''
    )
    [Console]::Error.WriteLine(($lines -join "`n"))
    exit 2
}
catch {
    # A failure in the hook itself must never stop the user.
    exit 0
}
