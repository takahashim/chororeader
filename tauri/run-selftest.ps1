# 動作確認を 1 回走らせ、結果を読み上げる。
#
# 画面のあるアプリは PowerShell が終了を待たない。
# そのまま書くと、起こしただけで段が「成功」し、中身が空のまま通ってしまう。
# 実際それで通していた。Start-Process で待ち、結果が無ければ落とす。
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Book
)

$ErrorActionPreference = "Stop"

$out = Join-Path (Get-Location) "selftest-$([System.IO.Path]::GetRandomFileName()).json"
$env:CHORO_SELFTEST = "1"
$env:CHORO_SELFTEST_OUT = $out

$args = @()
if ($Book) { $args += $Book }

$process = if ($args.Count -gt 0) {
    Start-Process -FilePath $Exe -ArgumentList $args -PassThru -Wait -NoNewWindow
} else {
    Start-Process -FilePath $Exe -PassThru -Wait -NoNewWindow
}

if (-not (Test-Path $out)) {
    throw "結果が書かれなかった。動作確認そのものが走っていない（終了コード $($process.ExitCode)）"
}

Get-Content $out
Remove-Item $out -Force

if ($process.ExitCode -ne 0) {
    throw "動作確認が不合格（終了コード $($process.ExitCode)）"
}
