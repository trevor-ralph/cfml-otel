# Integration tests: drives tests/app on each engine in dev/docker-compose.yml and verifies the
# results in Tempo (traces), Prometheus (metrics) and Loki (logs) through Grafana's datasource proxy.
# Exit code = number of failed assertions.
param(
  [string[]]$Engines = @('lucee7', 'lucee6', 'acf', 'acf2023'),
  [int]$ExportWaitSeconds = 15,
  [string]$Grafana = 'http://localhost:3000'
)
$ErrorActionPreference = 'Stop'

$targets = @{
  lucee7 = @{ port = 8971; service = 'cfml-otel-lucee7' }
  lucee6 = @{ port = 8961; service = 'cfml-otel-lucee6' }
  acf    = @{ port = 8951; service = 'cfml-otel-acf2025' }
  acf2023 = @{ port = 8941; service = 'cfml-otel-acf2023' }
}

function New-Hex([int]$bytes) { -join ((1..$bytes) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) }) }
function B64ToHex([string]$s) { if (-not $s) { return '' }; -join ([Convert]::FromBase64String($s) | ForEach-Object { '{0:x2}' -f $_ }) }
function Get-Json([string]$url, [hashtable]$headers = @{}) {
  (Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $url -Headers $headers).Content | ConvertFrom-Json
}
function Get-DsUid([string]$name) { (Invoke-RestMethod "$Grafana/api/datasources/name/$name").uid }

function Get-Spans([string]$traceId) {
  $tr = Invoke-RestMethod "$Grafana/api/datasources/proxy/uid/$script:tempo/api/v2/traces/$traceId"
  foreach ($rs in $tr.trace.resourceSpans) { foreach ($ss in $rs.scopeSpans) { foreach ($sp in $ss.spans) {
    $attrs = @{}
    foreach ($a in $sp.attributes) { $attrs[$a.key] = $a.value }
    [pscustomobject]@{
      name = $sp.name; kind = $sp.kind; id = (B64ToHex $sp.spanId); parent = (B64ToHex $sp.parentSpanId)
      status = $sp.status.code; events = @($sp.events | ForEach-Object { $_.name }); eventObjs = $sp.events; attrs = $attrs
    }
  } } }
}

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$engine, [string]$name, [bool]$pass, [string]$detail = '') {
  $results.Add([pscustomobject]@{ engine = $engine; check = $name; result = $(if ($pass) { 'PASS' } else { 'FAIL' }); detail = $detail })
}
function Note([string]$engine, [string]$name, [string]$detail) {
  $results.Add([pscustomobject]@{ engine = $engine; check = $name; result = 'NOTE'; detail = $detail })
}

$script:tempo = Get-DsUid 'Tempo'
$prom = Get-DsUid 'Prometheus'
$loki = Get-DsUid 'Loki'
$runs = @{}

# ---- Phase 1: drive the scenarios ------------------------------------------------------------
foreach ($e in $Engines) {
  $t = $targets[$e]
  $base = "http://localhost:$($t.port)/cfml-otel/tests/app"
  $T = New-Hex 16
  $P = New-Hex 8
  $r = Get-Json "$base/scenarios.cfm?reinit=1" @{ traceparent = "00-$T-$P-01" }

  # Leak protection: leak a scope, then hammer the pool and make sure nobody inherits it.
  $leak = Get-Json "$base/leak.cfm"
  $bad = 0
  1..40 | ForEach-Object {
    $ct = New-Hex 16
    $c = Get-Json "$base/check.cfm" @{ traceparent = "00-$ct-$(New-Hex 8)-01" }
    if ($c.traceId -ne $ct) { $bad++ }
  }
  $runs[$e] = @{ T = $T; P = $P; r = $r; leakBad = $bad; leak = $leak; started = [DateTimeOffset]::UtcNow.AddMinutes(-5) }
}

"waiting $ExportWaitSeconds s for export..."
Start-Sleep -Seconds $ExportWaitSeconds

