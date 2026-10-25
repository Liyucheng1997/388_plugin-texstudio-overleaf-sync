<#
.SYNOPSIS
    End-to-end tests for OverleafSync.ps1 (-NoGui mode).

.DESCRIPTION
    Uses a local bare repository as "GitHub" and a second clone as "Overleaf",
    so nothing touches the network. Run:  powershell -File tests\run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$sync = Join-Path $PSScriptRoot '..\src\OverleafSync.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('overleaf-sync-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$remote = Join-Path $work 'github.git'
$paper = Join-Path $work '论文 paper'
$overleaf = Join-Path $work 'overleaf'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = 0

function Write-Text([string]$File, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $File) -Force | Out-Null
    [IO.File]::WriteAllText($File, ($Text -replace "`r?`n", "`n"), $utf8)
}

function Invoke-Sync([string[]]$SyncArgs) {
    $ErrorActionPreference = 'Continue'   # the script reports errors on stderr
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sync @SyncArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String).Trim() }
}

function Invoke-G([string]$Dir, [string[]]$GitArgs) {
    $ErrorActionPreference = 'Continue'   # git prints warnings on stderr
    $out = & git -C $Dir -c core.quotepath=false @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $GitArgs failed: $out" }
    ($out | Out-String).Trim()
}

function Assert([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:Failures++ }
}

function Edit-Line([string]$File, [int]$Line, [string]$Text) {
    $lines = [IO.File]::ReadAllText($File) -split "`n"
    $lines[$Line] = $Text
    [IO.File]::WriteAllText($File, ($lines -join "`n"), $utf8)
}

