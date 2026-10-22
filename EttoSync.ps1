<#
  Etto's Playhouse - L4D2 Workshop sync
  Keeps a player's Left 4 Dead 2 Workshop subscriptions compatible with the server.

  Modes
    (default)  Standard: subscribe required items, unsubscribe retired / known-bad items, put the load-first
               item at the top of addonlist.txt, enable required items. Nothing else is touched.
    -Parity    Also subscribe Etto's full client setup (the manifest's optional "parity" list) and copy its
               load order, so your game looks and sounds like Etto's. Combine with -Strict for an exact mirror.
    -Strict    Make subscriptions match the manifest exactly (required + recommended, + parity with -Parity).
               Snapshot first.
    -Restore   Undo a previous run from its snapshot (latest by default, or -Backup <folder>).
    -DryRun    Show what would change, change nothing.
    -Yes       Do not ask for confirmation.
    -LocalPack With -Parity: install Etto's local (non-Workshop) add-ons from the zip Etto hands out personally.
               Default: EttosPlayhouse_LocalPack.zip next to this script. Each file must match the SHA-256 the
               manifest lists; anything else in the zip is ignored.

  It uses the steam_api.dll that ships with your own Left 4 Dead 2 install to talk to your running Steam
  client - the same calls the Workshop "Subscribe" button makes. The manifest is data only (Workshop IDs and
  labels); nothing downloaded from it is ever executed.
#>
param(
    [switch]$Strict,
    [switch]$Parity,
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$Yes,
    [string]$Backup,
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/Renevark/ettos-playhouse-l4d2/main/manifest.json',
    [string]$ManifestFile,
    [string]$LocalPack
)

$ScriptVersion = 4
$ErrorActionPreference = 'Stop'

# resolve file arguments against the current PowerShell location now: the 32-bit relaunch below and the Steam
# session (which changes directory) would otherwise resolve them somewhere else
foreach ($k in 'ManifestFile', 'LocalPack') {
    $v = Get-Variable $k -ValueOnly
    if ($v) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($v)
        Set-Variable $k $full
        if ($PSBoundParameters.ContainsKey($k)) { $PSBoundParameters[$k] = $full }
    }
}

# ---- steam_api.dll in L4D2 is 32-bit: make sure we run in 32-bit PowerShell ----------------------------
if ([IntPtr]::Size -ne 4) {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $fwd += "-$k" } } else { $fwd += "-$k"; $fwd += "$v" }
    }
    & $ps32 @fwd
    exit $LASTEXITCODE
}

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; exit 1 }

# ---- locate Steam and Left 4 Dead 2 --------------------------------------------------------------------
$steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if (-not $steamPath) { Fail 'Steam is not installed for this Windows user.' }
$steamPath = $steamPath -replace '/', '\'
if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { Fail 'Start Steam and log in first.' }
if (Get-Process left4dead2 -ErrorAction SilentlyContinue) { Fail 'Close Left 4 Dead 2 first, then run this again.' }

