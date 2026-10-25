<#
.SYNOPSIS
    OverleafSync: one-click Git/GitHub sync for TeXstudio projects.

.DESCRIPTION
    Commits the files you pick, merges whatever Overleaf pushed to GitHub,
    tags the result with a version number (v1.0, v1.1, ...) and pushes it.
    An Overleaf project linked to the same GitHub repository then only needs
    "Pull GitHub changes into Overleaf".

    Normally launched by the TeXstudio macro (see install.ps1) with -PathHex.
    -NoGui runs the same logic from the command line (used by the tests).

.EXAMPLE
    powershell -File OverleafSync.ps1 -Path F:\paper\main.tex
    powershell -File OverleafSync.ps1 -Path F:\paper -NoGui -Message "Revise intro"
#>
[CmdletBinding()]
param(
    [string]$Path,
    # Same as -Path, hex-encoded UTF-16 so TeXstudio's command-line expansion cannot mangle it.
    [string]$PathHex,
    [switch]$NoGui,
    [string]$Message,
    # Version tag for -NoGui; 'none' skips tagging, empty means "next version by -Bump".
    [string]$Version,
    [ValidateSet('minor', 'major')][string]$Bump = 'minor',
    # -NoGui only: initialise the folder as a repository with -RepoUrl as origin.
    [switch]$Init,
    [string]$RepoUrl,
    # -NoGui only: restore the working tree to this version tag.
    [string]$Restore
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $script:Utf8 } catch { }
$env:GIT_TERMINAL_PROMPT = '0'

$script:LogFile = Join-Path $env:LOCALAPPDATA 'OverleafSync\sync.log'
$script:Root = $null
$script:State = $null
$script:Owner = $null
$script:MaxFileSize = 50MB   # Overleaf rejects files above 50 MB, GitHub above 100 MB
$script:SourceExt = @('.tex', '.bib', '.sty', '.cls', '.bst', '.bbx', '.cbx', '.cfg', '.def', '.clo', '.ist', '.tikz', '.pgf', '.txt', '.md')
$script:ImageExt = @('.png', '.jpg', '.jpeg', '.eps', '.svg', '.gif', '.tif', '.tiff')
$script:GitIgnoreTemplate = @'
# LaTeX build artifacts
*.aux
*.bbl
*.bcf
*.blg
*.fdb_latexmk
*.fls
*.idx
*.ilg
*.ind
*.lof
*.log
*.lot
*.out
*.run.xml
*.synctex.gz
*.synctex(busy)
*.toc
*.xdv
*.nav
*.snm
*.vrb
*.acn
*.acr
*.alg
*.glg
*.glo
*.gls
*.ist
*.loa
*.lol
*.thm

# Editor and OS files
*.bak
*.txss
*.txss2
*~
.DS_Store
Thumbs.db
desktop.ini
'@

#region Process helpers

