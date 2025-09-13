Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path "$PSScriptRoot\.." | Select-Object -ExpandProperty Path
$py = Join-Path $repoRoot ".\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

$code = @"
import os, json, sys, re, importlib

def load_dotenv(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if re.match(r"^\s*#", line) or re.match(r"^\s*$", line):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    v = v.strip().strip('"').strip("'")
                    os.environ[k.strip()] = v
    except FileNotFoundError:
        pass

load_dotenv(".env")

key = os.getenv("COINSPOT_API_KEY", "")
sec = os.getenv("COINSPOT_API_SECRET", "")
if not key or not sec:
    print("ENV_NOT_SET")
    sys.exit(2)

try:
    mod = importlib.import_module("ctrader.data_providers.coinspot_v2")
    CoinSpotV2 = getattr(mod, "CoinSpotV2")
    client = CoinSpotV2(key, sec)
    res = client.ro_balances()
    print("OK", json.dumps(res)[:400])
    sys.exit(0)
except Exception as e:
    print("V2_FAIL", e)

try:
    mod = importlib.import_module("ctrader.data_providers.coinspot")
    CoinSpot = getattr(mod, "CoinSpot")
    client = CoinSpot(key, sec)
    res = client.balances()
    print("OK_LEGACY", json.dumps(res)[:400])
    sys.exit(0)
except Exception as e:
    print("LEGACY_FAIL", e)
    sys.exit(2)
"@

$tmp = [System.IO.Path]::GetTempFileName().Replace(".tmp",".py")
[System.IO.File]::WriteAllText($tmp, $code, (New-Object System.Text.UTF8Encoding($false)))
& $py $tmp
$exit = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
exit $exit