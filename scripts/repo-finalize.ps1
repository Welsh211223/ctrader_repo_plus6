# scripts/repo-finalize.ps1  (PS 5.1 safe)
[CmdletBinding()]
param(
  [string]$Owner  = $null,
  [string]$Repo   = $null,
  [string]$Branch = "main",
  [switch]$BlockEgress   # flip harden-runner from audit -> block
)

function Info([string]$m){ Write-Host $m -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host $m -ForegroundColor Green }
function Warn([string]$m){ Write-Host $m -ForegroundColor Yellow }
function Err([string]$m){ Write-Host $m -ForegroundColor Red }

function Resolve-Gh {
  try { return (Get-Command gh -ErrorAction Stop).Source } catch {
    $c = Join-Path $Env:ProgramFiles 'GitHub CLI\gh.exe'
    if (Test-Path $c){ return $c }
    throw "GitHub CLI not found. Install: winget install GitHub.cli"
  }
}

# --- Resolve owner/repo if not provided ---
if (-not $Owner -or -not $Repo) {
  try {
    $url = (git remote get-url origin) 2>$null
    if ($url -match 'github\.com[/:]([^/]+)/([^/.]+)') {
      if (-not $Owner) { $Owner = $Matches[1] }
      if (-not $Repo)  { $Repo  = $Matches[2] }
    }
  } catch { }
}
if (-not $Owner -or -not $Repo) { throw "Owner/Repo not resolved. Pass -Owner 'user' -Repo 'name'." }

$repoFull = "$Owner/$Repo"
$gh = Resolve-Gh
$wfDir = ".github\workflows"

# ----------------------------------------------------
# 1) Fix duplicate `with:` mappings inside step blocks
# ----------------------------------------------------
function Fix-DuplicateWithInFile([string]$Path){
  if (-not (Test-Path $Path)) { return }
  $lines = Get-Content -Path $Path
  $out   = New-Object System.Collections.Generic.List[string]
  $stepIndent = -1
  $withSeen = $false

  for ($i=0; $i -lt $lines.Count; $i++){
    $L = $lines[$i]

    if ($L -match '^(\s*)-\s'){  # start of a new step
      $stepIndent = $Matches[1].Length
      $withSeen = $false
    }
    if ($L -match '^\s+with:\s*\{\s*\}\s*$'){
      if ($withSeen) { continue } else { $withSeen = $true }
    } elseif ($L -match '^\s+with:\s*$'){
      if ($withSeen) { continue } else { $withSeen = $true }
    }
    $out.Add($L)
  }

  $new = $out -join "`n"
  $orig = ($lines -join "`n")
  if ($new -ne $orig) {
    Set-Content -Path $Path -Value $new -Encoding utf8
    Ok "Fixed duplicate 'with:' in $Path"
  } else {
    Info "No duplicate 'with:' found in $Path"
  }
}

$maybeDup = @(
  "lint.yml","block-large-files.yml","pip-audit.yml","bandit.yml","tests.yml",
  "release.yml","codeql.yml","pr-title.yml","scorecard.yml","provenance.yml"
) | ForEach-Object { Join-Path $wfDir $_ } | Where-Object { Test-Path $_ }

foreach ($f in $maybeDup) { Fix-DuplicateWithInFile $f }

# ---------------------------------------------------------
# 2) Ensure step-security/harden-runner (optional egress=block)
# ---------------------------------------------------------
function AddOrUpdate-HardenRunner([string]$Path){
  if (-not (Test-Path $Path)) { return }
  $raw = Get-Content -Raw -Path $Path

  if ($raw -match 'step-security/harden-runner@v3'){
    if ($BlockEgress) {
      $updated = [regex]::Replace($raw, '(egress-policy:\s*)(audit|allow)', '${1}block')
      if ($updated -ne $raw){
        Set-Content -Path $Path -Value $updated -Encoding utf8
        Ok "Set egress-policy: block in $Path"
      } else {
        Info "egress-policy already block in $Path"
      }
    } else {
      Info "Harden runner already present in $Path"
    }
    return
  }

  if ($raw -match 'actions/checkout@v4'){
    # PS 5.1-safe "ternary"
    $blockMode = 'audit'
    if ($BlockEgress) { $blockMode = 'block' }

    $new = [regex]::Replace(
      $raw,
      '(^\s*)- uses:\s*actions/checkout@v4\s*(\r?\n)',
      {
        param($m)
        $i = $m.Groups[1].Value
        $i + "- uses: actions/checkout@v4`n" +
        $i + "- name: Harden Runner`n" +
        $i + "  uses: step-security/harden-runner@v3`n" +
        $i + "  with:`n" +
        $i + "    egress-policy: $blockMode`n"
      },
      'Multiline'
    )
    if ($new -ne $raw) {
      Set-Content -Path $Path -Value $new -Encoding utf8
      Ok "Added harden-runner to $Path"
    }
  }
}

