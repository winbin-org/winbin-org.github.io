# Installs winbin to a directory you choose:
#
#     powershell -c "irm https://winbin-org.github.io/install.ps1 | iex"
#
# For a script, the long form takes options, which the short form has no way to:
#
#     powershell -c "& ([scriptblock]::Create((irm https://winbin-org.github.io/install.ps1))) -NonInteractive DIR"
#
# DIR is where to install, and -NonInteractive requires it. It means never asking
# anything, now or if there's ever more to ask. -Pdb installs winbin.pdb as well, for
# naming the frames in a stack trace. An update keeps a PDB that's already there.
#
# Downloads a prebuilt exe, so it needs neither zig nor git. If winbin.exe is
# already on your PATH, it's updated where it is, unless DIR says otherwise.
#
# Doesn't touch PATH: having winbin's directory on it is how you turn winbin's
# programs on and off, so that stays your decision.
#
# Errors throw instead of exit: with iex, exit would close the user's shell.

[CmdletBinding()]
param([string]$Dir, [switch]$NonInteractive, [switch]$Pdb)

$ErrorActionPreference = "Stop"

$releases = "https://github.com/winbin-org/winbin/releases/latest/download"
$suggested = "C:\winbin"

# A 32-bit powershell on a 64-bit machine reports x86 in PROCESSOR_ARCHITECTURE,
# the real one is in PROCESSOR_ARCHITEW6432.
$machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($machine) {
    "AMD64" { "x86_64" }
    "ARM64" { "aarch64" }
    "x86" { "x86" }
    default { throw "winbin: unsupported architecture '$machine'" }
}