try {
    New-Item -ItemType Directory -Path $work | Out-Null
    git init -q --bare -b main $remote

    Write-Host '1. Initialise a new paper repository'
    $main = Join-Path $paper 'main.tex'
    Write-Text $main "\documentclass{article}`n\begin{document}`nIntro line.`nMethod line.`nResult line.`n\end{document}`n"
    Write-Text (Join-Path $paper '章节\引言.tex') "中文引言。`n"
    Write-Text (Join-Path $paper 'figures\plot.pdf') 'fake pdf'
    Write-Text (Join-Path $paper 'main.pdf') 'compiled pdf'
    Write-Text (Join-Path $paper 'main.aux') 'aux'
    Write-Text (Join-Path $paper 'submission.zip') 'zip'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Init', '-RepoUrl', $remote)
    Assert ($r.Code -eq 0) 'init exits 0' $r.Text
    $ignore = [IO.File]::ReadAllText((Join-Path $paper '.gitignore'))
    Assert ($ignore -match '(?m)^/main\.pdf$') '.gitignore excludes the compiled main.pdf'

    Write-Host '2. First sync'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '初稿')
    Assert ($r.Code -eq 0) 'sync exits 0' $r.Text
    $files = Invoke-G $remote @('ls-tree', '-r', '--name-only', 'main')
    Assert ($files -match 'main\.tex') 'main.tex pushed'
    Assert ($files -match '章节/引言\.tex') 'Chinese path pushed'
    Assert ($files -match 'figures/plot\.pdf') 'figure PDF pushed'
    Assert ($files -match '\.gitignore') '.gitignore pushed'
    Assert ($files -notmatch 'main\.pdf|main\.aux|submission\.zip') 'build output and archives left out' $files
    Assert ((Invoke-G $remote @('tag')) -eq 'v1.0') 'tag v1.0 pushed'
    Assert ((Invoke-G $remote @('log', '-1', '--format=%s', 'main')) -eq 'v1.0: 初稿') 'Chinese commit message'

    Write-Host '3. Overleaf edits one line, I edit another'
    git clone -q $remote $overleaf 2>&1 | Out-Null
    Edit-Line (Join-Path $overleaf 'main.tex') 2 'Intro line, edited by advisor.'
    Invoke-G $overleaf @('commit', '-q', '-am', 'Advisor edit') | Out-Null
    Invoke-G $overleaf @('push', '-q', 'origin', 'main') | Out-Null
    Edit-Line $main 4 'Result line, edited locally.'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '改结果')
    Assert ($r.Code -eq 0 -and $r.Text -match 'Incoming=1') 'merged one incoming commit' $r.Text
    $content = [IO.File]::ReadAllText($main)
    Assert ($content -match 'edited by advisor' -and $content -match 'edited locally') 'both edits present locally'
    Assert ((Invoke-G $remote @('tag')) -match 'v1\.1') 'tag v1.1 pushed'

    Write-Host '4. Conflicting edits'
    Invoke-G $overleaf @('pull', '-q') | Out-Null
    Edit-Line (Join-Path $overleaf 'main.tex') 3 'Method line by advisor.'
    Invoke-G $overleaf @('commit', '-q', '-am', 'Advisor method') | Out-Null
    Invoke-G $overleaf @('push', '-q', 'origin', 'main') | Out-Null
    Edit-Line $main 3 'Method line by me.'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '改方法')
    Assert ($r.Code -eq 2 -and $r.Text -match 'Conflicts=main\.tex') 'conflict reported' $r.Text
    Assert ([IO.File]::ReadAllText($main) -match '<<<<<<<') 'conflict markers written'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '解决冲突')
    Assert ($r.Code -eq 1 -and $r.Text -match '冲突标记') 'refuses to commit unresolved markers' $r.Text
    $resolved = ([IO.File]::ReadAllText($main) -replace '(?s)<<<<<<<[^\n]*\n.*?>>>>>>>[^\n]*\n', "Method line merged.`n")
    [IO.File]::WriteAllText($main, $resolved, $utf8)
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '解决冲突')
    Assert ($r.Code -eq 0 -and $r.Text -match 'Tag=v1\.2') 'merge completed as v1.2' $r.Text
    $parents = (Invoke-G $remote @('log', '-1', '--format=%P', 'main')) -split ' '
    Assert ($parents.Count -eq 2) 'remote head is the merge commit'

    Write-Host '5. Unticked files stay local; nothing to do is a no-op'
    $before = Invoke-G $remote @('rev-parse', 'main')
    Write-Text (Join-Path $paper 'notes.docx') 'private notes'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '无改动')
    Assert ($r.Code -eq 0 -and $r.Text -match 'Committed=False') 'no commit when only unticked files changed' $r.Text
    Assert ((Invoke-G $remote @('rev-parse', 'main')) -eq $before) 'remote unchanged'

    Write-Host '6. Restore an old version and publish it as a new one'
    Write-Text (Join-Path $paper 'appendix.tex') "Appendix.`n"
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '加附录', '-Bump', 'major')
    Assert ($r.Text -match 'Tag=v2\.0') 'major bump gives v2.0' $r.Text
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Restore', 'v1.0')
    Assert ($r.Code -eq 0) 'restore exits 0' $r.Text
    Assert (-not (Test-Path (Join-Path $paper 'appendix.tex'))) 'file added after v1.0 removed'
    Assert ([IO.File]::ReadAllText($main) -match 'Intro line\.\r?\n') 'main.tex back at v1.0'
    Assert (Test-Path (Join-Path $paper 'notes.docx')) 'untracked local files kept'
    $r = Invoke-Sync @('-Path', $main, '-NoGui', '-Message', '回到 v1.0')
    Assert ($r.Code -eq 0 -and $r.Text -match 'Tag=v2\.1') 'restored content published as v2.1' $r.Text
    $diff = Invoke-G $remote @('diff', '--stat', 'v1.0', 'v2.1')
    Assert (-not $diff) 'v2.1 tree equals v1.0' $diff
    Assert ((Invoke-G $remote @('rev-list', '--count', 'main')) -gt 5) 'history preserved'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures) { Write-Host "$script:Failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
