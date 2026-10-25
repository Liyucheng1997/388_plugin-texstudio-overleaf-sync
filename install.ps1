<#
.SYNOPSIS
    Installs the "Overleaf 同步" macro into TeXstudio.

.DESCRIPTION
    Copies src\OverleafSync.ps1 to %APPDATA%\texstudio\overleaf-sync\ and writes a
    TeXstudio macro file (macro\Macro_N.txsMacro) that calls it. TeXstudio must be
    closed: it loads macros at start-up and rewrites the macro files when it exits.
    Re-running the installer updates an existing installation in place.

.PARAMETER Shortcut
    Keyboard shortcut for the macro (default Ctrl+Alt+G).

.PARAMETER Uninstall
    Removes the macro and the installed script.
#>
param(
    [string]$Shortcut = 'Ctrl+Alt+G',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$macroName = 'Overleaf 同步'
$configDir = Join-Path $env:APPDATA 'texstudio'
$macroDir = Join-Path $configDir 'macro'
$installDir = Join-Path $configDir 'overleaf-sync'
$installedScript = Join-Path $installDir 'OverleafSync.ps1'

if (-not (Test-Path -LiteralPath $configDir)) {
    throw "没有找到 TeXstudio 配置目录 $configDir。请先运行一次 TeXstudio。"
}
if (Get-Process texstudio -ErrorAction SilentlyContinue) {
    throw 'TeXstudio 正在运行。请先关闭 TeXstudio，再运行安装（TeXstudio 退出时会覆盖宏文件）。'
}
if ($installedScript -match '[%?@#|]') {
    throw "安装路径 $installedScript 含有 TeXstudio 会特殊处理的字符（% ? @ # |），无法安装。"
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    Write-Warning '没有找到 Git。同步前请先安装 Git for Windows：https://git-scm.com/download/win'
}

# TeXstudio loads Macro_0, Macro_1, ... and stops at the first missing index.
New-Item -ItemType Directory -Path $macroDir -Force | Out-Null
$index = 0
$slot = -1
while (Test-Path -LiteralPath (Join-Path $macroDir "Macro_$index.txsMacro")) {
    $existing = Get-Content -LiteralPath (Join-Path $macroDir "Macro_$index.txsMacro") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($existing.name -eq $macroName) { $slot = $index }
    $index++
}

if ($Uninstall) {
    if ($slot -ge 0) {
        # Shift the following macros down so the numbering stays contiguous.
        for ($i = $slot; $i -lt $index - 1; $i++) {
            Move-Item -LiteralPath (Join-Path $macroDir "Macro_$($i + 1).txsMacro") -Destination (Join-Path $macroDir "Macro_$i.txsMacro") -Force
        }
        if ($slot -eq $index - 1) { Remove-Item -LiteralPath (Join-Path $macroDir "Macro_$slot.txsMacro") }
    }
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    Write-Host '已卸载 Overleaf 同步宏。'
    return
}
if ($slot -lt 0) { $slot = $index }

# Windows PowerShell 5.1 needs a BOM to read the Chinese text in the script.
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'src\OverleafSync.ps1') -Raw -Encoding UTF8
[IO.File]::WriteAllText($installedScript, $source, (New-Object System.Text.UTF8Encoding($true)))

$js = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'src\macro.js') -Raw -Encoding UTF8
$js = $js.Replace('__SCRIPT_PATH__', ($installedScript -replace '\\', '/'))
$macro = [ordered]@{
    abbrev        = ''
    description   = @('一键同步到 GitHub（再在 Overleaf 中 Pull），自动编版本号。')
    formatVersion = 1
    menu          = ''
    name          = $macroName
    shortcut      = $Shortcut
    tag           = @($js.TrimEnd() -split "`r?`n")
    trigger       = ''
}
$macroFile = Join-Path $macroDir "Macro_$slot.txsMacro"
[IO.File]::WriteAllText($macroFile, ($macro | ConvertTo-Json -Depth 3), $utf8)

Write-Host "已安装：$macroFile"
Write-Host "同步脚本：$installedScript"
Write-Host ''
Write-Host "启动 TeXstudio 后，按 $Shortcut 或点菜单 宏 → $macroName 即可同步。"
Write-Host '第一次运行时 TeXstudio 会询问是否信任这个脚本，请选择 「Yes, allow all calls it will ever make」。'