$libs = @($steamPath)
$lf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
if (Test-Path $lf) {
    foreach ($m in [regex]::Matches((Get-Content $lf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
}
$game = $null
foreach ($l in ($libs | Select-Object -Unique)) {
    if (Test-Path (Join-Path $l 'steamapps\appmanifest_550.acf')) {
        $cand = Join-Path $l 'steamapps\common\Left 4 Dead 2'
        if (Test-Path (Join-Path $cand 'bin\steam_api.dll')) { $game = $cand; break }
    }
}
if (-not $game) { Fail 'Could not find a Left 4 Dead 2 install in your Steam libraries.' }
$addonsDir = Join-Path $game 'left4dead2\addons\workshop'
$addonList = Join-Path $game 'left4dead2\addonlist.txt'
$localDir = Join-Path $game 'left4dead2\addons'
$work = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'EttosPlayhouse'
$backupRoot = Join-Path $work 'backups'
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

# ---- native helpers: Steamworks flat API + VPK directory reader ----------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class EttoSteam {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetDllDirectory(string p);
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_Init();
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void SteamAPI_Shutdown();
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void SteamAPI_RunCallbacks();
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr SteamAPI_SteamUGC_v016();
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern ulong SteamAPI_ISteamUGC_SubscribeItem(IntPtr ugc, ulong id);
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern ulong SteamAPI_ISteamUGC_UnsubscribeItem(IntPtr ugc, ulong id);
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern uint SteamAPI_ISteamUGC_GetNumSubscribedItems(IntPtr ugc);
    [DllImport("steam_api.dll", CallingConvention = CallingConvention.Cdecl)] public static extern uint SteamAPI_ISteamUGC_GetSubscribedItems(IntPtr ugc, [Out] ulong[] ids, uint max);
    public static IntPtr Ugc;
    public static ulong[] Subscribed() {
        uint n = SteamAPI_ISteamUGC_GetNumSubscribedItems(Ugc);
        ulong[] a = new ulong[Math.Max(n, 1)];
        uint got = SteamAPI_ISteamUGC_GetSubscribedItems(Ugc, a, n);
        ulong[] r = new ulong[got]; Array.Copy(a, r, got); return r;
    }
    static string CStr(BinaryReader br) {
        var ms = new MemoryStream(); byte b;
        while ((b = br.ReadByte()) != 0) ms.WriteByte(b);
        return Encoding.UTF8.GetString(ms.ToArray());
    }
    // addontitle from the VPK's addoninfo.txt (single-file VPKs only), or "" if absent.
    public static string VpkTitle(string path) {
        try {
            using (var br = new BinaryReader(File.OpenRead(path))) {
                if (br.ReadUInt32() != 0x55AA1234) return "";
                uint ver = br.ReadUInt32(); uint tree = br.ReadUInt32();
                long hdr = 12; if (ver == 2) { br.ReadBytes(16); hdr = 28; }
                while (true) {
                    string ext = CStr(br); if (ext.Length == 0) break;
                    while (true) {
                        string dir = CStr(br); if (dir.Length == 0) break;
                        while (true) {
                            string name = CStr(br); if (name.Length == 0) break;
                            br.ReadBytes(4); ushort pre = br.ReadUInt16(); ushort arc = br.ReadUInt16();
                            uint off = br.ReadUInt32(); uint len = br.ReadUInt32(); br.ReadUInt16();
                            byte[] pd = br.ReadBytes(pre);
                            if (name.ToLower() == "addoninfo" && ext == "txt" && dir.Trim().Length == 0 && arc == 0x7fff) {
                                br.BaseStream.Seek(hdr + tree + off, SeekOrigin.Begin);
                                byte[] body = br.ReadBytes((int)len);
                                string s = Encoding.UTF8.GetString(pd) + Encoding.UTF8.GetString(body);
                                var m = System.Text.RegularExpressions.Regex.Match(s, "addontitle\"?\\s+\"([^\"]*)\"", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                                return m.Success ? m.Groups[1].Value : "";
                            }
                        }
                    }
                }
            }
        } catch { }
        return "";
    }
    // File paths inside a VPK (directory tree only; no data is read).
    public static string[] VpkFiles(string path) {
        var list = new List<string>();
        using (var br = new BinaryReader(File.OpenRead(path))) {
            if (br.ReadUInt32() != 0x55AA1234) return list.ToArray();
            uint ver = br.ReadUInt32(); br.ReadUInt32();
            if (ver == 2) br.ReadBytes(16);
            while (true) {
                string ext = CStr(br); if (ext.Length == 0) break;
                while (true) {
                    string dir = CStr(br); if (dir.Length == 0) break;
                    while (true) {
                        string name = CStr(br); if (name.Length == 0) break;
                        br.ReadBytes(4); ushort pre = br.ReadUInt16(); br.ReadBytes(12); br.ReadBytes(pre);
                        string d = dir.Trim();
                        list.Add(((d.Length > 0 && d != " ") ? d + "/" : "") + name + "." + ext);
                    }
                }
            }
        }
        return list.ToArray();
    }
}
'@

# ---- manifest (data only, strictly validated) ----------------------------------------------------------
function Get-Manifest {
    if ($ManifestFile) { $raw = Get-Content $ManifestFile -Raw }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try { $raw = (Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -Headers @{ 'Cache-Control' = 'no-cache' }).Content }
        catch { Fail "Could not download the manifest from $ManifestUrl ($($_.Exception.Message))" }
    }
    try { $m = $raw | ConvertFrom-Json } catch { Fail 'The manifest is not valid JSON.' }
    if ($m.schema -ne 1) { Fail "Unsupported manifest schema '$($m.schema)'. Download the latest sync script." }
    foreach ($sec in 'required', 'recommended', 'parity', 'retired', 'knownBad') {
        foreach ($it in @($m.$sec)) {
            if ($null -eq $it) { continue }
            if ("$($it.id)" -notmatch '^\d{6,12}$') { Fail "Manifest '$sec' has an invalid Workshop id '$($it.id)'." }
        }
    }
    if ($m.loadFirst -and "$($m.loadFirst)" -notmatch '^\d{6,12}$') { Fail 'Manifest loadFirst is not a Workshop id.' }
    foreach ($o in @($m.loadFirstAll)) { if ($o -and "$o" -notmatch '^\d{6,12}$') { Fail "Manifest loadFirstAll has an invalid Workshop id '$o'." } }
    foreach ($o in @($m.loadOrder)) { if ($o -and "$o" -notmatch '^\d{6,12}$') { Fail "Manifest loadOrder has an invalid Workshop id '$o'." } }
    foreach ($f in @($m.localPack.files)) {
        if ($null -eq $f) { continue }
        if ("$($f.name)" -notmatch '^[A-Za-z0-9_\-]+\.vpk\z') { Fail "Manifest localPack has an invalid file name '$($f.name)'." }
        if ("$($f.sha256)" -notmatch '^[0-9a-f]{64}\z') { Fail "Manifest localPack has an invalid SHA-256 for '$($f.name)'." }
        if ($null -ne $f.bytes -and "$($f.bytes)" -notmatch '^\d+\z') { Fail "Manifest localPack has an invalid size for '$($f.name)'." }
    }
    return $m
}
function Ids($section) { @($section | Where-Object { $_ } | ForEach-Object { [uint64]"$($_.id)" }) }
function Label($m, [uint64]$id) {
    foreach ($sec in 'required', 'recommended', 'parity', 'retired', 'knownBad') {
        foreach ($it in @($m.$sec)) { if ($it -and [uint64]"$($it.id)" -eq $id) { return $it.label } }
    }
    $f = Join-Path $addonsDir "$id.vpk"
    if (Test-Path $f) { $t = [EttoSteam]::VpkTitle($f); if ($t) { return $t } }
    return ''
}

# ---- addonlist.txt editing -----------------------------------------------------------------------------
# L4D2 rewrites addonlist.txt at every launch and ORDERS it by Steam subscription time (newest subscription on
# top = highest priority). It keeps our on/off flags but not our ordering, so this only enables/drops entries;
# priority is set by subscription order (see Set-SubscriptionOrder).
function Get-GameOrder {
    if (-not (Test-Path $addonList)) { return @() }
    $t = [IO.File]::ReadAllText($addonList)
    @([regex]::Matches($t, '"workshop[\\/](\d+)\.vpk"\s*"1"') | ForEach-Object { [uint64]$_.Groups[1].Value })
}
function Update-AddonList([uint64[]]$tops, [uint64[]]$enable, [uint64[]]$drop) {
    if (-not (Test-Path $addonList)) { Say '  addonlist.txt not found yet - L4D2 creates it on first launch; run this again afterwards.' 'Yellow'; return }
    $text = [IO.File]::ReadAllText($addonList)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($text, '"([^"]+\.vpk)"\s*"([01])"')) { $entries.Add(@{ name = $m.Groups[1].Value; on = $m.Groups[2].Value }) }
    $wid = { param($n) if ($n -match '^workshop[\\/](\d+)\.vpk$') { [uint64]$Matches[1] } else { [uint64]0 } }
    $entries = [System.Collections.Generic.List[object]]@($entries | Where-Object { $drop -notcontains (& $wid $_.name) })
    foreach ($id in $enable) {
        $e = $entries | Where-Object { (& $wid $_.name) -eq $id } | Select-Object -First 1
        if ($e) { $e.on = '1' } else { $entries.Insert(0, @{ name = "workshop\$id.vpk"; on = '1' }) }
    }
    for ($k = $tops.Count - 1; $k -ge 0; $k--) {               # tops[0] ends up first
        $first = $tops[$k]
        $e = $entries | Where-Object { (& $wid $_.name) -eq $first } | Select-Object -First 1
        if (-not $e) { $e = @{ name = "workshop\$first.vpk"; on = '1' } } else { [void]$entries.Remove($e) }
        $e.on = '1'
        $entries.Insert(0, $e)
    }
    $out = '"AddonList"' + $nl + '{' + $nl
    foreach ($e in $entries) { $out += "`t`"$($e.name)`"`t`t`"$($e.on)`"" + $nl }
    $out += '}' + $nl
    [IO.File]::WriteAllText($addonList, $out, (New-Object Text.UTF8Encoding($false)))
}

# ---- local pack: Etto's non-Workshop add-ons, handed out personally as a zip -------------------------------
# The manifest only lists their names, sizes and SHA-256s; the files themselves never come from the internet.
function Sha256File($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }
function Sha256Entry($entry) {
    $s = $entry.Open()
    try { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($s)) -replace '-', '').ToLower() } finally { $s.Dispose() }
}
function LocalEntryOn($name) {              # is there an enabled addonlist.txt entry for this local add-on?
    if (-not (Test-Path $addonList)) { return $true }     # no list yet: L4D2 adds new local add-ons enabled at first launch
    $t = [IO.File]::ReadAllText($addonList)
    return [regex]::IsMatch($t, '"' + [regex]::Escape($name) + '"\s*"1"', 'IgnoreCase')
}
function Get-LocalPackPlan($m) {
    $files = @($m.localPack.files | Where-Object { $_ })
    if (-not $files.Count) { return $null }
    $zipName = if ("$($m.localPack.zip)" -match '^[A-Za-z0-9_\-]+\.zip\z') { "$($m.localPack.zip)" } else { 'EttosPlayhouse_LocalPack.zip' }
    $zip = if ($LocalPack) { $LocalPack } else { Join-Path $PSScriptRoot $zipName }
    $plan = [pscustomobject]@{ zip = $zip; zipName = $zipName; given = [bool]$LocalPack; haveZip = (Test-Path -LiteralPath $zip); unreadable = $false
                               install = @(); current = @(); missing = @(); stale = @(); enable = @() }
    $entries = @{}
    $installed = @{}
    foreach ($f in $files) { $dst = Join-Path $localDir $f.name; $installed[$f.name] = (Test-Path -LiteralPath $dst) -and (Sha256File $dst) -eq $f.sha256 }
    if ($plan.haveZip) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                foreach ($e in $z.Entries) { if ($e.FullName -notmatch '[\\/]') { $entries[$e.Name.ToLower()] = $e } }
                foreach ($f in $files) {
                    if ($installed[$f.name]) { $plan.current += $f; continue }
                    $e = $entries[$f.name.ToLower()]
                    if (-not $e) { $plan.missing += $f; continue }
                    if (($f.bytes -and [int64]$e.Length -ne [int64]$f.bytes) -or (Sha256Entry $e) -ne $f.sha256) { $plan.stale += $f; continue }
                    $plan.install += $f
                }
            } finally { $z.Dispose() }
        } catch {
            $plan.unreadable = $true; $plan.haveZip = $false
            $plan.install = @(); $plan.current = @(); $plan.missing = @(); $plan.stale = @()
        }
    }
    if (-not $plan.haveZip) {
        foreach ($f in $files) { if ($installed[$f.name]) { $plan.current += $f } else { $plan.missing += $f } }
    }
    $plan.enable = @($plan.current | Where-Object { -not (LocalEntryOn $_.name) })
    return $plan
}
# Extracts each planned file to a temp name, checks its SHA-256, then moves it into addons\. An existing copy is moved
# into the snapshot first. Each file is recorded in the snapshot (name, sha256, replaced) BEFORE anything is moved, so
# Restore can undo a run that stopped half-way. Returns the names actually installed.
function Install-LocalPack($plan, $snapDir) {
    $done = @()
    $log = Join-Path $snapDir 'localpack_installed.txt'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($plan.zip)
    try {
        foreach ($f in $plan.install) {
            $dst = Join-Path $localDir $f.name
            $tmp = "$dst.etto-tmp"
            try {
                $e = $z.Entries | Where-Object { $_.FullName -notmatch '[\\/]' -and $_.Name -ieq $f.name } | Select-Object -First 1
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $tmp, $true)
                if ((Sha256File $tmp) -ne $f.sha256) { throw 'checksum does not match the list' }
                $replaced = Test-Path -LiteralPath $dst
                Add-Content -LiteralPath $log -Value ("{0}`t{1}`t{2}" -f $f.name, $f.sha256, [int]$replaced) -Encoding ASCII
                if ($replaced) { Move-Item -LiteralPath $dst (Join-Path $snapDir $f.name) -Force }
                Move-Item -LiteralPath $tmp $dst -Force
                $done += $f.name
                Say "  installed $($f.name)" 'Green'
            } catch {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                Say "  $($f.name): not installed ($($_.Exception.Message)). Ask Etto for a fresh pack, or run Restore.cmd." 'Yellow'
            }
        }
    } finally { $z.Dispose() }
    return $done
}
# Make sure each local add-on has an enabled entry in addonlist.txt (new ones go on top, like L4D2 does).
function Enable-LocalAddons([string[]]$names) {
    if (-not $names -or -not (Test-Path $addonList)) { return }
    $text = [IO.File]::ReadAllText($addonList)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($mm in [regex]::Matches($text, '"([^"]+\.vpk)"\s*"([01])"')) { $entries.Add(@{ name = $mm.Groups[1].Value; on = $mm.Groups[2].Value }) }
    for ($k = $names.Count - 1; $k -ge 0; $k--) {
        $e = $entries | Where-Object { $_.name -ieq $names[$k] } | Select-Object -First 1
        if ($e) { $e.on = '1' } else { $entries.Insert(0, @{ name = $names[$k]; on = '1' }) }
    }
    $out = '"AddonList"' + $nl + '{' + $nl
    foreach ($e in $entries) { $out += "`t`"$($e.name)`"`t`t`"$($e.on)`"" + $nl }
    $out += '}' + $nl
    [IO.File]::WriteAllText($addonList, $out, (New-Object Text.UTF8Encoding($false)))
}

# ---- Steam session ----------------------------------------------------------------------------------------
$rt = Join-Path $env:TEMP 'EttosPlayhouseSync'
New-Item -ItemType Directory -Force -Path $rt | Out-Null
Set-Content -Path (Join-Path $rt 'steam_appid.txt') -Value '550' -Encoding ASCII
Set-Location $rt; [Environment]::CurrentDirectory = $rt
$env:SteamAppId = '550'; $env:SteamGameId = '550'
[void][EttoSteam]::SetDllDirectory((Join-Path $game 'bin'))
if (-not [EttoSteam]::SteamAPI_Init()) { Fail 'Could not connect to Steam. Is Steam running, logged in, and does this account own Left 4 Dead 2?' }
[EttoSteam]::Ugc = [EttoSteam]::SteamAPI_SteamUGC_v016()

function Apply-Changes([uint64[]]$add, [uint64[]]$remove) {
    foreach ($id in $remove) { [void][EttoSteam]::SteamAPI_ISteamUGC_UnsubscribeItem([EttoSteam]::Ugc, $id) }
    foreach ($id in $add) { [void][EttoSteam]::SteamAPI_ISteamUGC_SubscribeItem([EttoSteam]::Ugc, $id); Start-Sleep -Milliseconds 300 }
    $deadline = (Get-Date).AddSeconds(45)
    do {
        [EttoSteam]::SteamAPI_RunCallbacks(); Start-Sleep -Milliseconds 250
        $now = [EttoSteam]::Subscribed()
        $pending = @($add | Where-Object { $now -notcontains $_ }) + @($remove | Where-Object { $now -contains $_ })
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
    foreach ($id in $pending) { Say "  not confirmed by Steam: $id" 'Yellow' }
}

function Wait-Sub([uint64]$id, [bool]$want) {
    $deadline = (Get-Date).AddSeconds(15)
    do { [EttoSteam]::SteamAPI_RunCallbacks(); Start-Sleep -Milliseconds 200 } while ((([EttoSteam]::Subscribed()) -contains $id) -ne $want -and (Get-Date) -lt $deadline)
}
# Subscribe (or re-subscribe) items one at a time, oldest-priority first, so the LAST id ends up on top of
# L4D2's add-on list after the next launch. Items already subscribed are cycled (unsubscribe + subscribe);
# nothing is deleted - the game keeps the downloaded file. 1.2 s spacing because Steam's timestamps are per second.
function Set-SubscriptionOrder([uint64[]]$bottomToTop) {
    $i = 0
    foreach ($id in $bottomToTop) {
        $i++
        Write-Host ("`r  ordering {0}/{1}: {2}      " -f $i, $bottomToTop.Count, $id) -NoNewline
        if (([EttoSteam]::Subscribed()) -contains $id) { [void][EttoSteam]::SteamAPI_ISteamUGC_UnsubscribeItem([EttoSteam]::Ugc, $id); Wait-Sub $id $false }
        [void][EttoSteam]::SteamAPI_ISteamUGC_SubscribeItem([EttoSteam]::Ugc, $id); Wait-Sub $id $true
        Start-Sleep -Milliseconds 1200
    }
    if ($bottomToTop) { Write-Host '' }
}

try {
    $before = [EttoSteam]::Subscribed()
    # ---------------------------------------------------------------- restore
    if ($Restore) {
        $dir = if ($Backup) { $Backup } else { (Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName }
        if (-not $dir -or -not (Test-Path (Join-Path $dir 'subscribed.txt'))) { Fail 'No backup found to restore.' }
        $snap = @(Get-Content (Join-Path $dir 'subscribed.txt') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [uint64]$_ })
        $add = @($snap | Where-Object { $before -notcontains $_ })
        $remove = @($before | Where-Object { $snap -notcontains $_ })
        $lpFile = Join-Path $dir 'localpack_installed.txt'
        $lpRecs = @()
        if (Test-Path $lpFile) {
            foreach ($line in Get-Content $lpFile) {
                $c = "$line" -split "`t"
                if ($c.Count -ge 3 -and $c[0] -match '^[A-Za-z0-9_\-]+\.vpk\z' -and $c[1] -match '^[0-9a-f]{64}\z') { $lpRecs += [pscustomobject]@{ name = $c[0]; sha = $c[1]; replaced = ($c[2] -eq '1') } }
            }
        }
        Say "Restoring snapshot $(Split-Path $dir -Leaf): resubscribe $($add.Count), unsubscribe $($remove.Count), restore addonlist.txt$(if ($lpRecs) {", undo $($lpRecs.Count) local add-on(s)"})" 'Cyan'
        if ($DryRun) { Say 'Dry run - nothing changed.'; return }
        if (-not $Yes -and (Read-Host 'Proceed? (y/n)') -notmatch '^y') { return }
        Apply-Changes $add $remove
        foreach ($r in $lpRecs) {
            $cur = Join-Path $localDir $r.name; $old = Join-Path $dir $r.name
            $ours = (Test-Path -LiteralPath $cur) -and (Sha256File $cur) -eq $r.sha
            if (-not $ours -and (Test-Path -LiteralPath $cur)) { Say "  $($r.name) changed since that run - left as it is." 'Yellow'; continue }
            if ($r.replaced -and (Test-Path -LiteralPath $old)) { Copy-Item -LiteralPath $old $cur -Force; Say "  $($r.name): previous copy put back" }
            elseif ($ours) { Remove-Item -LiteralPath $cur -Force; Say "  $($r.name): removed" }
        }
        $al = Join-Path $dir 'addonlist.txt'
        if (Test-Path $al) { Copy-Item $al $addonList -Force }
        Say "`nRestored. Launch Left 4 Dead 2 once so Steam re-downloads anything that was removed." 'Green'
        return
    }

    # ---------------------------------------------------------------- sync
    $m = Get-Manifest
    Say "== $($m.name) - Workshop sync (manifest $($m.updated), script v$ScriptVersion) ==" 'Cyan'
    if ($m.latestScript -and [int]$m.latestScript -gt $ScriptVersion) { Say "A newer sync script (v$($m.latestScript)) is available: $($m.scriptUrl)" 'Yellow' }
    foreach ($n in @($m.notes)) { if ($n) { Say "Note: $n" 'DarkCyan' } }

    $req = Ids $m.required; $rec = Ids $m.recommended; $par = Ids $m.parity
    $order = if ($Parity) { @($m.loadOrder | Where-Object { $_ } | ForEach-Object { [uint64]"$_" }) } else { @() }
    $want = if ($Parity) { @($req) + @($par) } else { @($req) }
    # top-priority items, top first: loadFirstAll (v3+), else the single loadFirst
    $tops = @(@($m.loadFirstAll) | Where-Object { $_ } | ForEach-Object { [uint64]"$_" })
    if (-not $tops.Count -and $m.loadFirst) { $tops = @([uint64]"$($m.loadFirst)") }
    $topsUp = if ($tops.Count) { @($tops[($tops.Count - 1)..0]) } else { @() }   # bottom -> top
    $removeSet = @(Ids $m.retired) + @(Ids $m.knownBad)
    if ($Strict) { $removeSet += @($before | Where-Object { $want -notcontains $_ -and $rec -notcontains $_ }) }
    $remove = @($before | Where-Object { $removeSet -contains $_ } | Select-Object -Unique)
    $add = @($want | Where-Object { $before -notcontains $_ -and $tops -notcontains $_ } | Select-Object -Unique)
    $add += @($topsUp | Where-Object { $before -notcontains $_ })    # load-first items are subscribed last

    # ---- load order = subscription order (newest on top). Work out what has to be (re)subscribed in sequence.
    $gameOrder = Get-GameOrder                                   # as L4D2 wrote it at its last launch
    $after = @($before | Where-Object { $remove -notcontains $_ }) + @($add)
    $cycle = @()
    if ($Parity -and $order) {
        $target = @($order | Where-Object { $after -contains $_ })              # top -> bottom
        $cur = @($gameOrder | Where-Object { $target -contains $_ })
        if (@($add | Where-Object { $target -contains $_ }).Count -gt 0 -or (($cur -join ',') -ne ($target -join ','))) {
            $cycle = @($target[($target.Count - 1)..0])                         # bottom -> top
        }
    }
    $topNow = @($gameOrder | Select-Object -First $tops.Count)
    $topsOk = $gameOrder.Count -eq 0 -or (($topNow -join ',') -eq ($tops -join ','))
    if ($tops.Count -and $cycle.Count -eq 0 -and ($add.Count -gt 0 -or -not $topsOk)) { $cycle = $topsUp }
    if ($tops.Count -and $cycle.Count -gt 0) { $cycle = @($cycle | Where-Object { $tops -notcontains $_ }) + $topsUp }   # load-first items always last = top

    Say "`nSubscribed now: $($before.Count) items.  Mode: $(if ($Strict) {'STRICT'} else {'Standard'})$(if ($Parity) {' + PARITY'})"
    if ($add) { Say "`nWill SUBSCRIBE ($($add.Count)):" 'Green'; foreach ($i in $add) { Say "  + $i  $(Label $m $i)" } }
    if ($remove) { Say "`nWill UNSUBSCRIBE ($($remove.Count)):" 'Yellow'; foreach ($i in $remove) { $l = Label $m $i; $r = (@($m.knownBad) | Where-Object { $_ -and [uint64]"$($_.id)" -eq $i }).reason; Say "  - $i  $l$(if ($r) {"  ($r)"})" } }
    $missingRec = @($rec | Where-Object { $before -notcontains $_ })
    if ($missingRec -and -not $Strict) { Say "`nRecommended (optional, not changed):" 'DarkCyan'; foreach ($i in $missingRec) { Say "  ? https://steamcommunity.com/sharedfiles/filedetails/?id=$i  $(Label $m $i)" } }
    if (-not $add -and -not $remove) { Say "`nSubscriptions already match." 'Green' }
    if ($cycle.Count -eq 1) { Say "`nLoad order: will re-subscribe $($cycle[0]) ($(Label $m $cycle[0])) so it loads first (takes effect at your next launch)." 'Green' }
    elseif ($cycle.Count -gt 1) { Say "`nLoad order: will (re)subscribe $($cycle.Count) add-ons one by one in Etto's order (about $([int]($cycle.Count * 1.6)) s; takes effect at your next launch). Nothing is re-downloaded." 'Green' }
    elseif ($tops.Count) { Say "`nLoad order OK: $($tops -join ', ') already on top." 'Green' }
    if (-not $Parity -and $par) {
        $missPar = @($par | Where-Object { $before -notcontains $_ })
        $mb = 0; foreach ($it in @($m.parity)) { if ($it -and $missPar -contains [uint64]"$($it.id)" -and $it.mb) { $mb += [double]$it.mb } }
        if ($missPar) { Say ("`nOptional: Parity.cmd copies Etto's full client setup and load order ({0} more add-ons, about {1:N1} GB to download)." -f $missPar.Count, ($mb / 1024)) 'DarkCyan' }
    }

    # ---- warnings: mechanical file-path checks on items the manifest does not know about ----
    $known = @($req) + @($rec) + @($par) + @($removeSet)
    $reqMissions = @{}; $reqMaps = @{}
    foreach ($id in $req) {
        $f = Join-Path $addonsDir "$id.vpk"
        if (Test-Path $f) { foreach ($p in [EttoSteam]::VpkFiles($f)) { if ($tops -notcontains $id -and $p -match '^missions/(.+\.txt)$') { $reqMissions[$Matches[1].ToLower()] = $id }; if ($p -match '^maps/(.+)\.bsp$') { $reqMaps[$Matches[1].ToLower()] = $id } } }
    }
    $warn = @()
    foreach ($id in ($before | Where-Object { $known -notcontains $_ })) {
        $f = Join-Path $addonsDir "$id.vpk"
        if (-not (Test-Path $f)) { continue }
        $files = [EttoSteam]::VpkFiles($f); $why = @()
        if ($files | Where-Object { $_ -match '^models/survivors/anim_' -or $_ -match '/xdreanims/' }) { $why += 'replaces survivor ANIMATIONS (this exact kind of mod crashed players on this server)' }
        $mo = @($files | Where-Object { $_ -match '^missions/(.+\.txt)$' -and $reqMissions.ContainsKey($Matches[1].ToLower()) })
        if ($mo) { $why += "overrides a server campaign's mission file ($($mo -join ', ')) - can cause wrong names or 'unable to open map'" }
        $mp = @($files | Where-Object { $_ -match '^maps/(.+)\.bsp$' -and $reqMaps.ContainsKey($Matches[1].ToLower()) })
        if ($mp) { $why += "contains maps the server already gets from another item ($($mp.Count) map(s)) - duplicate/old copy of a campaign" }
        if ($why) { $warn += [pscustomobject]@{ id = $id; why = $why } }
    }
    if ($warn) {
        Say "`nWARNINGS (not changed - consider unsubscribing):" 'Magenta'
        foreach ($w in $warn) { Say "  ! https://steamcommunity.com/sharedfiles/filedetails/?id=$($w.id)" 'Magenta'; foreach ($y in $w.why) { Say "      $y" } }
    }

    # ---- Etto's local add-ons (Parity only) ----
    $lp = if ($Parity) { Get-LocalPackPlan $m } else { $null }
    if ($LocalPack -and -not $Parity) { Say "`n-LocalPack only applies to Parity.cmd (-Parity); ignored." 'Yellow' }
    if ($lp) {
        $all = @($m.localPack.files | Where-Object { $_ })
        if ($lp.install) { Say "`nWill INSTALL Etto's local add-ons from $(Split-Path $lp.zip -Leaf) ($($lp.install.Count)):" 'Green'; foreach ($f in $lp.install) { Say "  + $($f.name)  $($f.label)" } }
        if ($lp.current.Count -eq $all.Count -and -not $lp.enable) { Say "`nEtto's local add-ons: all $($all.Count) installed and up to date." 'Green' }
        if ($lp.enable) { Say "`nWill SWITCH ON Etto's local add-ons that are installed but off ($($lp.enable.Count)): $(@($lp.enable | ForEach-Object { $_.name }) -join ', ')" 'Green' }
        if ($lp.missing) {
            $why = if ($lp.unreadable) { "$(Split-Path $lp.zip -Leaf) is damaged or incomplete" } elseif ($lp.haveZip) { "not in $(Split-Path $lp.zip -Leaf)" } elseif ($lp.given) { "$($lp.zip) not found" } else { "no $($lp.zipName) next to this script" }
            Say "`nEtto's local add-ons missing ($($lp.missing.Count), $why):" 'Yellow'
            foreach ($f in $lp.missing) { Say "  ? $($f.name)  $($f.label)" }
            Say "  These aren't on the Workshop. Ask Etto for the pack zip and put it next to Parity.cmd, then run Parity.cmd again." 'Yellow'
        }
        if ($lp.stale) { Say "`nThe pack zip has an older or newer copy of $($lp.stale.Count) file(s) than this list ($(@($lp.stale | ForEach-Object { $_.name }) -join ', ')). Ask Etto for a fresh pack." 'Yellow' }
    }
    $lpWork = $lp -and ($lp.install.Count -gt 0 -or $lp.enable.Count -gt 0)

    if ($DryRun) { Say "`nDry run - nothing changed."; return }
    if (-not $add -and -not $remove -and $cycle.Count -eq 0 -and -not $lpWork) { Say "`nNothing to do."; return }
    if (-not $Yes) { if ((Read-Host "`nApply these changes? (y/n)") -notmatch '^y') { return } }

    # ---- snapshot, then apply ----
    $snapDir = Join-Path $backupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
    $before | ForEach-Object { "$_" } | Set-Content (Join-Path $snapDir 'subscribed.txt') -Encoding ASCII
    if (Test-Path $addonList) { Copy-Item $addonList (Join-Path $snapDir 'addonlist.txt') }
    Say "`nSnapshot saved: $snapDir  (Restore.cmd undoes this run)"

    $plain = @($add | Where-Object { $cycle -notcontains $_ })
    if ($plain -or $remove) { Apply-Changes $plain $remove }
    if ($cycle) { Set-SubscriptionOrder $cycle }
    Update-AddonList $tops $want $remove
    if ($lp -and $lp.install.Count -gt 0) {
        Say "`nInstalling Etto's local add-ons:" 'Cyan'
        [void](Install-LocalPack $lp $snapDir)
    }
    if ($lp) { Enable-LocalAddons @(@($lp.current) + @($lp.install) | ForEach-Object { $_.name } | Where-Object { Test-Path -LiteralPath (Join-Path $localDir $_) }) }
    Say "`naddonlist.txt updated: required items enabled." 'Green'
    # L4D2 (legacy Workshop) downloads new items itself when it starts, and may re-order addonlist.txt.
    $notDownloaded = @($want | Where-Object { -not (Test-Path (Join-Path $addonsDir "$_.vpk")) })
    if ($notDownloaded.Count -gt 0) {
        Say "`n$($notDownloaded.Count) add-on(s) are not downloaded yet. Left 4 Dead 2 downloads them itself:" 'Yellow'
        Say '  1. Launch Left 4 Dead 2 and stay at the main menu until the add-on downloads finish.' 'Yellow'
        Say '  2. Quit the game, then launch again and play. (The load order is already set by this run.)' 'Yellow'
    } else {
        Say "`nDone. Launch Left 4 Dead 2 once (it applies the new load order and removes unsubscribed items), quit, then launch again and play." 'Cyan'
    }
}
finally {
    [EttoSteam]::SteamAPI_Shutdown()
}