function Write-Log([string]$Text) {
    try {
        $dir = Split-Path $script:LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::AppendAllText($script:LogFile, ('[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine), $script:Utf8)
    } catch { }
}

# Quotes one argument following the Windows CommandLineToArgvW rules.
function ConvertTo-CommandLineArg([string]$Arg) {
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq [char]'\') { $slashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', 2 * $slashes + 1)
        } elseif ($slashes) {
            [void]$sb.Append([char]'\', $slashes)
        }
        $slashes = 0
        [void]$sb.Append($ch)
    }
    if ($slashes) { [void]$sb.Append([char]'\', 2 * $slashes) }
    [void]$sb.Append('"')
    $sb.ToString()
}

function Invoke-Exe {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkDir, [switch]$AllowFail)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    $err = $errTask.Result
    $result = [pscustomobject]@{ Code = $proc.ExitCode; Out = $out; Err = $err; Text = ($out + $err).Trim() }
    Write-Log ('{0} {1} -> {2}{3}{4}' -f (Split-Path $Exe -Leaf), $psi.Arguments, $result.Code, [Environment]::NewLine, $result.Text)
    if ($result.Code -ne 0 -and -not $AllowFail) {
        throw ("{0} {1} 失败：`n{2}" -f (Split-Path $Exe -Leaf), @($Arguments)[0], $result.Text)
    }
    $result
}

function Invoke-Git([string[]]$GitArgs, [switch]$AllowFail) {
    $all = @('-c', 'core.quotepath=false', '-c', 'i18n.logOutputEncoding=utf-8', '--literal-pathspecs') + $GitArgs
    Invoke-Exe -Exe $script:GitExe -Arguments $all -WorkDir $script:Root -AllowFail:$AllowFail
}

function New-TempTextFile([string]$Text) {
    $file = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($file, $Text, $script:Utf8)
    $file
}

# Runs a git command that takes its paths from a NUL-separated pathspec file.
function Invoke-GitWithPaths([string[]]$GitArgs, [string[]]$Paths) {
    $spec = New-TempTextFile ($Paths -join [char]0)
    try {
        Invoke-Git ($GitArgs + @("--pathspec-from-file=$spec", '--pathspec-file-nul')) | Out-Null
    } finally {
        Remove-Item -LiteralPath $spec -ErrorAction SilentlyContinue
    }
}

function Split-Nul([string]$Text) {
    @($Text.Split([char]0) | Where-Object { $_ })
}

#endregion

#region Repository state

function Get-RepoRoot([string]$Dir) {
    $r = Invoke-Exe -Exe $script:GitExe -Arguments @('rev-parse', '--show-toplevel') -WorkDir $Dir -AllowFail
    if ($r.Code -eq 0 -and $r.Out.Trim()) { return ($r.Out.Trim() -replace '/', '\') }
    $null
}

function Test-GitRef([string]$Ref) {
    (Invoke-Git @('rev-parse', '--verify', '-q', $Ref) -AllowFail).Code -eq 0
}

function Get-ChangeKind([string]$XY) {
    if ($XY -eq '??') { return '新文件' }
    if (@('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU') -contains $XY) { return '冲突' }
    if ($XY.Contains('D')) { return '删除' }
    if ($XY.Contains('R')) { return '重命名' }
    if ($XY.Contains('A')) { return '新增' }
    '修改'
}

# Whether a changed file is ticked by default: every tracked change, plus untracked
# LaTeX sources and figures. Archives, submission bundles etc. stay unticked.
function Test-DefaultInclude($Change) {
    if ($Change.Size -gt $script:MaxFileSize) { return $false }
    if (-not $Change.Untracked) { return $true }
    $name = ($Change.Path -split '/')[-1]
    if (@('.gitignore', '.gitattributes', '.latexmkrc', 'latexmkrc') -contains $name) { return $true }
    $ext =[IO.Path]::GetExtension($Change.Path).ToLowerInvariant()
    if ($script:SourceExt -contains $ext -or $script:ImageExt -contains $ext) { return $true }
    ($ext -eq '.pdf' -and $Change.Path -match '(?i)(fig|img|image|pic|plot|graph)')
}

function Get-Changes {
    $tokens = (Invoke-Git @('status', '--porcelain=v1', '-z', '-uall')).Out.Split([char]0)
    for ($i = 0; $i -lt $tokens.Length; $i++) {
        $t = $tokens[$i]
        if ($t.Length -lt 4) { continue }
        $xy = $t.Substring(0, 2)
        $p = $t.Substring(3)
        if ($xy[0] -eq [char]'R' -or $xy[0] -eq [char]'C') { $i++ }   # skip the rename source
        $full = Join-Path $script:Root ($p -replace '/', '\')
        $size = 0
        if (Test-Path -LiteralPath $full -PathType Leaf) { $size = (Get-Item -LiteralPath $full -Force).Length }
        $kind = Get-ChangeKind $xy
        $change = [pscustomobject]@{
            XY = $xy; Path = $p; Kind = $kind; Size = $size
            Untracked = ($xy -eq '??'); Conflict = ($kind -eq '冲突'); Default = $false
        }
        $change.Default = $change.Conflict -or (Test-DefaultInclude $change)
        $change
    }
}

function Get-VersionTags {
    $tags = foreach ($line in ((Invoke-Git @('tag', '--list', 'v*')).Out -split "`r?`n")) {
        if ($line -match '^v(\d+)\.(\d+)(?:\.(\d+))?$') {
            $patch = 0
            if ($Matches[3]) { $patch = $Matches[3] }
            [pscustomobject]@{ Name = $line; Key = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $patch) }
        }
    }
    @($tags | Sort-Object Key)
}

function Get-NextVersion([string]$Latest, [string]$Kind) {
    if ($Latest -notmatch '^v(\d+)\.(\d+)') { return 'v1.0' }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($Kind -eq 'major') { return "v$($major + 1).0" }
    "v$major.$($minor + 1)"
}

function ConvertTo-WebUrl([string]$Url) {
    if (-not $Url) { return '' }
    $u = $Url.Trim() -replace '\.git$', ''
    if ($u -match '^git@([^:]+):(.+)$') { return "https://$($Matches[1])/$($Matches[2])" }
    if ($u -match '^ssh://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$') { return "https://$($Matches[1])/$($Matches[2])" }
    if ($u -match '^https?://') { return ($u -replace '^(https?://)[^@/]+@', '$1') }
    ''
}

function Get-SyncState([switch]$Fetch) {
    $s = [ordered]@{ Root = $script:Root }
    $s.Branch = (Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD') -AllowFail).Out.Trim()
    $s.HasHead = Test-GitRef 'HEAD'
    $url = Invoke-Git @('remote', 'get-url', 'origin') -AllowFail
    $s.RemoteUrl = ''
    if ($url.Code -eq 0) { $s.RemoteUrl = $url.Out.Trim() }
    $s.WebUrl = ConvertTo-WebUrl $s.RemoteUrl
    $s.FetchError = ''
    if ($Fetch -and $s.RemoteUrl) {
        $f = Invoke-Git @('fetch', '--tags', 'origin') -AllowFail
        if ($f.Code -ne 0) { $s.FetchError = $f.Text }
    }
    $s.RemoteBranch = ''
    $s.Ahead = 0
    $s.Behind = 0
    if ($s.RemoteUrl -and $s.Branch -and (Test-GitRef "refs/remotes/origin/$($s.Branch)")) {
        $s.RemoteBranch = "origin/$($s.Branch)"
        if ($s.HasHead) {
            $counts = (Invoke-Git @('rev-list', '--left-right', '--count', "HEAD...$($s.RemoteBranch)")).Out.Trim() -split '\s+'
            $s.Ahead = [int]$counts[0]
            $s.Behind = [int]$counts[1]
        } else {
            $s.Behind = [int](Invoke-Git @('rev-list', '--count', $s.RemoteBranch)).Out.Trim()
        }
    } elseif ($s.HasHead -and $s.RemoteUrl -and $s.Branch) {
        $s.Ahead = [int](Invoke-Git @('rev-list', '--count', 'HEAD')).Out.Trim()
    }
    $mergeHead = (Invoke-Git @('rev-parse', '--git-path', 'MERGE_HEAD')).Out.Trim()
    if (-not [IO.Path]::IsPathRooted($mergeHead)) { $mergeHead = Join-Path $script:Root $mergeHead }
    $s.Merging = Test-Path -LiteralPath $mergeHead
    $s.Changes = @(Get-Changes)
    $s.Tags = @(Get-VersionTags)
    $s.LatestTag = ''
    if ($s.Tags.Count) { $s.LatestTag = $s.Tags[-1].Name }
    $s.OverleafUrl = (Invoke-Git @('config', '--get', 'overleaf-sync.url') -AllowFail).Out.Trim()
    [pscustomobject]$s
}

function Get-FilesWithConflictMarkers([string[]]$Paths) {
    foreach ($p in $Paths) {
        $full = Join-Path $script:Root ($p -replace '/', '\')
        if ((Test-Path -LiteralPath $full -PathType Leaf) -and
            (Select-String -LiteralPath $full -Pattern '^(<{7}|>{7})( |$)' -Quiet)) { $p }
    }
}

#endregion

#region Operations

function Initialize-Repo {
    param([string]$Dir, [string]$MainTex, [string]$RemoteUrl, [string]$RepoName, [bool]$Private = $true)
    $ignore = Join-Path $Dir '.gitignore'
    if (-not (Test-Path -LiteralPath $ignore)) {
        $text = $script:GitIgnoreTemplate
        if ($MainTex -and ((Split-Path $MainTex) -eq $Dir)) {
            $pdf = [IO.Path]::ChangeExtension((Split-Path $MainTex -Leaf), '.pdf')
            $text += "`n# Compiled main document (Overleaf compiles it by itself)`n/$pdf`n"
        }
        [IO.File]::WriteAllText($ignore, ($text -replace "`r?`n", "`n"), $script:Utf8)
    }
    Invoke-Exe -Exe $script:GitExe -Arguments @('init', '-q', '-b', 'main') -WorkDir $Dir | Out-Null
    $script:Root = Get-RepoRoot $Dir
    Set-Remote -RemoteUrl $RemoteUrl -RepoName $RepoName -Private $Private
}

function Set-Remote {
    param([string]$RemoteUrl, [string]$RepoName, [bool]$Private = $true)
    if ($RemoteUrl) {
        Invoke-Git @('remote', 'add', 'origin', $RemoteUrl) | Out-Null
    } elseif ($RepoName) {
        $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
        if (-not $gh) { throw '未找到 GitHub CLI (gh)。请填写已有仓库地址，或安装 gh 后运行 gh auth login。' }
        $visibility = '--public'
        if ($Private) { $visibility = '--private' }
        Invoke-Exe -Exe $gh.Source -Arguments @('repo', 'create', $RepoName, $visibility, '--source', '.', '--remote', 'origin') -WorkDir $script:Root | Out-Null
    }
}

function Invoke-Sync {
    param($State, [string[]]$Paths, [string]$Message, [string]$Tag, [scriptblock]$Progress)
    $result = [ordered]@{ Committed = $false; Incoming = 0; Tag = ''; Pushed = $false; Conflicts = @(); Notes = @() }
    $Paths = @($Paths | Where-Object { $_ })
    if ($Progress) { & $Progress '检查中…' }

    if ($Tag) {
        if ($Tag -notmatch '^v\d+\.\d+(\.\d+)?$') { throw '版本号格式应为 v主.次，例如 v2.6' }
        if (Test-GitRef "refs/tags/$Tag") { throw "版本号 $Tag 已存在，请换一个。" }
    }
    if ($State.Merging) {
        $conflicted = @($State.Changes | Where-Object Conflict | ForEach-Object Path)
        $missing = @($conflicted | Where-Object { $Paths -notcontains $_ })
        if ($missing.Count) { throw ("以下冲突文件必须勾选才能完成合并：`n" + ($missing -join "`n")) }
        $marked = @(Get-FilesWithConflictMarkers $conflicted)
        if ($marked.Count) {
            throw ("以下文件里还有冲突标记（<<<<<<< / >>>>>>>），请先在 TeXstudio 中处理并保存：`n" + ($marked -join "`n"))
        }
    }

    $text = ''
    if ($Message) { $text = $Message.Trim() }
    if (-not $text) { $text = '更新 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    $subject = $text
    if ($Tag) { $subject = "${Tag}: $text" }
    $msgFile = New-TempTextFile $subject
    try {
        # 1. Commit exactly the ticked files.
        if ($Paths.Count -or $State.Merging) {
            if ($Progress) { & $Progress '提交本地修改…' }
            if ($State.HasHead -and -not $State.Merging) { Invoke-Git @('reset', '-q') | Out-Null }
            if ($Paths.Count) { Invoke-GitWithPaths @('add', '-A') $Paths }
            $staged = (Invoke-Git @('diff', '--cached', '--quiet') -AllowFail).Code -ne 0
            if ($staged -or $State.Merging) {
                Invoke-Git @('commit', '-q', '-F', $msgFile) | Out-Null
                $result.Committed = $true
            }
        }

        # 2. Merge what arrived from Overleaf (via GitHub).
        if ($State.RemoteBranch) {
            $range = $State.RemoteBranch
            if (Test-GitRef 'HEAD') { $range = "HEAD..$($State.RemoteBranch)" }
            $incoming = [int](Invoke-Git @('rev-list', '--count', $range)).Out.Trim()
            if ($incoming -gt 0) {
                if ($Progress) { & $Progress "合并远端的 $incoming 个新提交…" }
                $merge = Invoke-Git @('merge', '--no-edit', '--allow-unrelated-histories', '-m', 'Merge changes from Overleaf/GitHub', $State.RemoteBranch) -AllowFail
                $result.Incoming = $incoming
                if ($merge.Code -ne 0) {
                    $conflicts = @(Split-Nul (Invoke-Git @('diff', '--name-only', '-z', '--diff-filter=U')).Out)
                    if ($conflicts.Count) {
                        $result.Conflicts = $conflicts
                        return [pscustomobject]$result
                    }
                    throw ("合并远端修改失败：`n" + $merge.Text)
                }
            }
        }

        if (-not (Test-GitRef 'HEAD')) {
            $result.Notes += '没有可提交的内容。'
            return [pscustomobject]$result
        }

        # 3. Version tag, only when this sync brought new local content.
        if ($Tag -and $result.Committed) {
            Invoke-Git @('tag', '-a', $Tag, '-F', $msgFile) | Out-Null
            $result.Tag = $Tag
        }

        # 4. Push.
        if ($State.RemoteUrl -and $State.Branch) {
            if ($Progress) { & $Progress '推送到 GitHub…' }
            Invoke-Git @('push', '-u', 'origin', "HEAD:refs/heads/$($State.Branch)") | Out-Null
            if ($result.Tag) { Invoke-Git @('push', 'origin', "refs/tags/$($result.Tag)") | Out-Null }
            $result.Pushed = $true
        } elseif (-not $State.RemoteUrl) {
            $result.Notes += '还没有关联 GitHub 仓库，本次只在本地提交。'
        }
    } finally {
        Remove-Item -LiteralPath $msgFile -ErrorAction SilentlyContinue
    }
    [pscustomobject]$result
}

# Makes the working tree look exactly like version $Tag, as uncommitted changes.
# History is untouched: the next sync publishes it as a new version.
function Restore-Version([string]$Tag) {
    if (-not (Test-GitRef "refs/tags/$Tag")) { throw "找不到版本 $Tag" }
    if ((Invoke-Git @('status', '--porcelain', '-uno')).Out.Trim()) {
        throw '当前还有未同步的修改，请先同步（或撤销）后再恢复旧版本。'
    }
    $added = @(Split-Nul (Invoke-Git @('diff', '--name-only', '-z', '--no-renames', '--diff-filter=A', $Tag, 'HEAD')).Out)
    if ($added.Count) { Invoke-GitWithPaths @('rm', '-q') $added }
    Invoke-Git @('checkout', $Tag, '--', '.') | Out-Null
    Invoke-Git @('reset', '-q') | Out-Null
}

function Add-ToGitIgnore([string[]]$Paths) {
    $file = Join-Path $script:Root '.gitignore'
    $prefix = ''
    if ((Test-Path -LiteralPath $file) -and -not ([IO.File]::ReadAllText($file)).EndsWith("`n")) { $prefix = "`n" }
    $lines = ($Paths | ForEach-Object { '/' + ($_ -replace '([\[\]\*\?#! ])', '\$1') }) -join "`n"
    [IO.File]::AppendAllText($file, $prefix + $lines + "`n", $script:Utf8)
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    "$Bytes B"
}

function ConvertTo-RepoName([string]$Name) {
    $n = ($Name -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.')
    if (-not $n) { $n = 'latex-paper' }
    $n
}

#endregion

#region GUI

function Px([double]$Value) { [int]($Value * $script:Scale) }

# Message boxes get a top-most owner: the script starts in the background, so an
# unowned box could open behind the TeXstudio window.
function Get-DialogOwner {
    if (-not $script:Owner) {
        $script:Owner = New-Object Windows.Forms.Form
        $script:Owner.TopMost = $true
    }
    $script:Owner
}

function Show-Info([string]$Text, [string]$Icon = 'Information') {
    [void][Windows.Forms.MessageBox]::Show((Get-DialogOwner), $Text, 'Overleaf 同步', 'OK', $Icon)
}

function Show-YesNo([string]$Text, [string]$Icon = 'Question') {
    [Windows.Forms.MessageBox]::Show((Get-DialogOwner), $Text, 'Overleaf 同步', 'YesNo', $Icon) -eq 'Yes'
}

function New-Button([string]$Text, [int]$Width = 0) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    if ($Width) { $b.MinimumSize = New-Object Drawing.Size((Px $Width), 0) }
    $b.Margin = New-Object Windows.Forms.Padding(3)
    $b
}

function New-Form([string]$Title, [int]$Width, [int]$Height) {
    $f = New-Object Windows.Forms.Form
    $f.Text = $Title
    $f.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object Drawing.Size((Px $Width), (Px $Height))
    $f.ShowIcon = $false
    $f
}

function Show-TextWindow([string]$Title, [string]$Text) {
    $f = New-Form $Title 900 600
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.WordWrap = $false
    $box.ScrollBars = 'Both'
    $box.Dock = 'Fill'
    $box.Font = New-Object Drawing.Font('Consolas', 10)
    $box.Text = ($Text -replace "`r?`n", "`r`n")
    $f.Controls.Add($box)
    [void]$f.ShowDialog()
}

# Asks how to connect a GitHub repository. Returns @{Url; RepoName; Private} or $null.
function Show-RemoteDialog([string]$DefaultName, [bool]$AllowLocalOnly) {
    $hasGh = [bool](Get-Command gh.exe -ErrorAction SilentlyContinue)
    $f = New-Form '关联 GitHub 仓库' 560 250
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $table = New-Object Windows.Forms.TableLayoutPanel
    $table.Dock = 'Fill'
    $table.Padding = New-Object Windows.Forms.Padding((Px 10))
    $table.ColumnCount = 2
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))

    $rbNew = New-Object Windows.Forms.RadioButton
    $rbNew.Text = '新建 GitHub 仓库，名称：'
    $rbNew.AutoSize = $true
    $rbNew.Enabled = $hasGh
    $txtName = New-Object Windows.Forms.TextBox
    $txtName.Text = $DefaultName
    $txtName.Dock = 'Fill'
    $chkPrivate = New-Object Windows.Forms.CheckBox
    $chkPrivate.Text = '私有仓库（只有你和你邀请的人可见）'
    $chkPrivate.Checked = $true
    $chkPrivate.AutoSize = $true
    $rbUrl = New-Object Windows.Forms.RadioButton
    $rbUrl.Text = '使用已有仓库地址：'
    $rbUrl.AutoSize = $true
    $txtUrl = New-Object Windows.Forms.TextBox
    $txtUrl.Dock = 'Fill'
    $rbLocal = New-Object Windows.Forms.RadioButton
    $rbLocal.Text = '暂不关联，只在本地做版本管理'
    $rbLocal.AutoSize = $true
    $rbLocal.Visible = $AllowLocalOnly
    $hint = New-Object Windows.Forms.Label
    $hint.AutoSize = $true
    $hint.ForeColor = [Drawing.Color]::DimGray
    $hint.Text = '提示：Overleaf 只能从 GitHub 仓库新建项目来同步（New Project → Import from GitHub）。'
    if (-not $hasGh) { $hint.Text = '未检测到 GitHub CLI (gh)，请先在 GitHub 网页上建一个空仓库，再把地址填在这里。' }
    if ($hasGh) { $rbNew.Checked = $true } else { $rbUrl.Checked = $true }

    $table.Controls.Add($rbNew, 0, 0); $table.Controls.Add($txtName, 1, 0)
    $table.Controls.Add($chkPrivate, 1, 1)
    $table.Controls.Add($rbUrl, 0, 2); $table.Controls.Add($txtUrl, 1, 2)
    $table.Controls.Add($rbLocal, 0, 3); $table.SetColumnSpan($rbLocal, 2)
    $table.Controls.Add($hint, 0, 4); $table.SetColumnSpan($hint, 2)

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.Dock = 'Bottom'
    $buttons.AutoSize = $true
    $buttons.Padding = New-Object Windows.Forms.Padding((Px 6))
    $ok = New-Button '确定' 80
    $ok.DialogResult = 'OK'
    $cancel = New-Button '取消' 80
    $cancel.DialogResult = 'Cancel'
    $buttons.Controls.AddRange(@($cancel, $ok))
    $f.Controls.Add($table)
    $f.Controls.Add($buttons)
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    $f.TopMost = $true

    while ($f.ShowDialog() -eq 'OK') {
        if ($rbLocal.Checked) { return @{ Url = ''; RepoName = ''; Private = $true } }
        if ($rbUrl.Checked) {
            if ($txtUrl.Text.Trim()) { return @{ Url = $txtUrl.Text.Trim(); RepoName = ''; Private = $true } }
            Show-Info '请填写仓库地址，例如 https://github.com/用户名/仓库名.git' 'Warning'
            continue
        }
        $name = ConvertTo-RepoName $txtName.Text
        return @{ Url = ''; RepoName = $name; Private = $chkPrivate.Checked }
    }
    $null
}

function Show-HistoryDialog {
    $st = $script:State
    $format = '%(refname:short)%09%(creatordate:format:%Y-%m-%d %H:%M)%09%(contents:subject)'
    $refs = (Invoke-Git @('for-each-ref', '--sort=-creatordate', "--format=$format", 'refs/tags/v*')).Out -split "`r?`n"

    $f = New-Form '版本历史' 760 460
    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.Dock = 'Fill'
    [void]$lv.Columns.Add('版本', (Px 80))
    [void]$lv.Columns.Add('时间', (Px 130))
    [void]$lv.Columns.Add('说明', (Px 520))
    foreach ($line in $refs) {
        if (-not $line) { continue }
        $parts = $line -split "`t", 3
        $item = New-Object Windows.Forms.ListViewItem($parts[0])
        foreach ($extra in @($parts[1..2])) { [void]$item.SubItems.Add([string]$extra) }
        [void]$lv.Items.Add($item)
    }

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Bottom'
    $buttons.AutoSize = $true
    $buttons.Padding = New-Object Windows.Forms.Padding((Px 6))
    $btnView = New-Button '在 GitHub 查看此版本'
    $btnCompare = New-Button '与当前版本对比'
    $btnCommits = New-Button '全部提交记录'
    $btnRestore = New-Button '恢复到此版本…'
    $btnClose = New-Button '关闭' 80
    $btnClose.DialogResult = 'Cancel'
    $buttons.Controls.AddRange(@($btnView, $btnCompare, $btnCommits, $btnRestore, $btnClose))
    foreach ($b in @($btnView, $btnCompare, $btnCommits)) { $b.Enabled = [bool]$st.WebUrl }
    $f.Controls.Add($lv)
    $f.Controls.Add($buttons)
    $f.CancelButton = $btnClose

    $selected = { if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Text } else { '' } }
    $btnView.Add_Click({ $t = & $selected; if ($t) { Start-Process "$($st.WebUrl)/tree/$t" } })
    $btnCompare.Add_Click({ $t = & $selected; if ($t) { Start-Process "$($st.WebUrl)/compare/$t...$($st.Branch)" } })
    $btnCommits.Add_Click({ Start-Process "$($st.WebUrl)/commits/$($st.Branch)" })
    $btnRestore.Add_Click({
        $t = & $selected
        if (-not $t) { Show-Info '请先在列表中选中一个版本。'; return }
        $question = "把论文文件恢复成 $t 时的内容？`n`n不会删除任何历史记录：恢复后的内容先作为「未提交的修改」出现，" +
            "你在 TeXstudio 中检查无误后，再点「同步」即可作为一个新版本发布。"
        if (-not (Show-YesNo $question)) { return }
        try {
            Restore-Version $t
            $script:Restored = $t
            $f.Close()
        } catch {
            Show-Info $_.Exception.Message 'Error'
        }
    })
    [void]$f.ShowDialog()
}

function Show-MainDialog {
    $f = New-Form ('Overleaf 同步 - ' + (Split-Path $script:Root -Leaf)) 860 640
    $f.MinimumSize = New-Object Drawing.Size((Px 640), (Px 480))
    $f.TopMost = $true

    # Header
    $header = New-Object Windows.Forms.FlowLayoutPanel
    $header.FlowDirection = 'TopDown'
    $header.WrapContents = $false
    $header.Dock = 'Top'
    $header.AutoSize = $true
    $header.Padding = New-Object Windows.Forms.Padding((Px 8), (Px 8), (Px 8), 0)
    $lblProject = New-Object Windows.Forms.Label
    $lblProject.AutoSize = $true
    $lblRemote = New-Object Windows.Forms.Label
    $lblRemote.AutoSize = $true
    $lblList = New-Object Windows.Forms.Label
    $lblList.AutoSize = $true
    $lblList.Margin = New-Object Windows.Forms.Padding(3, (Px 8), 3, 0)
    $lblList.Text = '勾选要提交的文件（双击查看改动；未勾选的文件留在本地，不会上传）：'
    $header.Controls.AddRange(@($lblProject, $lblRemote, $lblList))

    # File list
    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.CheckBoxes = $true
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.Dock = 'Fill'
    [void]$lv.Columns.Add('状态', (Px 70))
    [void]$lv.Columns.Add('文件', (Px 640))
    [void]$lv.Columns.Add('大小', (Px 80), 'Right')

    # Version + message
    $options = New-Object Windows.Forms.TableLayoutPanel
    $options.Dock = 'Bottom'
    $options.AutoSize = $true
    $options.ColumnCount = 2
    $options.Padding = New-Object Windows.Forms.Padding((Px 8), (Px 6), (Px 8), 0)
    [void]$options.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    [void]$options.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $lblVer = New-Object Windows.Forms.Label
    $lblVer.Text = '版本号：'
    $lblVer.AutoSize = $true
    $lblVer.Anchor = 'Left'
    $verRow = New-Object Windows.Forms.FlowLayoutPanel
    $verRow.AutoSize = $true
    $verRow.WrapContents = $false
    $verRow.Margin = New-Object Windows.Forms.Padding(0)
    $txtVer = New-Object Windows.Forms.TextBox
    $txtVer.Width = Px 80
    $txtVer.Anchor = 'Left'
    $btnMinor = New-Button '小版本 +0.1'
    $btnMajor = New-Button '大版本 +1'
    $chkTag = New-Object Windows.Forms.CheckBox
    $chkTag.Text = '打版本标签'
    $chkTag.Checked = $true
    $chkTag.AutoSize = $true
    $chkTag.Anchor = 'Left'
    $lblLatest = New-Object Windows.Forms.Label
    $lblLatest.AutoSize = $true
    $lblLatest.ForeColor = [Drawing.Color]::DimGray
    $lblLatest.Anchor = 'Left'
    $verRow.Controls.AddRange(@($txtVer, $btnMinor, $btnMajor, $chkTag, $lblLatest))
    $lblMsg = New-Object Windows.Forms.Label
    $lblMsg.Text = '更新说明：'
    $lblMsg.AutoSize = $true
    $txtMsg = New-Object Windows.Forms.TextBox
    $txtMsg.Multiline = $true
    $txtMsg.ScrollBars = 'Vertical'
    $txtMsg.Height = Px 56
    $txtMsg.Dock = 'Fill'
    $lblStatus = New-Object Windows.Forms.Label
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [Drawing.Color]::DimGray
    $options.Controls.Add($lblVer, 0, 0); $options.Controls.Add($verRow, 1, 0)
    $options.Controls.Add($lblMsg, 0, 1); $options.Controls.Add($txtMsg, 1, 1)
    $options.Controls.Add($lblStatus, 1, 2)

    # Buttons
    $bar = New-Object Windows.Forms.Panel
    $bar.Dock = 'Bottom'
    $bar.Height = Px 46
    $left = New-Object Windows.Forms.FlowLayoutPanel
    $left.Dock = 'Fill'
    $left.Padding = New-Object Windows.Forms.Padding((Px 6))
    $left.WrapContents = $false
    $right = New-Object Windows.Forms.FlowLayoutPanel
    $right.Dock = 'Right'
    $right.AutoSize = $true
    $right.FlowDirection = 'RightToLeft'
    $right.WrapContents = $false
    $right.Padding = New-Object Windows.Forms.Padding((Px 6))
    $btnAll = New-Button '全选'
    $btnNone = New-Button '全不选'
    $btnIgnore = New-Button '忽略所选'
    $btnHistory = New-Button '版本历史'
    $btnGitHub = New-Button 'GitHub'
    $btnOverleaf = New-Button 'Overleaf'
    $btnRemote = New-Button '关联 GitHub…'
    $btnAbort = New-Button '放弃合并'
    $btnSync = New-Button '同步到 GitHub' 120
    $btnSync.Font = New-Object Drawing.Font($f.Font, [Drawing.FontStyle]::Bold)
    $btnCancel = New-Button '关闭' 80
    $btnCancel.DialogResult = 'Cancel'
    $left.Controls.AddRange(@($btnAll, $btnNone, $btnIgnore, $btnHistory, $btnGitHub, $btnOverleaf, $btnRemote, $btnAbort))
    $right.Controls.AddRange(@($btnCancel, $btnSync))
    $bar.Controls.Add($left)
    $bar.Controls.Add($right)

    $f.Controls.Add($lv)
    $f.Controls.Add($header)
    $f.Controls.Add($options)
    $f.Controls.Add($bar)
    $f.CancelButton = $btnCancel

    $render = {
        $st = $script:State
        $branch = $st.Branch
        if (-not $branch) { $branch = '（游离 HEAD）' }
        $lblProject.Text = "项目：$($st.Root)    分支：$branch"
        $lblRemote.ForeColor = [Drawing.Color]::DimGray
        $where = $st.WebUrl
        if (-not $where) { $where = $st.RemoteUrl }
        if (-not $st.RemoteUrl) {
            $lblRemote.Text = 'GitHub：还没有关联远端仓库，同步只会在本地提交。'
            $lblRemote.ForeColor = [Drawing.Color]::DarkOrange
        } elseif ($st.FetchError) {
            $lblRemote.Text = "GitHub：$where    无法连接，稍后同步时会重试。"
            $lblRemote.ForeColor = [Drawing.Color]::DarkOrange
        } else {
            $parts = @()
            if ($st.Behind) { $parts += "远端有 $($st.Behind) 个新提交（可能是老师在 Overleaf 上的修改），同步时会自动合并" }
            if ($st.Ahead) { $parts += "本地有 $($st.Ahead) 个提交还没推送" }
            if (-not $parts) { $parts += '与 GitHub 一致' }
            $lblRemote.Text = "GitHub：$where    " + ($parts -join '；')
            if ($st.Behind) { $lblRemote.ForeColor = [Drawing.Color]::RoyalBlue }
        }
        if ($st.Merging) {
            $lblRemote.Text += "`n正在合并 Overleaf 的修改：处理完红色的冲突文件后，再点「同步」完成合并。"
            $lblRemote.ForeColor = [Drawing.Color]::Firebrick
        }

        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($c in $st.Changes) {
            $item = New-Object Windows.Forms.ListViewItem($c.Kind)
            [void]$item.SubItems.Add($c.Path)
            [void]$item.SubItems.Add((Format-Size $c.Size))
            $item.Checked = $c.Default
            $item.Tag = $c
            if ($c.Conflict) { $item.ForeColor = [Drawing.Color]::Firebrick }
            elseif ($c.Size -gt $script:MaxFileSize) { $item.ForeColor = [Drawing.Color]::DarkOrange }
            elseif (-not $c.Default) { $item.ForeColor = [Drawing.Color]::Gray }
            [void]$lv.Items.Add($item)
        }
        $lv.EndUpdate()
        if (-not $st.Changes.Count) { $lblList.Text = '本地没有新的修改。' }

        $latest = $st.LatestTag
        if (-not $latest) { $latest = '无' }
        $lblLatest.Text = "（上一个版本：$latest）"
        $txtVer.Text = Get-NextVersion $st.LatestTag 'minor'
        $btnGitHub.Enabled = [bool]$st.WebUrl
        $btnRemote.Visible = -not $st.RemoteUrl
        $btnAbort.Visible = $st.Merging
        $btnHistory.Enabled = $st.Tags.Count -gt 0
        $lblStatus.Text = ''
    }

    $refresh = {
        param([bool]$Fetch)
        $f.UseWaitCursor = $true
        try { $script:State = Get-SyncState -Fetch:$Fetch } finally { $f.UseWaitCursor = $false }
        & $render
    }

    $setBusy = {
        param([bool]$Busy)
        foreach ($c in @($lv, $options, $bar)) { $c.Enabled = -not $Busy }
        $f.UseWaitCursor = $Busy
        [Windows.Forms.Application]::DoEvents()
    }

    $btnAll.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $true } })
    $btnNone.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $false } })
    $btnMinor.Add_Click({ $txtVer.Text = Get-NextVersion $script:State.LatestTag 'minor'; $chkTag.Checked = $true })
    $btnMajor.Add_Click({ $txtVer.Text = Get-NextVersion $script:State.LatestTag 'major'; $chkTag.Checked = $true })
    $chkTag.Add_CheckedChanged({ $txtVer.Enabled = $chkTag.Checked })
    $btnGitHub.Add_Click({ Start-Process $script:State.WebUrl })

    $btnIgnore.Add_Click({
        $paths = @($lv.SelectedItems | Where-Object { $_.Tag.Untracked } | ForEach-Object { $_.Tag.Path })
        if (-not $paths.Count) { Show-Info '请先用鼠标选中（高亮）要忽略的「新文件」。已纳入版本管理的文件不能这样忽略。'; return }
        if (-not (Show-YesNo ("以后同步时不再显示这些文件（写入 .gitignore）：`n`n" + ($paths -join "`n")))) { return }
        Add-ToGitIgnore $paths
        & $refresh $false
    })

    $lv.Add_DoubleClick({
        if (-not $lv.SelectedItems.Count) { return }
        $c = $lv.SelectedItems[0].Tag
        if ($c.Untracked) {
            Show-Info "$($c.Path)`n`n这是新文件，还没有纳入版本管理。勾选后同步即可上传。"
            return
        }
        $diffArgs = @('diff', '--cached', '--', $c.Path)
        if ($script:State.HasHead) { $diffArgs = @('diff', 'HEAD', '--', $c.Path) }
        $diff = (Invoke-Git $diffArgs -AllowFail).Out
        if (-not $diff) { $diff = '（没有文本差异）' }
        Show-TextWindow "改动：$($c.Path)" $diff
    })

    $btnOverleaf.Add_Click({
        $url = $script:State.OverleafUrl
        if (-not $url -or [Windows.Forms.Control]::ModifierKeys -eq 'Shift') {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $prompt = '粘贴这个论文对应的 Overleaf 项目链接（浏览器地址栏里的 https://www.overleaf.com/project/...）。以后按住 Shift 再点此按钮可修改。'
            $url = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Overleaf 项目链接', $url).Trim()
            if (-not $url) { return }
            Invoke-Git @('config', 'overleaf-sync.url', $url) | Out-Null
            $script:State.OverleafUrl = $url
        }
        Start-Process $url
    })

    $btnRemote.Add_Click({
        $choice = Show-RemoteDialog (ConvertTo-RepoName (Split-Path $script:Root -Leaf)) $false
        if (-not $choice) { return }
        & $setBusy $true
        try {
            Set-Remote -RemoteUrl $choice.Url -RepoName $choice.RepoName -Private $choice.Private
            & $refresh $true
        } catch {
            Show-Info $_.Exception.Message 'Error'
        } finally { & $setBusy $false }
    })

    $btnAbort.Add_Click({
        if (-not (Show-YesNo '放弃这次合并？你本地的修改会保留，Overleaf 上的修改暂不合并（下次同步时会再次尝试）。')) { return }
        Invoke-Git @('merge', '--abort') -AllowFail | Out-Null
        & $refresh $false
    })

    $btnHistory.Add_Click({
        $script:Restored = ''
        Show-HistoryDialog
        if ($script:Restored) {
            & $refresh $false
            $txtMsg.Text = "恢复到 $($script:Restored) 的内容"
            Show-Info "已恢复为 $($script:Restored) 的内容（尚未提交）。`nTeXstudio 会提示文件已在外部修改，请选择重新加载并检查；确认无误后点「同步到 GitHub」。"
        }
    })

    $btnSync.Add_Click({
        $st = $script:State
        $paths = @($lv.CheckedItems | ForEach-Object { $_.Tag.Path })
        $tag = ''
        if ($chkTag.Checked) { $tag = $txtVer.Text.Trim() }
        if (-not $paths.Count -and -not $st.Merging -and -not $st.Behind -and -not $st.Ahead -and $st.RemoteBranch) {
            Show-Info '没有需要同步的内容：本地没有勾选的修改，GitHub 上也没有新提交。'
            return
        }
        $big = @($lv.CheckedItems | Where-Object { $_.Tag.Size -gt $script:MaxFileSize } | ForEach-Object { $_.Tag.Path })
        if ($big.Count -and -not (Show-YesNo ("以下文件超过 50 MB，Overleaf 无法导入（GitHub 上限 100 MB），仍然提交？`n`n" + ($big -join "`n")) 'Warning')) { return }

        & $setBusy $true
        try {
            $progress = { param($t) $lblStatus.Text = $t; [Windows.Forms.Application]::DoEvents() }
            $r = Invoke-Sync -State $st -Paths $paths -Message $txtMsg.Text -Tag $tag -Progress $progress
            if ($r.Conflicts.Count) {
                & $refresh $false
                Show-Info ("你和 Overleaf 上改了同一处内容，以下文件有冲突：`n`n  " + ($r.Conflicts -join "`n  ") +
                    "`n`n文件里已用标记把两边的版本都保留下来：`n" +
                    "  <<<<<<< HEAD 到 ======= 之间是你的版本`n" +
                    "  ======= 到 >>>>>>> 之间是 Overleaf 上的版本`n`n" +
                    "请在 TeXstudio 中重新加载这些文件，保留正确的内容、删掉三行标记并保存，然后再点「同步到 GitHub」。" +
                    "`n不想合并的话，可以点「放弃合并」。") 'Warning'
                return
            }
            $lines = @()
            if ($r.Committed) {
                $v = $r.Tag
                if (-not $v) { $v = '一个新提交' }
                $lines += "已提交：$v"
            }
            if ($r.Incoming) { $lines += "已合并 GitHub 上的 $($r.Incoming) 个新提交（Overleaf 的修改已同步到本地）" }
            if ($r.Pushed) { $lines += '已推送到 GitHub' }
            $lines += $r.Notes
            $text = ($lines | ForEach-Object { "✔ $_" }) -join "`n"
            if ($r.Pushed) {
                $text += "`n`n下一步：在 Overleaf 打开项目 → 左上角 Menu → GitHub（新版界面在 Integrations / Sync 里）→ Pull GitHub changes into Overleaf。"
            }
            if ($r.Pushed -and $st.OverleafUrl) {
                if (Show-YesNo ($text + "`n`n现在打开 Overleaf 项目？") 'Information') { Start-Process $st.OverleafUrl }
            } else {
                Show-Info $text
            }
            $f.Close()
        } catch {
            Show-Info $_.Exception.Message 'Error'
            try { & $refresh $false } catch { }
        } finally {
            & $setBusy $false
        }
    })

    $f.Add_Shown({
        $f.Activate()
        $f.TopMost = $false
        $lblStatus.Text = '正在连接 GitHub…'
        & $setBusy $true
        try { & $refresh $true } finally { & $setBusy $false }
        $txtMsg.Focus()
    })

    $script:State = Get-SyncState
    & $render
    [void]$f.ShowDialog()
}

