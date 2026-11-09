# Hits every engine/strategy probe with a known traceparent, prints a verdict matrix,
# then checks Tempo to confirm probe.custom is a child of the agent's SERVER span.
param([int]$TempoWaitSeconds = 8)
$ErrorActionPreference = 'Stop'

$targets = @(
  @{ name = 'lucee6';           port = 8861; strategies = 'none','loadpaths','maven','osgi' },
  @{ name = 'lucee7';           port = 8871; strategies = 'none','loadpaths','maven','osgi' },
  @{ name = 'lucee7-serverlib'; port = 8872; strategies = 'none' },
  @{ name = 'acf';              port = 8851; strategies = 'none','loadpaths' },
  @{ name = 'acf-serverlib';    port = 8852; strategies = 'none' }
)
$checks = 'currentSpan','customSpan','customSpanViaInterface','cfthreadImplicit','cfthreadManualContext','runAsync','cfhttpNoTimeout','cfhttpWithTimeout'

function New-Hex([int]$bytes) { -join ((1..$bytes) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) }) }
function B64ToHex([string]$s) { if (-not $s) { return '' }; -join ([Convert]::FromBase64String($s) | ForEach-Object { '{0:x2}' -f $_ }) }

$outDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $outDir | Out-Null
$rows = @(); $raw = @()

foreach ($t in $targets) {
  foreach ($s in $t.strategies) {
    $traceId = New-Hex 16
    $url = "http://localhost:$($t.port)/$s/index.cfm"
    $row = [ordered]@{ target = $t.name; strategy = $s; traceId = $traceId }
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $url -Headers @{ traceparent = "00-$traceId-$(New-Hex 8)-01" }
      $j = $resp.Content | ConvertFrom-Json
      $raw += [pscustomobject]@{ target = $t.name; strategy = $s; result = $j }
      $row.engine = $j.engine
      $row.apiVisible = $j.verdict.apiVisible
      $row.bridged = $j.verdict.bridgedToAgent
      foreach ($c in $checks) {
        $row[$c] = if (-not $j.$c.ok) { 'ERR' } elseif ($j.verdict."${c}InIncomingTrace") { 'same' } else { 'other' }
      }
    } catch {
      $row.engine = "REQUEST FAILED: $($_.Exception.Message)"
    }
    $rows += [pscustomobject]$row
  }
}

$raw | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 (Join-Path $outDir 'probe-results.json')
"`n== Probe matrix ('same' = in the incoming trace, 'other' = different/invalid trace, ERR = threw)"
$rows | Format-Table target, strategy, apiVisible, bridged, @{l='current';e={$_.currentSpan}}, @{l='custom';e={$_.customSpan}}, @{l='custom/iface';e={$_.customSpanViaInterface}},
  @{l='thread';e={$_.cfthreadImplicit}}, @{l='thread+ctx';e={$_.cfthreadManualContext}}, @{l='runAsync';e={$_.runAsync}},
  @{l='http';e={$_.cfhttpNoTimeout}}, @{l='http+timeout';e={$_.cfhttpWithTimeout}} -AutoSize | Out-String -Width 220

"== Errors"
foreach ($r in $raw) {
  foreach ($p in $r.result.PSObject.Properties) {
    if ($p.Value -is [pscustomobject] -and $p.Value.PSObject.Properties['ok'] -and -not $p.Value.ok) {
      "  [$($r.target)/$($r.strategy)] $($p.Name): $($p.Value.error)"
    }
  }
}
"`n== Implementation classes"
foreach ($r in $raw) {
  $g = $r.result.globalOpenTelemetry
  if ($g.ok) { "  [$($r.target)/$($r.strategy)] $($g.value.otelClass)  loader=$($g.value.otelClassLoader)" }
}

"`n== Tempo span trees (waiting $TempoWaitSeconds s for export)"
Start-Sleep -Seconds $TempoWaitSeconds
$tempoUid = (Invoke-RestMethod 'http://localhost:3000/api/datasources/name/Tempo').uid
foreach ($row in $rows) {
  try {
    $tr = Invoke-RestMethod "http://localhost:3000/api/datasources/proxy/uid/$tempoUid/api/v2/traces/$($row.traceId)"
    $spans = foreach ($rs in $tr.trace.resourceSpans) {
      $svc = ($rs.resource.attributes | Where-Object key -eq 'service.name').value.stringValue
      foreach ($ss in $rs.scopeSpans) { foreach ($sp in $ss.spans) {
        [pscustomobject]@{ svc = $svc; name = $sp.name; kind = $sp.kind; id = (B64ToHex $sp.spanId); parent = (B64ToHex $sp.parentSpanId) }
      } }
    }
    $byId = @{}; $spans | ForEach-Object { $byId[$_.id] = $_ }
    "  [$($row.target)/$($row.strategy)] $(@($spans).Count) spans"
    foreach ($sp in $spans) {
      $p = if ($sp.parent -and $byId.ContainsKey($sp.parent)) { $byId[$sp.parent].name } elseif ($sp.parent) { "(remote $($sp.parent))" } else { '(root)' }
      "      $($sp.name) [$($sp.kind)] <- $p"
    }
  } catch {
    "  [$($row.target)/$($row.strategy)] no trace in Tempo: $($_.Exception.Message)"
  }
}
