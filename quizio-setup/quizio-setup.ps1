# Quizio git bridge - one-time setup (Windows PowerShell 5.1+)
# Run:  powershell -ExecutionPolicy Bypass -File quizio-setup.ps1
# Safe: makes a backup first, never deletes or rewrites your files, aborts on anything suspicious.

param(
  [string]$Root = 'D:\CLAUDE_PROJECTS\QUIZIO',
  [string]$Remote = 'https://github.com/SzabiM/quizio.git'
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM (a BOM breaks .gitignore)
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Die($m) { Say "STOP: $m" 'Red'; Read-Host 'Press Enter to close'; exit 1 }
function WriteFile($rel, $text) {
  $p = Join-Path $Root $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
  $t = $text -replace "`r`n", "`n"
  if ($rel -match '\.(ps1|vbs|cmd)$') { $t = $t -replace "`n", "`r`n" }
  [IO.File]::WriteAllText($p, $t, $utf8)
}

# 0. Checks
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Die 'Git is not installed. Run:  winget install --id Git.Git -e   then open a NEW PowerShell and run this again.'
}
if (-not (Test-Path (Join-Path $Root 'package.json'))) { Die "No package.json in $Root - wrong folder?" }
if (Test-Path (Join-Path $Root '.git')) { Die "$Root is already a git repo. Nothing changed." }
Set-Location $Root

# 1. Backup (code + data + assets; skips output/, node_modules/, cache/, public\job)
$bak = "$Root" + '_backup_' + (Get-Date -Format 'yyyyMMdd_HHmm')
Say "Backing up to $bak ..." 'Cyan'
robocopy $Root $bak /E /XD node_modules output cache venv .venv __pycache__ .git "$Root\public\job" /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Die "Backup failed (robocopy code $LASTEXITCODE)." }

# 2. .gitignore (merged with an existing one) and .gitattributes
# Whitelist: only what Claude needs (code for validate/photo tools + quiz data + photos).
# Everything else (tools/chatterbox, public/, output/, venvs, models, .env ...) never leaves the PC.
$allow = @(
  '/*',
  '!/.gitignore', '!/.gitattributes', '!/.github/',
  '!/package.json', '!/package-lock.json', '!/tsconfig.json', '!/remotion.config.ts',
  '!/src/', '!/scripts/', '!/docs/', '!/mcp/', '!/gui/', '!/data/', '!/credits.json',
  '!/assets/', '/assets/*', '!/assets/photos/',
  '!/tools/', '/tools/*', '!/tools/ci/', '!/tools/git-sync/'
)
$ignore = @(
  'node_modules/', '.env', '.env.*', '.claude/', 'cache/', '*.mp4', '*.exe', '*.log',
  '*token*.json', '*credentials*.json', '*client_secret*', 'tools/git-sync/state/',
  'venv/', '.venv/', '__pycache__/', '*.pyc', '*.pyd', '*.dll', '*.lib', '*.so', '*.dylib',
  '*.safetensors', '*.pt', '*.pth', '*.ckpt', '*.onnx', '*.gguf', '*.bin', '.cache/'
)
$gi = Join-Path $Root '.gitignore'
$existing = @(); if (Test-Path $gi) { $existing = @(Get-Content $gi | Where-Object { $allow -notcontains $_ -and $ignore -notcontains $_ }) }
WriteFile '.gitignore' ((@($allow) + @('') + $existing + @('') + $ignore) -join "`n")

WriteFile '.gitattributes' @'
* text=auto
*.jpg binary
*.jpeg binary
*.png binary
*.webp binary
*.gif binary
*.ico binary
*.mp3 binary
*.wav binary
*.ogg binary
*.m4a binary
*.ttf binary
*.otf binary
*.woff binary
*.woff2 binary
*.ps1 text eol=crlf
*.vbs text eol=crlf
*.sh text eol=lf
'@

# 3. Cloud check + auto-merge (GitHub Actions)
WriteFile '.github/workflows/quiz-check.yml' @'
name: quiz-check
on:
  push:
    branches: ['claude/**']
permissions:
  contents: write
concurrency:
  group: merge-to-main
  cancel-in-progress: false
jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Guard (paths, sizes, secrets)
        id: guard
        run: bash tools/ci/guard.sh
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - name: Typecheck
        run: npx tsc --noEmit -p .
      - name: Validate new or changed quizzes
        run: |
          for f in $(git diff --name-only --diff-filter=AM origin/main...HEAD -- 'data/*.json' | grep -v '^data/brain/' || true); do
            echo "== $f"; npm run validate -- "$f"
          done
      - name: Merge into main
        if: steps.guard.outputs.automerge == 'true'
        run: |
          git config user.name "quizio-bot"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          for i in 1 2 3; do
            git fetch origin main
            git checkout -B main origin/main
            git merge --no-ff "origin/${GITHUB_REF_NAME}" -m "Auto-merge ${GITHUB_REF_NAME}" || { git merge --abort; echo "Merge conflict - needs a human"; exit 1; }
            git push origin main && exit 0
            sleep 5
          done
          exit 1
