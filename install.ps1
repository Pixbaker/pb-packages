# PB Package Manager - installation on a new PC.
# Run: irm https://raw.githubusercontent.com/Pixbaker/pb-packages/main/install.ps1 | iex
# (ASCII only on purpose: Windows PowerShell 5.1 + iex mangles non-ASCII.)
$ErrorActionPreference = 'Stop'
$repo = 'Pixbaker/pb-packages'
$packageId = 'com.pixbakers.pbpkg'
$root = if ($env:PBPKG_ROOT) { $env:PBPKG_ROOT } else { Join-Path $env:LOCALAPPDATA 'Pixbakers\pbpkg' }
$manager = Join-Path $root 'manager'

# 1. Python: the one bundled with 3ds Max (newest first), then python from PATH.
$python = $null
foreach ($year in 2030..2025) {
    $candidate = "C:\Program Files\Autodesk\3ds Max $year\Python\python.exe"
    if (Test-Path $candidate) { $python = $candidate; break }
}
if (-not $python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source }
}
if (-not $python) { throw 'PB Package Manager: no 3ds Max 2025+ (or Python) found.' }

# 2. Catalog via GitHub API (no raw URL cache).
$headers = @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = 'pbpkg-bootstrap' }
$catalog = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/contents/catalog.json?ref=main" -Headers $headers
if ($catalog -is [string]) { $catalog = $catalog | ConvertFrom-Json }
$package = $catalog.packages | Where-Object { $_.id -eq $packageId } | Select-Object -First 1
if (-not $package) { throw "PB Package Manager: $packageId is not in the catalog." }
$version = $package.versions | Sort-Object { [version]($_.version -replace '-.*$', '') } -Descending | Select-Object -First 1
$build = $version.builds | Where-Object { $_.python -eq 'any' } | Select-Object -First 1
if (-not $build) { throw "PB Package Manager: no 'any' build for $($version.version)." }

# 3. Download, verify sha256, unpack.
$temp = Join-Path ([IO.Path]::GetTempPath()) ("pbpkg-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $zip = Join-Path $temp 'manager.zip'
    Invoke-WebRequest -Uri $build.url -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
    if ($hash -ne $build.sha256.ToLower()) { throw 'PB Package Manager: checksum mismatch, download is corrupted.' }
    $staging = Join-Path $temp 'manager'
    Expand-Archive -Path $zip -DestinationPath $staging
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (Test-Path $manager) {
        Move-Item $manager ($manager + '.old-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    Move-Item $staging $manager
} finally {
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}

# 4. Register the manager as a package (versions + rollback), then hooks into every 3ds Max 2025+ profile.
$env:PYTHONPATH = $manager
& $python -m pbpkg install $packageId
if ($LASTEXITCODE -ne 0) { Write-Warning 'PB Package Manager: registering the manager package failed, using the seed copy.' }
& $python -m pbpkg install-hooks
if ($LASTEXITCODE -eq 3) {
    Write-Warning "PB Package Manager $($version.version) installed, but 3ds Max has no user profile yet. Start 3ds Max once, close it and run this installer again."
    return
}
if ($LASTEXITCODE -ne 0) { throw 'PB Package Manager: writing Max hooks failed.' }
Write-Host "PB Package Manager $($version.version) installed to $manager. Restart 3ds Max."
