param([string]$Root = ".")
Get-ChildItem -Path $Root -Filter *.yml -Recurse |
  Where-Object { $_.FullName -like "*\.github\workflows\*" } |
  ForEach-Object {
    $p = $_.FullName
    $lines = Get-Content $p
    for($i=0;$i -lt $lines.Count;$i++){
      $L = $lines[$i]
      if($L -match 'uses:\s*[^@]+@v[0-9]+'){
        "{0}:{1}: {2}" -f $p, ($i+1), $L
      }
    }
  }