function Initialize-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    try {
        Add-Type -Namespace OverleafSync -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
        [void][OverleafSync.Native]::SetProcessDPIAware()
    } catch { }
    [Windows.Forms.Application]::EnableVisualStyles()
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = $g.DpiX / 96.0
    $g.Dispose()
}

#endregion

#region Entry point

function Resolve-Target {
    if ($PathHex) {
        $chars = for ($i = 0; $i + 4 -le $PathHex.Length; $i += 4) { [char][Convert]::ToInt32($PathHex.Substring($i, 4), 16) }
        $script:Path = -join $chars
    }
    if (-not $Path) { $script:Path = (Get-Location).Path }
    $full = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full -PathType Container) { return @{ Dir = $full.TrimEnd('\'); MainTex = '' } }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "找不到文件：$full" }
    $mainTex = ''
    if ([IO.Path]::GetExtension($full) -eq '.tex') { $mainTex = $full }
    @{ Dir = (Split-Path $full); MainTex = $mainTex }
}

function Invoke-Cli($Target) {
    if ($Init) {
        Initialize-Repo -Dir $Target.Dir -MainTex $Target.MainTex -RemoteUrl $RepoUrl
        [Console]::Out.WriteLine("Initialized $script:Root")
        return 0
    }
    $script:Root = Get-RepoRoot $Target.Dir
    if (-not $script:Root) { throw "$($Target.Dir) 不是 Git 仓库，请先用 -Init 初始化。" }
    if ($Restore) {
        Restore-Version $Restore
        [Console]::Out.WriteLine("Restored $Restore")
        return 0
    }
    $st = Get-SyncState -Fetch
    if ($st.FetchError) { throw $st.FetchError }
    $paths = @($st.Changes | Where-Object Default | ForEach-Object Path)
    $tag = $Version
    if ($Version -eq 'none') { $tag = '' } elseif (-not $Version) { $tag = Get-NextVersion $st.LatestTag $Bump }
    $r = Invoke-Sync -State $st -Paths $paths -Message $Message -Tag $tag
    [Console]::Out.WriteLine(('Committed={0} Incoming={1} Tag={2} Pushed={3} Conflicts={4}' -f $r.Committed, $r.Incoming, $r.Tag, $r.Pushed, ($r.Conflicts -join ',')))
    if ($r.Conflicts.Count) { return 2 }
    0
}

function Invoke-Gui($Target) {
    Initialize-Gui
    $mutex = New-Object Threading.Mutex($false, 'Local\OverleafSync')
    if (-not $mutex.WaitOne(0)) { return }   # a sync window is already open
    try {
        $script:Root = Get-RepoRoot $Target.Dir
        if (-not $script:Root) {
            $question = "「$($Target.Dir)」 还没有版本管理。`n`n是否在这个文件夹初始化 Git，并关联一个 GitHub 仓库？" +
                "`n（会自动创建 .gitignore，排除 .aux/.log 等编译产生的文件）"
            if (-not (Show-YesNo $question)) { return }
            $choice = Show-RemoteDialog (ConvertTo-RepoName (Split-Path $Target.Dir -Leaf)) $true
            if (-not $choice) { return }
            Initialize-Repo -Dir $Target.Dir -MainTex $Target.MainTex -RemoteUrl $choice.Url -RepoName $choice.RepoName -Private $choice.Private
        }
        Show-MainDialog
    } finally {
        $mutex.ReleaseMutex()
    }
}

try {
    $script:GitExe = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $script:GitExe) { throw '没有找到 Git。请先安装 Git for Windows：https://git-scm.com/download/win' }
    $target = Resolve-Target
    if ($NoGui) { exit (Invoke-Cli $target) }
    Invoke-Gui $target
} catch {
    Write-Log ('ERROR ' + $_.Exception.Message + [Environment]::NewLine + $_.ScriptStackTrace)
    if ($NoGui) {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Overleaf 同步', 'OK', 'Error')
    } catch { }
    exit 1
}

#endregion