'@

WriteFile 'tools/ci/guard.sh' @'
#!/usr/bin/env bash
# Blocks secrets/huge files; auto-merge only for new quizzes, photos, credits and brain data.
set -euo pipefail
base=$(git merge-base origin/main HEAD)
auto=true; fail=0
allowed='^(data/[^/]+\.json|data/brain/.+|assets/photos/.+|credits\.json)$'
secretpath='(^|/)\.env($|\.)|^\.claude/|(^|/)[^/]*(credential|client_secret)[^/]*$|(^|/)[^/]*token[^/]*\.json$|(^|/)id_(rsa|ed25519)'
while IFS=$'\t' read -r st a b; do
  p="${b:-$a}"
  if [[ "$p" =~ $secretpath ]]; then echo "BLOCKED file: $p"; fail=1; fi
  if [[ "$st" != D* && -f "$p" ]] && [ "$(stat -c%s "$p")" -gt 5242880 ]; then echo "BLOCKED >5MB: $p"; fail=1; fi
  if ! [[ "$p" =~ $allowed ]]; then echo "needs review (code/other): $p"; auto=false; fi
  if [[ "$p" =~ ^data/[^/]+\.json$ && "$st" != A* ]]; then echo "needs review (existing quiz changed): $p"; auto=false; fi
  if [[ "$st" == D* ]]; then echo "needs review (deleted): $p"; auto=false; fi
done < <(git diff --name-status "$base" HEAD)
if git diff -U0 "$base" HEAD | grep -E '^\+' | grep -qE 'sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY'; then
  echo "BLOCKED: something that looks like an API key"; fail=1
fi
echo "automerge=$auto" >> "${GITHUB_OUTPUT:-/dev/null}"
exit $fail
'@

# 4. PC auto-sync (runs hidden every 10 min, skips while a render runs)
WriteFile 'tools/git-sync/sync.ps1' @'
$ErrorActionPreference = 'Continue'
$Root = Split-Path (Split-Path $PSScriptRoot)
Set-Location $Root
$state = Join-Path $PSScriptRoot 'state'; New-Item -ItemType Directory -Force $state | Out-Null
$log = Join-Path $state 'sync.log'
function Log($m) { Add-Content $log ("{0}  {1}" -f (Get-Date -Format 's'), $m) }
function Toast($title, $text) {
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $t = $x.GetElementsByTagName('text'); [void]$t.Item(0).AppendChild($x.CreateTextNode($title)); [void]$t.Item(1).AppendChild($x.CreateTextNode($text))
    $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))
  } catch {}
}
# one at a time
$lock = Join-Path $state 'lock'
if ((Test-Path $lock) -and ((Get-Item $lock).LastWriteTime -gt (Get-Date).AddMinutes(-15))) { exit }
Set-Content $lock $PID
try {
  # never touch files while Quizio is rendering / making voice
  $busy = $null
  try { $busy = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match 'make\.ts|remotion' } } catch {}
  if ($busy) { Log 'render running - skipped'; exit }
  if (Test-Path (Join-Path $Root '.git\MERGE_HEAD')) { Log 'unfinished merge - skipped'; exit }

  git add -A 2>&1 | Out-Null
  git diff --cached --quiet
  if ($LASTEXITCODE -ne 0) { git commit -q -m ("PC auto-sync " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) 2>&1 | Out-Null }

  $before = (git rev-parse HEAD).Trim()
  $remoteMain = git ls-remote --heads origin main 2>$null
  if ($LASTEXITCODE -ne 0) { Log 'GitHub unreachable (offline/login?)'; exit }
  if (-not $remoteMain) { git push -q -u origin HEAD:main 2>&1 | Out-Null; Log "first push exit=$LASTEXITCODE"; exit }
  git fetch -q origin main 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Log 'fetch failed (offline?)'; exit }
  git merge -q --no-edit origin/main 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    git merge --abort 2>&1 | Out-Null
    Log 'CONFLICT - merge aborted, your files untouched'
    Toast 'Quizio sync needs help' 'Conflict with cloud changes. Your files are untouched. Ask Claude to resolve.'
    exit
  }
  $new = git diff --name-only --diff-filter=A $before HEAD -- 'data/*.json' | Where-Object { $_ -notmatch '^data/brain/' }
  git push -q origin HEAD:main 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Log 'push failed - retry next run' }
  if ($new) {
    $names = ($new | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '
    Log "new quiz: $names"; Toast 'New Quizio quiz ready' "$names - tick it in Studio and press Make"
  } else { Log 'ok' }
} finally { Remove-Item $lock -ErrorAction SilentlyContinue }
'@

