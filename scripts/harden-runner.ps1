function Set-HardenRunnerPolicy {
  param([string]$File, [ValidateSet('block','audit')]$Policy='audit')
  $lines = [IO.File]::ReadAllLines($File, [Text.UTF8Encoding]::new($false))
  $out   = New-Object System.Collections.Generic.List[string]
  $inHarden=$false; $inWith=$false; $indent=''; $egressSeen=$false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*-\s*name:\s*Harden Runner\b'){ $inHarden=$true; $inWith=$false; $egressSeen=$false }
    if ($inHarden -and $line -match '^\s*with:\s*$'){ $inWith=$true; $indent = ($line -replace "(\S).*",'$1') -replace '\S',' ' }
    elseif ($inHarden -and $inWith -and $line -match '^\s*egress-policy:\s*\S+\s*$'){
      $curIndent = ($line -replace "(\S).*",'$1') -replace '\S',' '
      $line = "$curIndent" + "egress-policy: $Policy"
      $egressSeen=$true
    }
    elseif ($inHarden -and $line -match '^\s*-\s*name:\s*\S'){
      if ($inWith -and -not $egressSeen){ $out.Add((" " * ($indent.Length + 2)) + "egress-policy: $Policy") }
      $inHarden=$false; $inWith=$false; $egressSeen=$false
    }
    $out.Add($line)
  }
  if ($inHarden -and $inWith -and -not $egressSeen){ $out.Add((" " * ($indent.Length + 2)) + "egress-policy: $Policy") }
  [IO.File]::WriteAllLines($File,$out,[Text.UTF8Encoding]::new($false))
}

function Set-HardenRunnerAllowList {
  param([string]$File, [string[]]$Endpoints)
  $lines = [IO.File]::ReadAllLines($File, [Text.UTF8Encoding]::new($false))
  $out   = New-Object System.Collections.Generic.List[string]
  $inHarden=$false; $inWith=$false; $indent=''; $wrote=$false
  $allowLine = ($Endpoints -join ', ')
  for ($i=0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*-\s*name:\s*Harden Runner\b'){ $inHarden=$true; $inWith=$false; $wrote=$false }
    if ($inHarden -and $line -match '^\s*with:\s*$'){ $inWith=$true; $indent = ($line -replace "(\S).*",'$1') -replace '\S',' ' }
    if ($inHarden -and $inWith -and $line -match '^\s*allowed-endpoints:\s*>\s*$'){
      $out.Add($line)
      $i++
      while ($i -lt $lines.Count -and $lines[$i] -match '^\s{2,}\S'){ $i++ }
      $out.Add((" " * ($indent.Length + 2)) + $allowLine)
      $wrote=$true
      $i--
      continue
    }
    if ($inHarden -and $line -match '^\s*-\s*name:\s*\S'){
      if ($inWith -and -not $wrote){
        $out.Add((" " * ($indent.Length + 2)) + "allowed-endpoints: >")
        $out.Add((" " * ($indent.Length + 4)) + $allowLine)
      }
      $inHarden=$false; $inWith=$false; $wrote=$false
    }
    $out.Add($line)
  }
  if ($inHarden -and $inWith -and -not $wrote){
    $out.Add((" " * ($indent.Length + 2)) + "allowed-endpoints: >")
    $out.Add((" " * ($indent.Length + 4)) + $allowLine)
  }
  [IO.File]::WriteAllLines($File,$out,[Text.UTF8Encoding]::new($false))
}
