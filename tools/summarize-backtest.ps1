param(
    [string]$SourceCsv,
    [string]$OutCsv
)

$ErrorActionPreference = "Stop"

# Resolve default paths relative to this script
$scriptDir = Split-Path -Parent $PSCommandPath
$root      = Split-Path -Parent $scriptDir

if (-not $SourceCsv) {
    $SourceCsv = Join-Path $root "logs" "sim_backtest.csv"
}
if (-not $OutCsv) {
    $OutCsv = Join-Path $root "logs" "sim_backtest_summary.csv"
}

Write-Host "[INFO] summarize-backtest.ps1"
Write-Host "[INFO] Source:  $SourceCsv"
Write-Host "[INFO] Output:  $OutCsv"

if (-not (Test-Path $SourceCsv)) {
    throw "Backtest CSV not found: $SourceCsv"
}

$data = Import-Csv -Path $SourceCsv
if (-not $data -or $data.Count -eq 0) {
    throw "Backtest CSV is empty: $SourceCsv"
}

# Detect column names
$props = $data[0].PSObject.Properties.Name

# Symbol-like column
$symbolCol = @("symbol","Symbol","pair","Pair","asset","Asset") |
    Where-Object { $props -contains $_ } |
    Select-Object -First 1

# PnL % column
$pctCol = @("pnl_pct","PnlPct","PnL%","pnl_percent","pnl_pc","pnl_pcnt") |
    Where-Object { $props -contains $_ } |
    Select-Object -First 1

# Invested column
$invCol = @("avg_invested","AvgInvested","invested","Invested") |
    Where-Object { $props -contains $_ } |
    Select-Object -First 1

if (-not $pctCol) {
    $msg = "Could not find a PnL% column in $SourceCsv. Looked for: pnl_pct, PnL%, pnl_percent, etc."
    throw $msg
}

if ($symbolCol) {
    $groups = $data | Group-Object -Property $symbolCol
} else {
    # Single global group
    $groups = @(
        [PSCustomObject]@{
            Name  = "ALL"
            Group = $data
        }
    )
}

$rows = @()

foreach ($g in $groups) {
    # Collect numeric PnL% values
    $values = @()
    foreach ($row in $g.Group) {
        $raw = $row.$pctCol
        if ($null -ne $raw -and "$raw" -ne "") {
            [double]$v = 0
            if ([double]::TryParse("$raw", [ref]$v)) {
                $values += $v
            }
        }
    }

    if ($values.Count -eq 0) {
        continue
    }

    $windows = $values.Count
    $mean    = ($values | Measure-Object -Average).Average

    # Median with safe Count
    $sorted = @($values | Sort-Object)
    $cnt    = $sorted.Count
    if ($cnt -eq 0) { continue }

    if ($cnt % 2 -eq 1) {
        $median = $sorted[[int][math]::Floor($cnt / 2)]
    } else {
        $median = ($sorted[($cnt / 2) - 1] + $sorted[$cnt / 2]) / 2
    }

    $worst = ($values | Measure-Object -Minimum).Minimum
    $best  = ($values | Measure-Object -Maximum).Maximum

    # Population standard deviation
    $sumSq = 0.0
    foreach ($v in $values) {
        $sumSq += [math]::Pow($v - $mean, 2)
    }
    $var = if ($windows -gt 1) { $sumSq / $windows } else { 0.0 }
    $std = [math]::Sqrt([double]$var)

    # Average invested amount (if column exists)
    $avgInv = 0.0
    if ($invCol) {
        $invVals = @()
        foreach ($row in $g.Group) {
            $rawInv = $row.$invCol
            if ($null -ne $rawInv -and "$rawInv" -ne "") {
                [double]$w = 0
                if ([double]::TryParse("$rawInv", [ref]$w)) {
                    $invVals += $w
                }
            }
        }
        if ($invVals.Count -gt 0) {
            $avgInv = ($invVals | Measure-Object -Average).Average
        }
    }

    $rows += [PSCustomObject]@{
        Symbol        = if ($symbolCol) { $g.Name } else { "ALL" }
        Windows       = $windows
        "Mean %"      = [math]::Round($mean,   2)
        "Median %"    = [math]::Round($median, 2)
        "Worst %"     = [math]::Round($worst,  2)
        "Best %"      = [math]::Round($best,   2)
        "σ PnL%"      = [math]::Round($std,    2)
        "Avg Invested"= [math]::Round($avgInv, 2)
    }
}

if ($rows.Count -eq 0) {
    throw "No summary rows produced from $SourceCsv."
}

$rows | Export-Csv -Path $OutCsv -NoTypeInformation
Write-Host "[OK] Backtest summary written to $OutCsv"
