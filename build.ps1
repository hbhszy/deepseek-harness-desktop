param(
    [switch]$Run
)

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$source = Join-Path $projectRoot 'src\Launcher.cs'
$manifest = Join-Path $projectRoot 'app.manifest'
$assets = Join-Path $projectRoot 'assets'
$webView = Join-Path $projectRoot 'vendor\WebView2'
$launcherScript = Join-Path $projectRoot 'scripts\start-dsh-web.cmd'
$buildDirectory = Join-Path $projectRoot 'build'
$distDirectory = Join-Path $projectRoot 'dist'
$builtExe = Join-Path $buildDirectory 'DeepSeek Harness.exe'
$distExe = Join-Path $distDirectory 'DeepSeek Harness.exe'

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) {
    throw '找不到 .NET Framework C# 编译器。请启用 Windows 的 .NET Framework 4.x。'
}

$requiredFiles = @(
    $source,
    $manifest,
    (Join-Path $assets 'whale-blue.ico'),
    (Join-Path $assets 'whale-white.ico'),
    $launcherScript,
    (Join-Path $webView 'lib\net462\Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $webView 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'),
    (Join-Path $webView 'runtimes\win-x64\native\WebView2Loader.dll')
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "缺少构建文件：$file"
    }
}

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    ('/out:' + $builtExe),
    ('/win32icon:' + (Join-Path $assets 'whale-blue.ico')),
    ('/win32manifest:' + $manifest),
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Net.Http.dll',
    ('/reference:' + (Join-Path $webView 'lib\net462\Microsoft.Web.WebView2.Core.dll')),
    ('/reference:' + (Join-Path $webView 'lib\net462\Microsoft.Web.WebView2.WinForms.dll')),
    ('/resource:' + (Join-Path $webView 'lib\net462\Microsoft.Web.WebView2.Core.dll') + ',DeepSeekHarnessDesktop.Resources.Microsoft.Web.WebView2.Core.dll'),
    ('/resource:' + (Join-Path $webView 'lib\net462\Microsoft.Web.WebView2.WinForms.dll') + ',DeepSeekHarnessDesktop.Resources.Microsoft.Web.WebView2.WinForms.dll'),
    ('/resource:' + (Join-Path $webView 'runtimes\win-x64\native\WebView2Loader.dll') + ',DeepSeekHarnessDesktop.Resources.WebView2Loader.dll'),
    ('/resource:' + $launcherScript + ',DeepSeekHarnessDesktop.Resources.start-dsh-web.cmd'),
    ('/resource:' + (Join-Path $assets 'whale-blue.ico') + ',DeepSeekHarnessDesktop.Resources.whale-blue.ico'),
    ('/resource:' + (Join-Path $assets 'whale-white.ico') + ',DeepSeekHarnessDesktop.Resources.whale-white.ico'),
    $source
)

& $compiler $arguments
if ($LASTEXITCODE -ne 0) {
    throw "编译失败，退出代码：$LASTEXITCODE"
}

Copy-Item -LiteralPath $builtExe -Destination $distExe -Force
$file = Get-Item -LiteralPath $distExe
$hash = Get-FileHash -LiteralPath $distExe -Algorithm SHA256

Write-Host ''
Write-Host '构建完成：' -ForegroundColor Green
Write-Host $file.FullName
Write-Host ("版本：{0}" -f $file.VersionInfo.FileVersion)
Write-Host ("大小：{0:N0} 字节" -f $file.Length)
Write-Host ("SHA256：{0}" -f $hash.Hash)

if ($Run) {
    & $distExe
}
