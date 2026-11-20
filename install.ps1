# Tiphys agent installer for Windows x64 (PLAN K2). Runs as your normal user; no administrator rights needed.
#
#   irm https://raw.githubusercontent.com/aurict/tiphys/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/aurict/tiphys/main/install.ps1))) -Version 0.4.0
#
# Downloads the release bundle (agent + its own Node.js), verifies the ed25519 signature of SHA256SUMS with the key
# embedded below (needs openssl.exe: Git for Windows ships one) and the bundle's SHA-256, installs it to
# %LOCALAPPDATA%\Tiphys\agent\versions\<version> with a `current` junction, starts it at logon (HKCU Run key, a small
# PowerShell loop restarts it if it exits), turns on the safe features (`init --detect`), runs `tailscale serve` and
# prints the pairing QR code. Re-running updates. -Uninstall removes it (keeps settings unless -Purge).
# -InsecureSkipSignature installs without checking the signature (the SHA-256 is still checked, which only proves
# the download is intact, not who published it).
param(
  [string]$Version,
  [string]$Name,
  [switch]$NoService,
  [switch]$NoServe,
  [switch]$NoPair,
  [switch]$Uninstall,
  [switch]$Purge,
  [switch]$InsecureSkipSignature
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Releases = if ($env:TIPHYS_RELEASE_URL) { $env:TIPHYS_RELEASE_URL.TrimEnd('/') } else { 'https://github.com/aurict/tiphys/releases' }
$Root = if ($env:TIPHYS_PREFIX) { $env:TIPHYS_PREFIX } else { Join-Path $env:LOCALAPPDATA 'Tiphys\agent' }
$ConfigDir = Join-Path $env:USERPROFILE '.config\tiphys'
$Port = 7443
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# The release signing key (written by tools/release-keygen.sh). A placeholder means: no signed releases yet.
# BEGIN TIPHYS UPDATE KEY
$PubKey = 'TIPHYS-PLACEHOLDER-PUBLIC-KEY'
# END TIPHYS UPDATE KEY

function Step($m) { Write-Host "`n==> $m" }
# throw, not exit: with `irm | iex` an exit would close the user's PowerShell window.
function Fail($m) { throw "Tiphys install: $m" }

function Stop-Agent {
  # The loop script and the node process it started (matched by the install path on their command line).
  $procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Root) -and ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'node.exe') }
  foreach ($p in ($procs | Sort-Object { $_.Name -eq 'node.exe' })) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Remove-Junction($path) {
  if (Test-Path $path) { cmd /c rmdir "$path" | Out-Null }
}

if ($Uninstall) {
  Step 'Removing the Tiphys agent'
  Stop-Agent
  Remove-ItemProperty -Path $RunKey -Name 'TiphysAgent' -ErrorAction SilentlyContinue
  Remove-Junction (Join-Path $Root 'current')
  if (Test-Path $Root) { Remove-Item -Recurse -Force $Root }
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath) { [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';') | Where-Object { $_ -and $_ -ne $Root }) -join ';', 'User') }
  if ($Purge) { if (Test-Path $ConfigDir) { Remove-Item -Recurse -Force $ConfigDir }; Write-Host "Deleted $ConfigDir." }
  else { Write-Host "Kept your settings in $ConfigDir (delete with -Uninstall -Purge)." }
  Write-Host "If you published the agent with tailscale serve, remove it with: tailscale serve --https=$Port off"
  return
}