# ---- Phase 2: verify ---------------------------------------------------------------------------
foreach ($e in $Engines) {
  $run = $runs[$e]; $r = $run.r; $T = $run.T; $sc = $r.scenarios; $svc = $targets[$e].service
  $failed = @($sc.PSObject.Properties | Where-Object { -not $_.Value.ok } | ForEach-Object { "$($_.Name): $($_.Value.error)" })
  Check $e 'all scenarios ran without error' ($failed.Count -eq 0) ($failed -join ' || ')
  Check $e 'status: enabled + agentBridged + active' ($r.status.enabled -and $r.status.agentBridged -and $r.status.active) ($r.status | ConvertTo-Json -Compress)
  Check $e 'request continues incoming trace' ($r.traceId -eq $T) $r.traceId

  $spans = @(Get-Spans $T)
  $byName = @{}; foreach ($s in $spans) { $byName[$s.name] = $s }
  $server = $spans | Where-Object { $_.kind -eq 'SPAN_KIND_SERVER' -and $_.parent -eq $run.P } | Select-Object -First 1
  Check $e 'Tempo has the SERVER span' ($null -ne $server -and $server.id -eq $r.serverSpanId) "server=$($server.id) expected=$($r.serverSpanId)"
  $sid = $r.serverSpanId

  $n = $sc.nested.value
  Check $e 'nested: return value + context' ($n.returned -eq 'ret' -and $n.innerTraceId -eq $T -and $n.currentInInner -eq $n.innerSpanId -and $n.currentAfter -eq $sid)
  Check $e 'nested: Tempo parentage' ($byName['s2.outer'].parent -eq $sid -and $byName['s2.inner'].parent -eq $byName['s2.outer'].id)
  $a = $byName['s2.outer'].attrs
  $typed = $a['t.str'].stringValue -eq 'x' -and "$($a['t.num'].intValue)" -eq '42' -and $a['t.dbl'].doubleValue -eq 1.5 -and $a['t.bool'].boolValue -eq $true `
    -and (@($a['t.arr'].arrayValue.values | ForEach-Object { $_.stringValue }) -join ',') -eq 'a,b' `
    -and (@($a['t.nums'].arrayValue.values | ForEach-Object { $_.intValue }) -join ',') -eq '1,2,3'
  Check $e 'nested: attribute types (str/int/double/bool/arrays)' $typed (($a.Keys | Sort-Object | ForEach-Object { "$_=$($a[$_] | ConvertTo-Json -Compress -Depth 5)" }) -join ' ')

  $x = $sc.exception.value
  $f = $byName['s3.fails']
  Check $e 'exception: rethrown with original type, context restored' ($x.thrown -and $x.type -eq 'Custom.Fail' -and $x.currentAfter -eq $sid)
  Check $e 'exception: span ERROR + exception event' ($f.status -eq 'STATUS_CODE_ERROR' -and $f.events -contains 'exception') "status=$($f.status) events=$($f.events -join ',')"
  $jx = $byName['s14.java-exception']
  $jxType = ($jx.eventObjs | Where-Object name -eq 'exception' | ForEach-Object { ($_.attributes | Where-Object key -eq 'exception.type').value.stringValue }) -join ','
  Check $e 'java exception: recorded with Java type' ($jxType -match 'NumberFormatException|Exception') "exception.type=$jxType"

  Note $e 'cfthread without bindContext (expected: context lost)' "traceId=$($sc.cfthreadUnbound.value) same=$($sc.cfthreadUnbound.value -eq $T)"
  Check $e 'cfthread + bindContext: same trace, parent = SERVER' ($sc.cfthreadBound.value.traceId -eq $T -and $byName['s4.in-thread'].parent -eq $sid)
  Check $e 'runAsync: same trace, parent = SERVER' ($sc.runAsync.value.traceId -eq $T -and $byName['s5.async'].parent -eq $sid)

  $m = $sc.manual.value
  Check $e 'manual startSpan/makeCurrent/closeScope' ($m.currentInside -eq $m.spanId -and $m.currentAfter -eq $sid -and $byName['s6.child'].parent -eq $m.spanId -and $byName['s6.manual'].parent -eq $sid)

  $h = $sc.cfhttp.value
  $sentTrace = ($h.sent -split '-')[1]; $recvTrace = ($h.received -split '-')[1]
  Check $e 'cfhttp: injected traceparent is this trace' ($sentTrace -eq $T -and $byName['s7.client'].kind -eq 'SPAN_KIND_CLIENT')
  if ($recvTrace -eq $T) { Check $e 'cfhttp: downstream received this trace' $true $h.received }
  else { Note $e 'cfhttp: downstream received a DIFFERENT trace (agent overwrote header on a worker thread; LDEV-6519)' "sent=$($h.sent) received=$($h.received)" }

  $x8 = $sc.extract.value
  $remote = @(Get-Spans $x8.expectTraceId) | Where-Object name -eq 's8.remote-parent'
  Check $e 'extractContext: span joins remote trace + parent' ($x8.traceId -eq $x8.expectTraceId -and $remote.parent -eq $x8.expectParentId)
  Check $e 'root span: new trace' ($sc.root.value -and $sc.root.value -ne $T)
  Check $e 'disabled instance: no-op' ($sc.disabled.value.value -eq 5 -and -not $sc.disabled.value.enabled -and $sc.disabled.value.traceId -eq '')
  Check $e 'currentSpan().end() did not end SERVER span' ($byName['s15.after-borrowed-end'].parent -eq $sid)
  Check $e 'leaked scope closed at request end (40 pooled requests clean)' ($run.leakBad -eq 0) "requests inheriting a stale trace: $($run.leakBad)"

  # Metrics
  $q = [uri]::EscapeDataString("{__name__=~`"cfmlotel_test.*`",job=`"$svc`"}")
  $pm = Invoke-RestMethod "$Grafana/api/datasources/proxy/uid/$prom/api/v1/query?query=$q"
  $names = @($pm.data.result | ForEach-Object { $_.metric.__name__ } | Sort-Object -Unique)
  $want = 'calls', 'latency', 'level', 'inflight'
  $missing = @($want | Where-Object { $w = $_; -not ($names | Where-Object { $_ -like "cfmlotel_test_$w*" }) })
  Check $e 'metrics: counter/histogram/gauge/up-down in Prometheus' ($missing.Count -eq 0) "found: $($names -join ', ')"

  # Logs
  $lg = $sc.logs.value
  $lq = [uri]::EscapeDataString("{service_name=`"$svc`"} |= `"$($lg.marker)`"")
  $startNs = [string]($run.started.ToUnixTimeMilliseconds() * 1000000)
  $lr = Invoke-RestMethod "$Grafana/api/datasources/proxy/uid/$loki/loki/api/v1/query_range?query=$lq&start=$startNs&limit=20"
  $lines = @($lr.data.result | ForEach-Object { $_.values } )
  $traced = @($lr.data.result | Where-Object { $_.stream.trace_id -eq $T })
  Check $e 'logs: records in Loki' ($lines.Count -ge 2) "found $($lines.Count) line(s)"
  Check $e 'logs: correlated with trace_id' ($traced.Count -ge 1) (($lr.data.result | ForEach-Object { "trace_id=$($_.stream.trace_id) sev=$($_.stream.detected_level)$($_.stream.severity_text)" }) -join '; ')
}

$results | Format-Table engine, result, check, @{l = 'detail'; e = { if ($_.result -ne 'PASS') { $_.detail } else { '' } } } -AutoSize -Wrap | Out-String -Width 250
$outDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $outDir | Out-Null
$results | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $outDir 'integration-results.json')
$runs.GetEnumerator() | ForEach-Object { @{ engine = $_.Key; response = $_.Value.r } } | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 (Join-Path $outDir 'scenario-responses.json')
"== Non-passing checks"
$results | Where-Object result -ne 'PASS' | ForEach-Object { "  [$($_.engine)] $($_.result) $($_.check)`n      $($_.detail)" }
$fails = @($results | Where-Object result -eq 'FAIL').Count
"$fails failed, $(@($results | Where-Object result -eq 'PASS').Count) passed, $(@($results | Where-Object result -eq 'NOTE').Count) notes"
exit $fails
