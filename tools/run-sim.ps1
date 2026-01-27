param([string]$Start, [string]$End, [string]$Strategy="both")
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = (Get-Location).Path
$py   = Join-Path $root ".venv\Scripts\python.exe"
$env:PYTHONIOENCODING = "utf-8"
$args = @()
if($Start){ $args += @("--start",$Start) }
if($End){   $args += @("--end",$End) }
if($Strategy){ $args += @("--strategy",$Strategy) }
& $py (Join-Path $root "simulator.py") @args