if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { Fail 'only Windows x64 is supported' }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("tiphys-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  function Get-File($url, $out) { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out }

  if (-not $Version) {
    try { Get-File "$Releases/latest/download/VERSION" (Join-Path $Tmp 'VERSION') } catch { Fail "could not reach $Releases (no internet, or no release yet)" }
    $Version = (Get-Content (Join-Path $Tmp 'VERSION') -Raw).Trim()
  }
  $Version = $Version.TrimStart('v')
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "bad version: $Version" }

  $File = "tiphys-agent-$Version-win-x64.zip"
  $Base = "$Releases/download/v$Version"
  Step "Downloading Tiphys agent $Version (win-x64)"
  $Sums = Join-Path $Tmp 'SHA256SUMS'; $Sig = Join-Path $Tmp 'SHA256SUMS.sig'; $Zip = Join-Path $Tmp $File
  try { Get-File "$Base/SHA256SUMS" $Sums } catch { Fail "release v$Version not found at $Base" }
  try { Get-File "$Base/SHA256SUMS.sig" $Sig } catch { Fail 'SHA256SUMS.sig missing (unsigned release)' }
  try { Get-File "$Base/$File" $Zip } catch { Fail "no bundle $File in release v$Version" }

  Step 'Verifying'
  if ($PubKey -like '*BEGIN PUBLIC KEY*') {
    $openssl = (Get-Command openssl.exe -ErrorAction SilentlyContinue).Source
    if (-not $openssl) {
      foreach ($c in @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe", "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe")) {
        if (Test-Path $c) { $openssl = $c; break }
      }
    }
    if ($openssl) {
      $pem = Join-Path $Tmp 'pub.pem'
      [IO.File]::WriteAllText($pem, ($PubKey -replace "`r", '') + "`n")
      & $openssl pkeyutl -verify -pubin -inkey $pem -rawin -in $Sums -sigfile $Sig *> $null
      if ($LASTEXITCODE -ne 0) { Fail 'SIGNATURE CHECK FAILED: SHA256SUMS was not signed by the Tiphys release key. Nothing was installed.' }
      Write-Host 'signature: ok (ed25519, release key)'
    } elseif ($InsecureSkipSignature) {
      Write-Host 'signature: NOT CHECKED (no openssl.exe; -InsecureSkipSignature given)' -ForegroundColor Yellow
    } else {
      Fail "can't check the release signature: openssl.exe is needed (install Git for Windows, which includes it). To install anyway: -InsecureSkipSignature"
    }
  } elseif ($InsecureSkipSignature) {
    Write-Host 'signature: NOT CHECKED (installer without a release key; -InsecureSkipSignature given)' -ForegroundColor Yellow
  } else {
    Fail "this installer has no release signing key yet, so the download can't be verified. Use -InsecureSkipSignature only if you trust where it came from."
  }
  $want = $null
  foreach ($line in Get-Content $Sums) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $File) { $want = $parts[0].ToLower() }
  }
  if (-not $want) { Fail "$File is not listed in SHA256SUMS" }
  if ((Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLower() -ne $want) { Fail "SHA-256 mismatch for $File (damaged or tampered download). Nothing was installed." }
  Write-Host 'sha256: ok'

  Step "Installing to $Root\versions\$Version"
  $Versions = Join-Path $Root 'versions'
  New-Item -ItemType Directory -Force -Path $Versions | Out-Null
  $New = Join-Path $Versions ".new-$Version"
  if (Test-Path $New) { Remove-Item -Recurse -Force $New }
  Expand-Archive -Path $Zip -DestinationPath $New
  $Top = Join-Path $New "tiphys-agent-$Version-win-x64"
  if (-not (Test-Path (Join-Path $Top 'dist\cli.js')) -or -not (Test-Path (Join-Path $Top 'node\node.exe'))) { Fail 'bundle content is not what was expected' }
  Stop-Agent
  $Current = Join-Path $Root 'current'
  $Old = $null
  if (Test-Path $Current) { $Old = Split-Path -Leaf (@((Get-Item $Current).Target)[0]) }
  $Dest = Join-Path $Versions $Version
  if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
  Move-Item $Top $Dest
  Remove-Item -Recurse -Force $New
  Remove-Junction $Current
  New-Item -ItemType Junction -Path $Current -Target $Dest | Out-Null
  Remove-Item -Force (Join-Path $Root 'update-pending') -ErrorAction SilentlyContinue
  Get-ChildItem $Versions -Directory | Where-Object { $_.Name -ne $Version -and $_.Name -ne $Old } | Remove-Item -Recurse -Force

  # Command wrapper on the user PATH.
  Set-Content -Path (Join-Path $Root 'tiphys-agent.cmd') -Encoding ASCII -Value "@`"%~dp0current\node\node.exe`" `"%~dp0current\dist\cli.js`" %*"
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not (($userPath -split ';') -contains $Root)) {
    [Environment]::SetEnvironmentVariable('Path', ((@($userPath, $Root) | Where-Object { $_ }) -join ';'), 'User')
    Write-Host "Added $Root to your PATH (new terminals)."
  }
  $Node = Join-Path $Current 'node\node.exe'
  $Cli = Join-Path $Current 'dist\cli.js'
  function Agent { & $Node $Cli @args }

  # Runner: update guard (K8; rolls back after 3 failed starts of a self-updated version) and a restart loop.
  $runner = @'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
