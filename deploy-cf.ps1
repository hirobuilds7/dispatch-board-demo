# 配車ボード動作検証デモ（静的HTML）を Cloudflare Workers へ デプロイ + 検証する
# 使い方:
#   検証だけ（デプロイせん）: powershell -ExecutionPolicy Bypass -File .\deploy-cf.ps1 -DryRun
#   本番へ出す             : powershell -ExecutionPolicy Bypass -File .\deploy-cf.ps1
# 正本: memory/project-cloudflare.md（段階②）／設計書 D:/work/ops/sekkei/2026-09-03_cloudflare-stage2.md
#
# ★LP1（D:\work\lp-sample\deploy-cf.ps1）と同じ型。違いは3つ：
#   (1) 配るのは index.html と 3d.html の2本だけ＝README.md は配らん（提案文の内輪メモが客に見える）
#   (2) このデモは提案用（PF未掲載・架空データ）＝noindex は維持する側。_headers は二重防御
#   (3) ビルド工程が無い（素のHTML）＝dist は「原本からの転写」だけ
param(
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# 1) dist/ を毎回作り直し（公開ホワイトリストのみ。フォルダ直デプロイは README や .git が混入する）
if (Test-Path "$root\dist") { Remove-Item -Recurse -Force "$root\dist" }
New-Item -ItemType Directory -Force "$root\dist" | Out-Null
$whitelist = @("index.html", "3d.html")
foreach ($f in $whitelist) { Copy-Item "$root\$f" "$root\dist\" }
Copy-Item "$root\public\_headers" "$root\dist\_headers"

# 1-b) ★出したらアカンもんが混ざってへんか（README.md・.md 全般・画像原本）
$stray = Get-ChildItem -Recurse -File "$root\dist" |
  Where-Object { $whitelist -notcontains $_.Name -and $_.Name -ne "_headers" }
if ($stray.Count -gt 0) {
  $stray | ForEach-Object { Write-Output ("STRAY {0}" -f $_.Name) }
  Write-Error ("dist に出したらアカンファイルが {0} 件混ざっとる" -f $stray.Count)
}
$distKB = [math]::Round(((Get-ChildItem -Recurse -File "$root\dist" | Measure-Object Length -Sum).Sum / 1KB), 1)
Write-Output ("dist = {0} files / {1} KB" -f (Get-ChildItem -Recurse -File "$root\dist").Count, $distKB)

# 2) 参照切れチェック＝HTML が指しとる相対アセットが dist に居るか（デプロイ前に落とす）
$missing = 0
foreach ($h in $whitelist) {
  $refs = [regex]::Matches((Get-Content -Raw "$root\dist\$h"), '(?:src|href)="(?!https?:|data:|mailto:|#)([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value }
  foreach ($r in ($refs | Sort-Object -Unique)) {
    $p = Join-Path "$root\dist" ($r -replace '/', '\')
    if (-not (Test-Path $p)) { Write-Output ("MISSING {0} <- {1}" -f $r, $h); $missing++ }
  }
}
if ($missing -gt 0) { Write-Error ("HTML が参照する {0} 件が dist に無い" -f $missing) }
Write-Output "OK  参照切れなし"

# 3) dry-run（Opus 段はここまで）
if (Test-Path "$root\.wrangler-dry") { Remove-Item -Recurse -Force "$root\.wrangler-dry" }
npx --yes wrangler deploy --dry-run --outdir=.wrangler-dry
if ($LASTEXITCODE -ne 0) { Write-Error "wrangler dry-run failed (exit $LASTEXITCODE)" }
if ($DryRun) { Write-Output "DRY-RUN OK（-DryRun 指定＝ここで終了。本番デプロイはしてへん）"; exit 0 }

# 4) デプロイ（★ここから先は本番。Fable が実行する段）
npx --yes wrangler deploy
if ($LASTEXITCODE -ne 0) { Write-Error "wrangler deploy failed (exit $LASTEXITCODE)" }

# 5) 検証＝出荷される値そのもの（本文MD5を dist と突合 + ヘッダ実測）
$base = "https://dispatch-board-demo.hirobuilds7.workers.dev"

# ★伝播待ち＝デプロイ直後は数十秒 404／旧版を返す（2026-08-25 に LP2・PF で実測）。
#   待つべきは「200」やなく「中身が新版になること」。
Write-Output "伝播待ち..."
$localIndex = (Get-FileHash -Algorithm MD5 "$root\dist\index.html").Hash
$ready = $false
for ($i = 1; $i -le 30; $i++) {
  $tmp = [System.IO.Path]::GetTempFileName()
  curl.exe -sL --max-time 10 -o $tmp "$base/"
  $remoteIndex = (Get-FileHash -Algorithm MD5 $tmp).Hash
  Remove-Item $tmp -Force
  if ($remoteIndex -eq $localIndex) { Write-Output ("  {0}回目で新版の index.html が返った" -f $i); $ready = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $ready) { Write-Error "90秒待っても新版の index.html が返らん＝デプロイを疑う" }

$fail = 0
foreach ($f in $whitelist) {
  $local = (Get-FileHash -Algorithm MD5 "$root\dist\$f").Hash
  $tmp = [System.IO.Path]::GetTempFileName()
  curl.exe -sL --max-time 30 -o $tmp "$base/$f"
  $remote = (Get-FileHash -Algorithm MD5 $tmp).Hash
  Remove-Item $tmp -Force
  if ($local -eq $remote) { Write-Output ("OK  {0}  {1}" -f $f, $remote) }
  else { Write-Output ("NG  {0}  local={1} remote={2}" -f $f, $local, $remote); $fail++ }
}
# トップ（/）も index.html と同一か
$tmp = [System.IO.Path]::GetTempFileName()
curl.exe -sL --max-time 30 -o $tmp "$base/"
if ((Get-FileHash -Algorithm MD5 $tmp).Hash -eq $localIndex) { Write-Output "OK  /  = index.html" }
else { Write-Output "NG  / が index.html と違う"; $fail++ }
Remove-Item $tmp -Force

# 6) ★配ってへんもんが本当に出てへんか（陰性対照）
foreach ($ng in @("README.md", "_headers")) {
  $code = curl.exe -s -o NUL -w "%{http_code}" --max-time 20 "$base/$ng"
  if ($code -eq "404") { Write-Output ("OK  /{0} -> 404（配ってへん）" -f $ng) }
  else { Write-Output ("NG  /{0} -> {1}（配信されとる）" -f $ng, $code); $fail++ }
}

# 7) ★このデモは noindex を"付ける"側＝X-Robots-Tag が出とることを確認する
Write-Output "--- headers（X-Robots-Tag: noindex が出とるのが正） ---"
$hdr = curl.exe -sI --max-time 20 "$base/"
$hdr
if ($hdr -match "(?i)x-robots-tag:\s*noindex") { Write-Output "OK  X-Robots-Tag: noindex あり" }
else { Write-Output "NG  X-Robots-Tag: noindex が出てへん"; $fail++ }

if ($fail -gt 0) { Write-Error ("VERIFY FAILED: {0} check(s) failed" -f $fail) }
Write-Output "VERIFY OK: 2ファイル hash 一致 + 非公開2本が404 + noindex あり"
