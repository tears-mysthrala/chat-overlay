$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($taskRoot -notin @('D:\github\_worktrees\chat-overlay-postgres', 'D:\github\_worktrees\chat-overlay-f2-candidate')) { throw 'Unexpected worktree' }
Set-Location -LiteralPath $taskRoot
if ((git branch --show-current) -notin @('security/51-postgres-rls', 'security/55-f2-local-candidate')) { throw 'Unexpected branch' }
if ($taskRoot -eq 'D:\github\_worktrees\chat-overlay-f2-candidate' -and $env:POSTGRES_TEST_IMAGE -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Candidate requires an immutable validation image ID' }
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
