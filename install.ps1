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
# Downloads the latest winbin, which installs winbin as a package like any other, so
# it needs neither zig nor git. If winbin.exe is already on your PATH, it's updated
# where it is, unless DIR says otherwise.
#
# Doesn't touch PATH: having winbin's directory on it is how you turn winbin's
# programs on and off, so that stays your decision.
#
# Errors throw instead of exit: with iex, exit would close the user's shell.

[CmdletBinding()]
param([string]$Dir, [switch]$NonInteractive, [switch]$Pdb)

# In a scope of its own: with iex this runs in the caller's shell, where what's set and
# defined here would otherwise stay.
& {
    $ErrorActionPreference = "Stop"

    $releases = "https://github.com/winbin-org/winbin/releases/latest/download"
    $suggested = "C:\winbin"

    # IsWow64Process2 gives the machine's own architecture even to an emulated PowerShell.
    # The environment doesn't: an x64 PowerShell on an ARM64 machine says AMD64.
    $kernel32 = Add-Type -Name Kernel32 -Namespace WinbinInstall -PassThru -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
[DllImport("kernel32.dll")]
public static extern IntPtr GetCurrentProcess();
'@
    [uint16]$processMachine = 0
    [uint16]$nativeMachine = 0
    if (-not $kernel32::IsWow64Process2($kernel32::GetCurrentProcess(), [ref]$processMachine, [ref]$nativeMachine)) {
        throw "winbin: IsWow64Process2 failed, error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $arch = switch ($nativeMachine) {
        0x8664 { "x86_64" }
        0xAA64 { "aarch64" }
        0x014C { "x86" }
        default { throw ("winbin: unsupported machine 0x{0:x}" -f $nativeMachine) }
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

    # PATH can have anything in it, like a drive that's gone or characters a path can't
    # have, which Join-Path and Test-Path throw on.
    function Test-FileIn($dir, $name) {
        try { return [IO.File]::Exists([IO.Path]::Combine($dir, $name)) } catch { return $false }
    }

    # Not "." or anything else that depends on where this is run from.
    function Test-Absolute($dir) {
        return $dir -match '^([A-Za-z]:[\\/]|[\\/]{2})'
    }

    # Why winbin can't be installed there, $null if it can.
    function Get-Unusable($dir) {
        if (-not (Test-Absolute $dir)) { return "not an absolute path" }
        if (-not [IO.Directory]::Exists($dir)) { return "not found" }
        $windows = $env:WINDIR.TrimEnd("\")
        if ($dir -ieq $windows -or $dir.StartsWith("$windows\", [StringComparison]::OrdinalIgnoreCase)) { return "part of Windows" }
        $probe = "$dir\.winbin-write-test-$PID"
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
            if ((Test-Absolute $dir) -and (Test-FileIn $dir "winbin.exe")) {
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

    # The downloaded winbin isn't the one that's installed: it installs winbin, as a package.
    $installArgs = @("winbin")
    if ($Pdb -or (Test-FileIn $root "winbin.pdb")) { $installArgs = @("--pdbs") + $installArgs }
    if ($NonInteractive) { $installArgs = @("--non-interactive") + $installArgs }
    $url = "$releases/winbin-$arch.zip"
    $work = Join-Path ([IO.Path]::GetTempPath()) "winbin-install-$PID"
    # --dir can't be given along with it.
    $winbinDir = $env:WINBIN_DIR
    Write-Host "winbin: downloading $url"
    try {
        $env:WINBIN_DIR = $null
        New-Item -ItemType Directory -Force $work | Out-Null
        $zip = Join-Path $work "winbin.zip"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        $extracted = Join-Path $work "extracted"
        Expand-Archive -LiteralPath $zip -DestinationPath $extracted
        $downloaded = Join-Path $extracted "winbin.exe"
        if (-not (Test-Path -LiteralPath $downloaded -PathType Leaf)) { throw "winbin: $url has no winbin.exe in it" }

        New-Item -ItemType Directory -Force $root | Out-Null
        $root = (Resolve-Path -LiteralPath $root).ProviderPath
        # A backslash before the closing quote of an argument escapes it.
        if ($root.Length -gt 3) { $root = $root.TrimEnd("\") }
        # With "Stop", what winbin writes to stderr ends the script if that's being redirected.
        $ErrorActionPreference = "Continue"
        & $downloaded --dir $root install @installArgs
        $installed = $LASTEXITCODE
        if ($installed -eq 0) { & $downloaded --dir $root update --non-interactive winbin }
        $ErrorActionPreference = "Stop"
        if ($installed -ne 0) { throw "winbin: installing winbin in $root failed, exit code $installed" }
        if ($LASTEXITCODE -ne 0) { throw "winbin: updating winbin in $root failed, exit code $LASTEXITCODE" }
    } finally {
        $env:WINBIN_DIR = $winbinDir
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
    }
    Write-Host "winbin: installed $root\winbin.exe"

    if (@($pathDirs | Where-Object { $_ -ieq $root }).Count -eq 0) {
        Write-Host ""
        Write-Host "$root isn't on your PATH. To add it for your user, run this and restart your shell:"
        Write-Host ""
        # Not [Environment]::GetEnvironmentVariable, which gives PATH with its %VARIABLES%
        # filled in, so writing that back would lose them. The last part is what tells
        # everything running that the environment changed.
        $quoted = $root.Replace("'", "''")
        Write-Host "    `$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', `$true); `$k.SetValue('PATH', (`$k.GetValue('PATH', '', 'DoNotExpandEnvironmentNames').TrimEnd(';') + ';$quoted').TrimStart(';'), 'ExpandString'); [Environment]::SetEnvironmentVariable('winbin-path-changed', `$null, 'User')"
    }
}
