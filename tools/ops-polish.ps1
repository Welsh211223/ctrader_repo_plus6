[CmdletBinding()]
param(
  [switch]$PatchCI = $false,
  [string]$PythonVersion = "3.11"
)

function Section($m){ Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Ok($m){ Write-Host "✓ $m" -ForegroundColor Green }
function Warn($m){ Write-Host "⚠ $m" -ForegroundColor Yellow }
function Info($m){ Write-Host "• $m" -ForegroundColor DarkGray }
function Die($m){ Write-Host "✖ $m" -ForegroundColor Red; exit 1 }

try { $null = git rev-parse --is-inside-work-tree 2>$null } catch { Die "Run from the repository root." }

# --- 2) Enforce LF line endings ---
Section "Enforcing LF line endings"
git config core.autocrlf false | Out-Null
git config core.eol lf        | Out-Null
Ok "Set core.autocrlf=false, core.eol=lf"

$ga = ".gitattributes"
if (-not (Test-Path $ga)) {
@"
# Normalize text to LF
* text=auto eol=lf

# Common binary patterns
*.png binary
*.jpg binary
*.jpeg binary
*.pdf binary
"@ | Set-Content -Encoding utf8 -NoNewline $ga
  git add $ga | Out-Null
  Ok "Created .gitattributes"
} else {
  Info ".gitattributes already present"
}

# --- 3) Make gh reliably available next shells ---
Section "Ensuring WinGet Links on PATH (for gh)"
$links = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -and $links -and ($userPath -notlike "*$links*")) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$links", 'User')
  Ok "Added $links to User PATH (open a new PowerShell window to see it)"
} else {
  Info "PATH already includes WinGet Links (or not applicable)"
}
if (Get-Command gh -ErrorAction SilentlyContinue) {
  gh --version | Select-String '^gh version' | ForEach-Object { Info $_.ToString() }
} else {
  Warn "gh not found in THIS session; open a new PowerShell window"
}

# --- 4) detect-secrets helper for example files ---
Section "detect-secrets helper (allowlist pragma)"
function Add-AllowlistPragma {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string[]]$JsonPropertyNames = @("private_key","api_key","token")
  )
  if (-not (Test-Path $Path)) { Die "File not found: $Path" }
  $content = Get-Content -Raw -ErrorAction Stop $Path
  foreach ($name in $JsonPropertyNames) {
    $regex = "(?m)(""$([Regex]::Escape($name))""\s*:\s*"".*?"")"
    $content = [Regex]::Replace($content, $regex, '$1,  // pragma: allowlist secret')
  }
  Set-Content -Encoding ascii -NoNewline -Path $Path -Value $content
  Ok "Patched allowlist pragma(s) in: $Path"
}
Info "Use: Add-AllowlistPragma -Path 'secrets\\example.json' -JsonPropertyNames private_key,api_key,token"

# --- 5) OPTIONAL: patch CI to cache pip ---
if ($PatchCI) {
  Section "Patching GitHub Actions to enable pip cache"
  $wfRoot = ".github/workflows"
  if (-not (Test-Path $wfRoot)) {
    Warn "No .github/workflows directory found; skipping CI patch"
  } else {
    $files = Get-ChildItem $wfRoot -Filter *.yml -Recurse
    if (-not $files) {
      Warn "No workflow .yml files found; skipping"
    } else {
      foreach ($f in $files) {
        $y = Get-Content $f.FullName -Raw
        $patched = [Regex]::Replace($y,
          "(?ms)(-\s*uses:\s*actions/setup-python@v5\s*\r?\n\s*with:\s*\r?\n)((?:\s+.+\r?\n)+?)",
          {
            param($m)
            $head = $m.Groups[1].Value
            $withBlock = $m.Groups[2].Value
            $hasPy    = $withBlock -match "(?m)^\s*python-version\s*:\s*"
            $hasCache = $withBlock -match "(?m)^\s*cache\s*:\s*"
            if (-not $hasPy)    { $withBlock = "          python-version: `"$PythonVersion`"`r`n$withBlock" }
            if (-not $hasCache) { $withBlock = "          cache: `"pip`"`r`n$withBlock" }
            return "$head$withBlock"
          }
        )
        if ($patched -ne $y) {
          Set-Content -Encoding utf8 -NoNewline -Path $f.FullName -Value $patched
          Ok "Updated pip cache/python-version in: $($f.Name)"
        } else {
          Info "No changes needed in: $($f.Name)"
        }
      }
      $pending = git diff --name-only $wfRoot
      if ($pending) {
        git add $wfRoot | Out-Null
        git commit -S -m "ci: enable pip cache for setup-python (faster lint CI) [auto]" | Out-Null
        try { git push | Out-Null } catch { git push -u origin (git branch --show-current) | Out-Null }
        Ok "Committed & pushed CI cache updates"
      } else {
        Info "No CI changes to commit"
      }
    }
  }
} else {
  Info "CI patch disabled (run with -PatchCI to enable)"
}

Write-Host "`nAll done." -ForegroundColor Green
