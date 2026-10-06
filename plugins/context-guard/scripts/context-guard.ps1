<#
.SYNOPSIS
  Hook that prevents wasted tokens from prompt-cache expiry (Windows / PowerShell).

.DESCRIPTION
  Runs on UserPromptSubmit, before the prompt is sent. If the prompt cache has expired
  and the context is non-trivial, exits 2 to block the send and offers three choices:
  /compact, /clear, or continue. Blocking costs nothing because no API call happens.
  Re-sending the same text within the snooze window passes through (= "continue").

  Input is JSON on stdin (transcript_path, session_id, prompt, ...).
  Thresholds can be overridden with environment variables (see README).
#>

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
$StaleCtx      = Get-Threshold 'CONTEXT_GUARD_STALE_TOKENS'    80000  # floor for "cache expired and non-trivial"
$StaleMinutes  = Get-Threshold 'CONTEXT_GUARD_STALE_MINUTES'      55  # the prompt cache TTL is one hour
$SnoozeMinutes = Get-Threshold 'CONTEXT_GUARD_SNOOZE_MINUTES'     30  # stay quiet this long after a warning

# For verification: CONTEXT_GUARD_TEST=1 drops every threshold so the hook always fires.
if ($env:CONTEXT_GUARD_TEST -eq '1') {
    $StaleCtx = 1; $StaleMinutes = 0; $SnoozeMinutes = 1
}

$StateDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$StatePath = Join-Path $StateDir 'context-guard-state.json'

# Give up on stdin after this long and let the prompt through.
$StdinTimeoutMs = Get-Threshold 'CONTEXT_GUARD_STDIN_TIMEOUT_MS' 3000

# For diagnosis: CONTEXT_GUARD_TRACE=<file> appends a timestamped line per step.
function Write-Trace {
    param([string]$Step)
    if (-not $env:CONTEXT_GUARD_TRACE) { return }
    try { Add-Content -LiteralPath $env:CONTEXT_GUARD_TRACE -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $PID $Step" } catch { }
}
Write-Trace 'start'

# The console is shared with the Claude Code UI, so its encodings are left alone.
# Instead, stdin and stderr are wrapped in UTF-8 streams of our own. Setting
# [Console]::OutputEncoding / InputEncoding here coincided with the hook hanging
# until its 15 s timeout on Windows.
$Utf8 = [Text.UTF8Encoding]::new($false)

# Never break the session. On anything unexpected, fall through with exit 0.
try {
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8)
    $readTask = $reader.ReadToEndAsync()
    if (-not $readTask.Wait($StdinTimeoutMs)) {
        Write-Trace 'stdin timed out'
        exit 0
    }
    $raw = $readTask.Result
    Write-Trace 'stdin read'
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $transcript = $payload.transcript_path
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }

    $sessionId = if ($payload.session_id) { $payload.session_id } else { 'unknown' }
    $prompt    = if ($payload.prompt) { [string]$payload.prompt } else { '' }

    # Never block slash commands themselves (/compact, /clear, ...).
    if ($prompt.TrimStart().StartsWith('/')) { exit 0 }

    # --- Read the current context size and last activity from the transcript --
    # Only the tail is read. Lines can be huge, so parse only those carrying usage.
    # @() so a one-line transcript stays an array instead of being indexed per character.
    $tail = @(Get-Content -LiteralPath $transcript -Tail 60 -Encoding UTF8 -ErrorAction Stop)

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
    Write-Trace 'transcript read'
    if ($ctx -le 0) { exit 0 }

    $gapMin = if ($null -ne $lastSec) { [int](($nowSec - $lastSec) / 60) } else { 0 }

    # --- Pass through unless the cache has expired on a non-trivial context ---
    if (-not ($gapMin -ge $StaleMinutes -and $ctx -ge $StaleCtx)) { exit 0 }

    # --- State file ----------------------------------------------------------
    # State is stored as epoch seconds; ISO strings get mangled on a JSON round trip.
    $state = @{}
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $loaded = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { }
    }
    $entryKey = "Submit:$sessionId"
    $mine     = $state[$entryKey]

    # Already warned recently: treat the re-send as "continue anyway" and let it through.
    if ($mine -and $null -ne $mine.at) {
        $sinceMin = ($nowSec - [int64]$mine.at) / 60.0
        if ($sinceMin -lt $SnoozeMinutes) { exit 0 }
    }

    $state[$entryKey] = @{ at = $nowSec }

    # Drop entries older than 7 days so old sessions do not accumulate.
    $cutoff = $nowSec - (7 * 24 * 60 * 60)
    $keep = @{}
    foreach ($k in $state.Keys) {
        $at = $state[$k].at
        if ($null -eq $at) { continue }
        if ([int64]$at -gt $cutoff) { $keep[$k] = $state[$k] }
    }
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($keep | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $StatePath -Encoding UTF8

    # ---- Warn and block (no API call is made) -------------------------------
    $ctxK = '{0:N0}' -f $ctx
    $lines = @(
        ''
        "⚠ Context $ctxK tokens / $gapMin min since last activity"
        "  The prompt cache (1h TTL) has expired, so sending this will rewrite about $ctxK tokens."
        ''
        '  [1] /compact      Continuing this work (keeps the thread; pays off in 2-3 turns)'
        '  [2] /clear        Switching topics (free)'
        "  [3] Continue      Send the same text again (no warning for the next $SnoozeMinutes min)"
        ''
    )
    # Written as UTF-8 bytes so the warning glyph survives without touching the console encoding.
    $stderr = [IO.StreamWriter]::new([Console]::OpenStandardError(), $Utf8)
    $stderr.Write(($lines -join "`n") + "`n")
    $stderr.Flush()
    Write-Trace 'blocked'
    exit 2
}
catch {
    # A failure in the hook itself must never stop the user.
    exit 0
}