$targets = Get-ChildItem $wfDir -Filter *.yml -File -Recurse -ErrorAction SilentlyContinue | Select-Object -Expand FullName
foreach ($t in $targets) { AddOrUpdate-HardenRunner $t }

# ------------------------------------------------------------------
# 3) Add OpenSSF Scorecard (if missing) and a guarded provenance wf
# ------------------------------------------------------------------
if (-not (Test-Path $wfDir)) { New-Item -ItemType Directory -Force -Path $wfDir | Out-Null }

$scorePath = Join-Path $wfDir "scorecard.yml"
if (-not (Test-Path $scorePath)){
  $scorecard = @'
name: scorecards
on:
  workflow_dispatch:
  schedule:
    - cron: "37 3 * * 5"
permissions:
  security-events: write
  id-token: write
  contents: read
concurrency:
  group: scorecards-${{ github.ref }}
  cancel-in-progress: true
jobs:
  analysis:
    runs-on: ubuntu-latest
    steps:
      - uses: ossf/scorecard-action@v2.3.1
        with:
          results_file: results.sarif
          results_format: sarif
          publish_results: true
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
'@
  Set-Content -Path $scorePath -Value $scorecard -Encoding utf8
  Ok "Wrote $scorePath"
}

$provPath = Join-Path $wfDir "provenance.yml"
if (-not (Test-Path $provPath)){
  $prov = @'
name: provenance
on:
  push:
    tags: [ "v*" ]
permissions:
  contents: write
  id-token: write
concurrency:
  group: provenance-${{ github.ref }}
  cancel-in-progress: true
jobs:
  attest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Harden Runner
        uses: step-security/harden-runner@v3
        with:
          egress-policy: audit
      - name: Find subject files
        id: find
        shell: bash
        run: |
          if [ -d dist ]; then echo "path=dist/**" >> "$GITHUB_OUTPUT"; exit 0; fi
          if compgen -G "*.whl" > /dev/null; then echo "path=*.whl" >> "$GITHUB_OUTPUT"; exit 0; fi
          if compgen -G "*.zip" > /dev/null; then echo "path=*.zip" >> "$GITHUB_OUTPUT"; exit 0; fi
          echo "path=" >> "$GITHUB_OUTPUT"
      - name: Attest build provenance (if any artifacts)
        if: steps.find.outputs.path != ''
        uses: actions/attest-build-provenance@v1
        with:
          subject-path: ${{ steps.find.outputs.path }}
'@
  Set-Content -Path $provPath -Value $prov -Encoding utf8
  Ok "Wrote $provPath"
}

# -----------------------------------
# 4) Refresh required check contexts
# -----------------------------------
$bpJson = ""
try { $bpJson = & $gh api ("repos/{0}/branches/{1}/protection/required_status_checks" -f $repoFull,$Branch) --jq . } catch { }
$contexts = @()
try { $contexts = ($bpJson | ConvertFrom-Json).contexts } catch { }

$want = @("black","ruff","ruff-format","isort","detect-secrets","size-check","pip-audit","semantic-pull-request")
if (Test-Path (Join-Path $wfDir "bandit.yml")) { $want += "bandit" }
if (Test-Path (Join-Path $wfDir "tests.yml"))  { $want += "pytest" }

$contexts = ($contexts + $want) | Where-Object { $_ } | Select-Object -Unique

$payloadBp = [ordered]@{
  required_status_checks = @{ strict = $true; contexts = $contexts }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $false
    required_approving_review_count = 1
    require_last_push_approval = $true
  }
  restrictions = $null
  required_linear_history = $true
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
} | ConvertTo-Json -Depth 6

try {
  $null = $payloadBp | & $gh api -X PUT ("repos/{0}/branches/{1}/protection" -f $repoFull,$Branch) `
    --header "Accept: application/vnd.github+json" --input -
  Ok "Branch protection updated."
} catch {
  Warn "Could not update branch protection: $($_.Exception.Message)"
}

# -------------------------------
# 5) Run hooks, commit, and push
# -------------------------------
$hasPreCommit = $false
try { Get-Command pre-commit -ErrorAction Stop | Out-Null; $hasPreCommit = $true } catch { }
if ($hasPreCommit) {
  Info "Running pre-commit on all files..."
  & pre-commit run --all-files 2>$null | Write-Host
}

git add -A
try {
  git commit -m "ci(security): PS5.1-safe finalize; fix duplicate YAML 'with'; harden-runner; scorecard; provenance; refresh checks" | Write-Host
} catch { }

try { git push | Write-Host } catch { Warn "Push skipped or failed: $($_.Exception.Message)" }

# ----------------
# 6) Quick summary
# ----------------
Info "Required checks:"
& $gh api ("repos/{0}/branches/{1}/protection/required_status_checks" -f $repoFull,$Branch) --jq '.contexts' | Write-Host
Ok "Done."
