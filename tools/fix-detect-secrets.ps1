Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
$py = ".\.venv\Scripts\python.exe"; if (-not (Test-Path $py)) { $py = "python" }
& $py -m pip install -U detect-secrets | Out-Null
$scan = & $py -m detect_secrets scan --all-files --exclude-files '^\.secrets\.baseline$'
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText(".secrets.baseline", ($scan -join "`n"), $enc)
Write-Host "âœ… .secrets.baseline regenerated."