WriteFile 'tools/git-sync/run-hidden.vbs' @'
Set sh = CreateObject("WScript.Shell")
p = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & p & "\sync.ps1""", 0, True
'@

WriteFile 'tools/git-sync/sync-now.cmd' "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0sync.ps1`"`r`ntype `"%~dp0state\sync.log`"`r`npause`r`n"

# 5. Repo + safety check before anything leaves the PC
git init -q -b main
git config core.longpaths true
git config core.quotepath false
git config core.safecrlf false
if (-not (git config user.name)) { git config user.name 'Quizio PC' }
if (-not (git config user.email)) { git config user.email 'quizio-pc@localhost' }
git add -A
$staged = git diff --cached --name-only
$bad = $staged | Where-Object { $_ -match '^\.claude/' -or ((Split-Path $_ -Leaf) -match '^\.env($|\.)|credential|client_secret|token[^/]*\.json$|^id_(rsa|ed25519)|\.(p12|pfx)$|key[^/]*\.pem$') }
$big = $staged | Where-Object { (Get-Item -LiteralPath $_).Length -gt 50MB }
$mb = [math]::Round((($staged | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum) / 1MB, 1)
Say "Files to upload: $($staged.Count)  ($mb MB)" 'Cyan'
Say 'Biggest folders:' 'Gray'
$staged | Group-Object { ($_ -split '/')[0..([math]::Min(1, ($_ -split '/').Count - 2))] -join '/' } | ForEach-Object {
  [pscustomobject]@{ Folder = $_.Name; MB = [math]::Round((($_.Group | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum) / 1MB, 1); Files = $_.Count }
} | Sort-Object MB -Descending | Select-Object -First 10 | ForEach-Object { Say ("  {0,8} MB  {1,6} files  {2}" -f $_.MB, $_.Files, $_.Folder) 'Gray' }
if ($bad -or $big) {
  if ($bad) { Say "Possible secrets ($(@($bad).Count)):" 'Yellow'; $bad | Select-Object -First 20 | ForEach-Object { Say "  $_" 'Yellow' } }
  if ($big) { Say "Files over 50 MB ($(@($big).Count)):" 'Yellow'; $big | Select-Object -First 20 | ForEach-Object { Say "  $_" 'Yellow' } }
  Remove-Item -Recurse -Force (Join-Path $Root '.git')
  Die 'Nothing uploaded. Tell Claude which of these files are safe, or add them to .gitignore.'
}
if ($mb -gt 500) { Remove-Item -Recurse -Force (Join-Path $Root '.git'); Die "Upload would be $mb MB (too big; see Biggest folders above). Nothing uploaded - send Claude that list." }
$staged | Out-File (Join-Path $Root 'tools\git-sync\first-upload-list.txt') -Encoding ascii
Say "Full list saved to tools\git-sync\first-upload-list.txt" 'Gray'
if ((Read-Host 'Upload to GitHub now? (y/n)') -ne 'y') { Remove-Item -Recurse -Force (Join-Path $Root '.git'); Die 'Cancelled. Nothing uploaded.' }
git add -A
git commit -q -m 'Initial Quizio import'
git remote add origin $Remote
# 6. Scheduled task: every 10 min + at logon, hidden
$vbs = Join-Path $Root 'tools\git-sync\run-hidden.vbs'
$act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
$trg = @(
  (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
  (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10))
)
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Quizio Git Sync' -Action $act -Trigger $trg -Settings $set -Description 'Syncs D:\CLAUDE_PROJECTS\QUIZIO with GitHub (skips during renders)' -Force | Out-Null

Say 'Pushing (a GitHub login window may open the first time)...' 'Cyan'
git push -u origin main
if ($LASTEXITCODE -ne 0) { Say 'Push failed (login/network). Your files are untouched. Auto-sync will retry every 10 min, or run tools\git-sync\sync-now.cmd.' 'Yellow' }

Say ''
Say 'DONE.' 'Green'
Say "Backup:        $bak"
Say 'Auto-sync:     every 10 min, hidden (Task Scheduler: "Quizio Git Sync")'
Say 'Sync now:      tools\git-sync\sync-now.cmd'
Say 'Log:           tools\git-sync\state\sync.log'
Read-Host 'Press Enter to close'
