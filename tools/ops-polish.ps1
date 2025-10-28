param([switch]$PatchCI)

$ErrorActionPreference = 'Stop'

function Ok   ($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Info ($m){ Write-Host "[i]   $m" -ForegroundColor Cyan }
function Warn ($m){ Write-Host "[!]   $m" -ForegroundColor Yellow }

# --- 1) Enforce LF in git + .gitattributes ---
git config core.autocrlf false | Out-Null
git config core.eol lf        | Out-Null
Ok "git core.autocrlf=false, core.eol=lf"

$ga = ".gitattributes"
if (-not (Test-Path $ga)) {
@"
* text=auto eol=lf
*.ps1  text eol=lf
*.py   text eol=lf
*.yml  text eol=lf
*.yaml text eol=lf
*.json text eol=lf
"@ | Set-Content -Encoding utf8 -NoNewline $ga
  git add $ga | Out-Null
  Info "Wrote .gitattributes"
} else {
  Info ".gitattributes already present"
}

# --- 2) Make sure 'gh' can be found (best effort) ---
$apps = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
if ($env:PATH -notlike "*$apps*") { $env:PATH = "$apps;$env:PATH" }
try { gh --version | Select-Object -First 1 | Out-Null; Info "gh is available" } catch { Warn "gh not found (ok)" }

# --- 3) Helper: Add-AllowlistPragma for detect-secrets ---
function Add-AllowlistPragma {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$JsonPropertyNames
  )
  if (-not (Test-Path -LiteralPath $Path)) { Warn "File not found: $Path"; return }

  $text    = Get-Content -LiteralPath $Path -Raw
  $changed = $false
  foreach ($name in $JsonPropertyNames) {
    $safe    = [regex]::Escape($name)
    $pattern = "(?m)^\s*(""$safe""\s*:\s*.+?)\s*$"
    $newtext = [regex]::Replace($text, $pattern, '$1  # pragma: allowlist secret')
    if ($newtext -ne $text) { $text = $newtext; $changed = $true }
  }
  if ($changed) {
    Set-Content -Encoding utf8 -NoNewline -LiteralPath $Path -Value $text
    Ok "Added allowlist pragmas to: $Path"
  } else {
    Info "No changes needed in: $Path"
  }
}

# --- 4) Optional: patch Actions setup-python to ensure cache: pip + python-version ---
if ($PatchCI) {
  $wfRoot = ".github/workflows"
  if (Test-Path $wfRoot) {
    Get-ChildItem $wfRoot -Filter *.yml -File -Recurse | ForEach-Object {
      $orig = Get-Content -Raw $_.FullName
      $patched = [regex]::Replace($orig,
        "(?ms)(^\s*-\s*uses:\s*actions/setup-python@[^\r\n]+[\r\n])(?<block>(?:\s{2,}.+[\r\n])+)",
        {
          param($m)
          $head = $m.Groups[1].Value
          $blk  = $m.Groups['block'].Value
          if ($blk -notmatch "(?m)^\s*with\s*:\s*$") { $blk = "      with:`r`n$blk" }
          if ($blk -notmatch "(?m)^\s*python-version\s*:") { $blk = "        python-version: '3.10'`r`n$blk" }
          if ($blk -notmatch "(?m)^\s*cache\s*:\s*pip\s*$") { $blk = "        cache: pip`r`n$blk" }
          return "$head$blk"
        })
      if ($patched -ne $orig) {
        Set-Content -Encoding utf8 -NoNewline -Path $_.FullName -Value $patched
        Ok "Updated: $($_.Name)"
      } else {
        Info "No changes: $($_.Name)"
      }
    }
    $pending = git diff --name-only $wfRoot
    if ($pending) {
      git add $wfRoot | Out-Null
      git commit -S -m "ci: ensure setup-python uses pip cache + python-version [auto]" | Out-Null
      try { git push | Out-Null } catch { git push -u origin (git branch --show-current) | Out-Null }
      Ok "Committed & pushed CI updates"
    } else {
      Info "No CI changes to commit"
    }
  } else {
    Warn "No workflows folder found"
  }
} else {
  Info "CI patch disabled (run with -PatchCI to enable)"
}