function Get-PathDirs {
    # The order Windows searches them in, without duplicates. What's in the registry,
    # not $env:PATH: that's only this shell, and what matters is every shell after it.
    $seen = @{}
    $dirs = @()
    $joined = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User")
    foreach ($entry in $joined -split ";") {
        $dir = $entry.Trim().Trim('"')
        if ($dir.Length -gt 3) { $dir = $dir.TrimEnd("\") }
        if (-not $dir -or $seen.ContainsKey($dir.ToLower())) { continue }
        $seen[$dir.ToLower()] = $true
        $dirs += $dir
    }
    return , $dirs
}

# Why winbin can't be installed there, $null if it can.
function Get-Unusable($dir) {
    if (-not [IO.Path]::IsPathRooted($dir)) { return "not an absolute path" }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return "not found" }
    $windows = $env:WINDIR.TrimEnd("\")
    if ($dir -ieq $windows -or $dir.StartsWith("$windows\", [StringComparison]::OrdinalIgnoreCase)) { return "part of Windows" }
    $probe = Join-Path $dir ".winbin-write-test-$PID"
    try {
        [IO.File]::WriteAllBytes($probe, [byte[]]@())
        [IO.File]::Delete($probe)
    } catch {
        return "can't write to it"
    }
    return $null
}

function Read-InstallDir($pathDirs) {
    $choices = @()
    foreach ($dir in $pathDirs) {
        $reason = Get-Unusable $dir
        if ($reason) {
            Write-Host "winbin: ignoring '$dir' ($reason)"
            continue
        }
        $empty = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0
        $note = if ($empty) { "" } else { "  (not empty)" }
        $choices += , @($dir, "$dir$note")
    }

    # Only what's true of it right now, and only if it isn't one of those already.
    $listed = @($choices | Where-Object { $_[0] -ieq $suggested }).Count -ne 0
    if (-not $listed) {
        $exists = Test-Path -LiteralPath $suggested -PathType Container
        $onPath = @($pathDirs | Where-Object { $_ -ieq $suggested }).Count -ne 0
        $usable = (-not $exists) -or (-not (Get-Unusable $suggested))
        if ($usable) {
            $notes = @()
            if (-not $exists) { $notes += "new" }
            if (-not $onPath) { $notes += "you'll need to add it to your PATH" }
            $choices += , @($suggested, "$suggested  ($($notes -join ', '))")
        }
    }
    if ($choices.Count -eq 0) { throw "winbin: there's nowhere to install. Add a directory you can write to to your PATH, or give one as an argument" }

    Write-Host ""
    Write-Host "Where should winbin install? Packages go in the same directory."
    for ($i = 0; $i -lt $choices.Count; $i++) {
        Write-Host "  $($i + 1): $($choices[$i][1])"
    }
    Write-Host "  0: cancel"
    while ($true) {
        Write-Host -NoNewline "Choose a number: "
        $answer = [Console]::In.ReadLine()
        if ($null -eq $answer) { throw "winbin: there's no one to answer. Run it in a terminal, or give it -NonInteractive DIR" }
        $number = 0
        if ([int]::TryParse($answer.Trim(), [ref]$number) -and $number -ge 0 -and $number -le $choices.Count) {
            if ($number -eq 0) { return $null }
            return $choices[$number - 1][0]
        }
        Write-Host "That isn't one of the choices."
    }
}

if ($Pdb -and $arch -eq "x86") { throw "winbin: there's no PDB for x86" }
if ($NonInteractive -and -not $Dir) { throw "winbin: -NonInteractive needs a directory to install to: -NonInteractive DIR" }

$pathDirs = Get-PathDirs
$root = $null
if ($Dir) {
    $root = $Dir
} else {
    foreach ($dir in $pathDirs) {
        if (Test-Path -LiteralPath (Join-Path $dir "winbin.exe") -PathType Leaf) {
            Write-Host "winbin: updating the one on your PATH, in $dir"
            $root = $dir
            break
        }
    }
    if (-not $root) { $root = Read-InstallDir $pathDirs }
    if (-not $root) {
        Write-Host "winbin: cancelled, nothing was changed"
        return
    }
}

# Windows PowerShell 5.1 can default to TLS 1.0, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Its progress bar slows downloads by an order of magnitude.
$ProgressPreference = "SilentlyContinue"

# Downloaded before anything in the root changes, so a failed download leaves no
# trace. Then a rename within the root, so a file there is never partial, with
# winbin.exe last so that it never goes with an older PDB. A PDB that's already
# there is replaced too, it wouldn't match the new exe.
$names = @("winbin.exe")
if ($Pdb -or (Test-Path -LiteralPath (Join-Path $root "winbin.pdb") -PathType Leaf)) { $names = @("winbin.pdb") + $names }
$url = "$releases/winbin-$arch.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) "winbin-install-$PID"
Write-Host "winbin: downloading $url"
try {
    New-Item -ItemType Directory -Force $work | Out-Null
    $zip = Join-Path $work "winbin.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    $extracted = Join-Path $work "extracted"
    Expand-Archive -LiteralPath $zip -DestinationPath $extracted
    foreach ($name in $names) {
        if (-not (Test-Path -LiteralPath (Join-Path $extracted $name) -PathType Leaf)) { throw "winbin: $url has no $name in it" }
    }

    New-Item -ItemType Directory -Force $root | Out-Null
    foreach ($name in $names) {
        $staged = Join-Path $root "$name.new"
        Move-Item -Force -LiteralPath (Join-Path $extracted $name) -Destination $staged
        Move-Item -Force -LiteralPath $staged -Destination (Join-Path $root $name)
    }
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
}
Write-Host "winbin: installed $root\winbin.exe"

if (@($pathDirs | Where-Object { $_ -ieq $root.TrimEnd("\") }).Count -eq 0) {
    Write-Host ""
    Write-Host "$root isn't on your PATH. To add it for your user, run this and restart your shell:"
    Write-Host ""
    Write-Host "    [Environment]::SetEnvironmentVariable('PATH', [Environment]::GetEnvironmentVariable('PATH', 'User') + ';$root', 'User')"
}
