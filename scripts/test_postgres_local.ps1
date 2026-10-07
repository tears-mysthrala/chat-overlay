$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($taskRoot -ne 'D:\github\_worktrees\chat-overlay-postgres') { throw 'Unexpected worktree' }
Set-Location -LiteralPath $taskRoot
if ((git branch --show-current) -ne 'security/51-postgres-rls') { throw 'Unexpected branch' }
$project = 'overlay51-' + [guid]::NewGuid().ToString('N').Substring(0,12)
New-Item -ItemType Directory -Force -Path output/postgres | Out-Null
function Invoke-Docker([string[]]$Arguments) {
  & docker @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Docker operation failed ($LASTEXITCODE)" }
}
try {
  Invoke-Docker @('compose','-f','compose.postgres-local.yml','-p',$project,'up','-d','--wait','postgres')
  # Migration runs through the restricted owner identity, not postgres/runtime.
  Invoke-Docker @('compose','-f','compose.postgres-local.yml','-p',$project,'cp','priv/postgres/001_rls.sql','postgres:/tmp/001_rls.sql')
  Invoke-Docker @('compose','-f','compose.postgres-local.yml','-p',$project,'exec','-T','-e','PGPASSWORD=synthetic-migration','postgres','psql','-h','127.0.0.1','-U','overlay_migrator','-d','overlay_synthetic','-v','ON_ERROR_STOP=1','-f','/tmp/001_rls.sql')
  Invoke-Docker @('compose','-f','compose.postgres-local.yml','-p',$project,'run','--rm','tests')
} finally {
  # Unique project owns only its synthetic containers/network/volume; no prune.
  & docker compose -f compose.postgres-local.yml -p $project down --volumes
  if ($LASTEXITCODE -ne 0) { Write-Error "Synthetic resources require cleanup for $project" }
}