while ($true) {
  $m = Join-Path $root 'update-pending'
  if (Test-Path $m) {
    $kv = @{}
    foreach ($l in Get-Content $m) { $p = $l -split '=', 2; if ($p.Count -eq 2) { $kv[$p[0]] = $p[1] } }
    $n = 0; [int]::TryParse([string]$kv['attempts'], [ref]$n) | Out-Null; $n++
    $from = [string]$kv['from']
    if ($n -gt 3 -and $from -match '^\d+\.\d+\.\d+$' -and (Test-Path (Join-Path $root "versions\$from"))) {
      cmd /c rmdir "$(Join-Path $root 'current')" | Out-Null
      New-Item -ItemType Junction -Path (Join-Path $root 'current') -Target (Join-Path $root "versions\$from") | Out-Null
      Remove-Item -Force $m
    } else {
      Set-Content -Path $m -Encoding ASCII -Value "from=$from`nto=$($kv['to'])`nattempts=$n"
    }
  }
  $env:NODE_ENV = 'production'
  & (Join-Path $root 'current\node\node.exe') --max-semi-space-size=1 (Join-Path $root 'current\dist\cli.js') serve *>> (Join-Path $root 'agent.log')
  Start-Sleep -Seconds 5
}
'@
  Set-Content -Path (Join-Path $Root 'run-agent.ps1') -Encoding UTF8 -Value $runner

  if (-not (Test-Path (Join-Path $ConfigDir 'agent.json'))) {
    Step 'Creating settings (detecting what this machine has)'
    if ($Name) { Agent init --detect --name $Name } else { Agent init --detect }
  } else {
    Write-Host "Settings exist ($ConfigDir\agent.json); features unchanged. Change them with: tiphys-agent init --features ..."
  }

  if ($NoService) {
    Write-Host 'Skipping autostart (-NoService). Start the agent with: tiphys-agent serve'
  } else {
    Step 'Starting the agent (and at every logon)'
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\run-agent.ps1`""
    Set-ItemProperty -Path $RunKey -Name 'TiphysAgent' -Value $cmd
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Root\run-agent.ps1`""
    $ok = $false
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
      Start-Sleep -Seconds 1
      try { Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/v1/health" -TimeoutSec 2 | Out-Null; $ok = $true } catch {}
    }
    if ($ok) { Write-Host "Agent is running on 127.0.0.1:$Port." } else { Write-Host "The agent did not answer yet. Check: tiphys-agent doctor (log: $Root\agent.log)" }
  }

  $ts = (Get-Command tailscale.exe -ErrorAction SilentlyContinue).Source
  if (-not $ts -and (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) { $ts = "$env:ProgramFiles\Tailscale\tailscale.exe" }
  if ($NoServe) {
  } elseif (-not $ts) {
    Step 'Tailscale'
    Write-Host 'Tailscale is not installed. The phone reaches this agent only through your tailnet:'
    Write-Host '  1. install it and log in: https://tailscale.com/download/windows'
    Write-Host "  2. publish: tailscale serve --bg --https=$Port http://127.0.0.1:$Port"
    Write-Host '  3. pair:    tiphys-agent pair'
    $NoPair = $true
  } else {
    $status = (& $ts serve status --json 2>$null) -join "`n"
    if ($status -match "127\.0\.0\.1:$Port`"") { Write-Host 'tailscale serve already publishes the agent.' }
    else {
      Step 'Publishing the agent in your tailnet (tailscale serve)'
      & $ts serve --bg "--https=$Port" "http://127.0.0.1:$Port" *> $null
      if ($LASTEXITCODE -eq 0) { Write-Host "ok: https://<this machine>:$Port inside your tailnet" }
      else { Write-Host "Could not run it. Run it yourself: tailscale serve --bg --https=$Port http://127.0.0.1:$Port" }
    }
  }

  if (-not $NoPair -and -not (Agent devices)) {
    Step 'Pair your phone'
    Agent pair --name Phone
    if ($LASTEXITCODE -ne 0) { Write-Host 'Pair later with: tiphys-agent pair' }
  }

  Step "Done: Tiphys agent $Version"
  Write-Host 'Check the install any time: tiphys-agent doctor'
  Write-Host 'Update: run this installer again.  Remove: add -Uninstall'
} finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
