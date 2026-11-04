<#
  Etto's Playhouse - L4D2 Workshop sync
  Keeps a player's Left 4 Dead 2 Workshop subscriptions compatible with the server.

  Modes
    (default)  Standard: subscribe required items, unsubscribe retired / known-bad items, put the load-first
               item at the top of addonlist.txt, enable required items, and (v7) add the -heapsize launch option
               described below. Nothing else is touched.
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
    -NoConfig  With -Parity: don't touch the game config. Otherwise, when EttosPlayhouse_Server.txt (host:port) sits
               next to this script, Parity probes the server and writes cfg\etto_net.cfg (rates + interp) plus marked
               blocks in cfg\autoexec.cfg (console, ping on mouse5, F8 = join) and cfg\listenserver.cfg (stock values
               for local games). Keys that are already bound are left alone. Restore.cmd takes it all out again.

  Your own local add-ons (v8): .vpk files directly in left4dead2\addons\ (not Etto's local pack) load above every
  Workshop item and override the server's add-ons. Every mode lists them with the same crash checks; Parity and -Strict
  switch them off in addonlist.txt (the files stay; Restore.cmd or the game's Add-ons menu turns them back on).
  -KeepLocalAddons leaves them on. Risky loose files in the game folder (survivor animations, a particle list,
  mission files) are reported, never changed.

  Add-ons that need Etto's local pack (v9): the manifest's "parityLocal" list (read only by v9+, so older scripts never
  subscribe these) holds parity items that are meant to run with a local-pack file ("needsLocal") that overrides
  one of their files ("needsPath"). Parity subscribes such an item only when that file is installed from the pack zip in
  the same run, or is installed, contains needsPath and isn't switched off; otherwise it is skipped (Parity + -Strict
  unsubscribes it). Standard and Parity warn when you are subscribed to one without its file. (Etto's pack carries a
  rebuilt wound texture and smaller textures for Improved gore textures and models. v9 said the mod's own copy crashed
  fresh joins; that was wrong, a dump with the same crash predates the mod.)

  Launch option (v7, all modes): when the manifest sets heapsizeKB, the script makes sure Left 4 Dead 2's Steam launch
  options contain -heapsize <KB> (a bigger model/sound cache; without it sound cuts in and out on big maps on Etto's
  server). Steam rewrites its settings when it exits, so the script closes Steam for a moment, edits the launch options
  of the logged-in account, and starts Steam again. Restore.cmd takes the option out again (Restore undoes the latest
  snapshot; use -Backup <folder> for an older run). -NoLaunchOption leaves the launch options alone.

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
    [string]$LocalPack,
    [switch]$NoConfig,
    [switch]$NoLaunchOption,
    [switch]$KeepLocalAddons
)

$ScriptVersion = 10
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
$cfgDir = Join-Path $game 'left4dead2\cfg'
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
    foreach ($sec in 'required', 'recommended', 'parity', 'parityLocal', 'retired', 'knownBad') {
        foreach ($it in @($m.$sec)) {
            if ($null -eq $it) { continue }
            if ("$($it.id)" -notmatch '^\d{6,12}$') { Fail "Manifest '$sec' has an invalid Workshop id '$($it.id)'." }
        }
    }
    if ($m.loadFirst -and "$($m.loadFirst)" -notmatch '^\d{6,12}$') { Fail 'Manifest loadFirst is not a Workshop id.' }
    foreach ($o in @($m.loadFirstAll)) { if ($o -and "$o" -notmatch '^\d{6,12}$') { Fail "Manifest loadFirstAll has an invalid Workshop id '$o'." } }
    foreach ($o in @($m.loadOrder)) { if ($o -and "$o" -notmatch '^\d{6,12}$') { Fail "Manifest loadOrder has an invalid Workshop id '$o'." } }
    if ($null -ne $m.heapsizeKB -and "$($m.heapsizeKB)" -notmatch '^\d{1,7}\z') { Fail 'Manifest heapsizeKB is not a number.' }
    foreach ($f in @($m.localPack.files)) {
        if ($null -eq $f) { continue }
        if ("$($f.name)" -notmatch '^[A-Za-z0-9_\-]+\.vpk\z') { Fail "Manifest localPack has an invalid file name '$($f.name)'." }
        if ("$($f.sha256)" -notmatch '^[0-9a-f]{64}\z') { Fail "Manifest localPack has an invalid SHA-256 for '$($f.name)'." }
        if ($null -ne $f.bytes -and "$($f.bytes)" -notmatch '^\d+\z') { Fail "Manifest localPack has an invalid size for '$($f.name)'." }
    }
    $lpNames = @(@($m.localPack.files) | Where-Object { $_ } | ForEach-Object { "$($_.name)".ToLower() })
    foreach ($it in @($m.parityLocal)) {
        if ($null -eq $it) { continue }
        if ($lpNames -notcontains "$($it.needsLocal)".ToLower()) { Fail "Manifest parityLocal item $($it.id) needs '$($it.needsLocal)', which is not in localPack." }
        if ("$($it.needsPath)" -notmatch '^[A-Za-z0-9_\-]+(/[A-Za-z0-9_.\-]+)+\z' -or "$($it.needsPath)" -match '(^|/)\.\.(/|$)') { Fail "Manifest parityLocal item $($it.id) has an invalid needsPath." }
    }
    # v9 treats parityLocal as part of parity from here on (older scripts don't read it, so they never subscribe these)
    $m | Add-Member -NotePropertyName parity -NotePropertyValue @(@($m.parity) + @($m.parityLocal) | Where-Object { $_ }) -Force
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
    foreach ($m in [regex]::Matches($text, '(?i)"([^"]+\.vpk)"\s*"([01])"')) { $entries.Add(@{ name = $m.Groups[1].Value; on = $m.Groups[2].Value }) }
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
# (v9) Is the local-pack file a parityLocal item depends on in place? Yes when this run installs it from the zip or
# finds it current (Parity switches those on), or when it is installed, contains needsPath and isn't switched off.
# Any version with the path is enough: the item only misses the fix while its own copy of that file wins.
function LocalFixReady($it, $lp) {
    $nl = "$($it.needsLocal)".ToLower()
    if ($lp -and @(@($lp.install) + @($lp.current) | Where-Object { $_ -and "$($_.name)".ToLower() -eq $nl }).Count) { return $true }
    $dst = Join-Path $localDir "$($it.needsLocal)"
    if (-not (Test-Path -LiteralPath $dst)) { return $false }
    if ((Test-Path $addonList) -and [regex]::IsMatch([IO.File]::ReadAllText($addonList), '"' + [regex]::Escape("$($it.needsLocal)") + '"\s*"0"', 'IgnoreCase')) { return $false }
    try { return @([EttoSteam]::VpkFiles($dst)) -contains "$($it.needsPath)" } catch { return $false }
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
# The player's own local add-ons (v8): every addons\*.vpk that isn't in Etto's local pack and is (or will be) switched on.
# The game lists a new local .vpk as enabled at its next launch, so files not in addonlist.txt yet count as on.
function Get-OwnLocalAddons([string[]]$ettoNames) {
    if (-not (Test-Path -LiteralPath $localDir)) { return @() }
    $state = @{}
    if (Test-Path $addonList) {
        foreach ($mm in [regex]::Matches([IO.File]::ReadAllText($addonList), '(?i)"([^"\\/]+\.vpk)"\s*"([01])"')) { $state[$mm.Groups[1].Value.ToLower()] = $mm.Groups[2].Value }
    }
    @(Get-ChildItem -LiteralPath $localDir -Filter '*.vpk' -File -ErrorAction SilentlyContinue | Where-Object {
        $n = $_.Name.ToLower()
        $ettoNames -notcontains $n -and $n -notmatch '_[0-9]{3}\.vpk\z' -and (-not $state.ContainsKey($n) -or $state[$n] -eq '1')
    } | ForEach-Object { [pscustomobject]@{ name = $_.Name; path = $_.FullName } })
}
# Switch local add-ons off in addonlist.txt (the files stay where they are; the game's Add-ons menu or Restore turns them on).
function Disable-LocalAddons([string[]]$names) {
    if (-not $names -or -not (Test-Path $addonList)) { return }
    $text = [IO.File]::ReadAllText($addonList)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($mm in [regex]::Matches($text, '(?i)"([^"]+\.vpk)"\s*"([01])"')) { $entries.Add(@{ name = $mm.Groups[1].Value; on = $mm.Groups[2].Value }) }
    foreach ($n in $names) {
        $e = $entries | Where-Object { $_.name -ieq $n } | Select-Object -First 1
        if ($e) { $e.on = '0' } else { $entries.Add(@{ name = $n; on = '0' }) }
    }
    $out = '"AddonList"' + $nl + '{' + $nl
    foreach ($e in $entries) { $out += "`t`"$($e.name)`"`t`t`"$($e.on)`"" + $nl }
    $out += '}' + $nl
    [IO.File]::WriteAllText($addonList, $out, (New-Object Text.UTF8Encoding($false)))
}
# Make sure each local add-on has an enabled entry in addonlist.txt (new ones go on top, like L4D2 does).
function Enable-LocalAddons([string[]]$names) {
    if (-not $names -or -not (Test-Path $addonList)) { return }
    $text = [IO.File]::ReadAllText($addonList)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($mm in [regex]::Matches($text, '(?i)"([^"]+\.vpk)"\s*"([01])"')) { $entries.Add(@{ name = $mm.Groups[1].Value; on = $mm.Groups[2].Value }) }
    for ($k = $names.Count - 1; $k -ge 0; $k--) {
        $e = $entries | Where-Object { $_.name -ieq $names[$k] } | Select-Object -First 1
        if ($e) { $e.on = '1' } else { $entries.Insert(0, @{ name = $names[$k]; on = '1' }) }
    }
    $out = '"AddonList"' + $nl + '{' + $nl
    foreach ($e in $entries) { $out += "`t`"$($e.name)`"`t`t`"$($e.on)`"" + $nl }
    $out += '}' + $nl
    [IO.File]::WriteAllText($addonList, $out, (New-Object Text.UTF8Encoding($false)))
}

# ---- game config: net settings + binds for Etto's server (Parity, hand-off folder only) ---------------------
# The server address comes from EttosPlayhouse_Server.txt next to this script (in the folder Etto hands out), never
# from the internet. Everything written is fenced by the markers below, so Restore can take it out again.
$EttoBegin = "// >>> Etto's Playhouse (added by Parity.cmd; Restore.cmd removes it) >>>"
$EttoEnd = "// <<< Etto's Playhouse <<<"
$EttoNetHeader = "// Etto's Playhouse net settings - written by Parity.cmd"
$CfgEnc = [Text.Encoding]::GetEncoding(28591)   # Latin-1: reads and writes every byte of a user cfg unchanged
function Get-ServerAddress {
    $f = Join-Path $PSScriptRoot 'EttosPlayhouse_Server.txt'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $a = "$(Get-Content -LiteralPath $f -TotalCount 1)".Trim()
    if ($a -notmatch '^[A-Za-z0-9.\-]{1,100}:(\d{1,5})\z' -or [int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535) { Say "  EttosPlayhouse_Server.txt doesn't hold host:port - skipping the game config." 'Yellow'; return $null }
    return $a
}
# Server-browser (A2S_INFO) queries, 0.4 s apart (servers answer ~3 queries/s per address). Returns ms timings.
function Test-ServerLink([string]$addr, [int]$count = 24) {
    $hostName, $port = $addr -split ':'
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = 1000
    $q = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0x54) + [Text.Encoding]::ASCII.GetBytes("Source Engine Query") + [byte[]](0)
    $rtt = New-Object System.Collections.Generic.List[double]; $lost = 0
    try {
        $udp.Connect($hostName, [int]$port)
        $remote = New-Object System.Net.IPEndPoint([Net.IPAddress]::Any, 0)
        for ($i = 0; $i -lt $count; $i++) {
            while ($udp.Available -gt 0) { try { [void]$udp.Receive([ref]$remote) } catch { break } }   # drop late replies
            $sw = [Diagnostics.Stopwatch]::StartNew()
            [void]$udp.Send($q, $q.Length)
            try {
                $r = $udp.Receive([ref]$remote)
                if ($r.Length -ge 5 -and $r[0] -eq 0xFF -and $r[1] -eq 0xFF -and $r[2] -eq 0xFF -and $r[3] -eq 0xFF -and ($r[4] -eq 0x49 -or $r[4] -eq 0x41)) { $rtt.Add($sw.Elapsed.TotalMilliseconds) } else { $lost++ }
            } catch { $lost++ }
            $left = 400 - [int]$sw.ElapsedMilliseconds
            if ($left -gt 0) { Start-Sleep -Milliseconds $left }
            Write-Host ("`r  probing the server {0}/{1}" -f ($i + 1), $count) -NoNewline
        }
    } catch { $lost = $count - $rtt.Count } finally { $udp.Close(); Write-Host '' }
    $s = @($rtt | Sort-Object)
    if (-not $s.Count) { return [pscustomobject]@{ ok = $false; sent = $count; lost = $count } }
    $med = $s[[int][Math]::Floor(($s.Count - 1) / 2)]
    $q1 = $s[[int][Math]::Floor(0.25 * ($s.Count - 1))]
    $q3 = $s[[int][Math]::Ceiling(0.75 * ($s.Count - 1))]
    # jitter = interquartile range: robust to a single slow reply (a clean line measures ~5 ms here, because the
    # server answers once per 10 ms frame)
    return [pscustomobject]@{ ok = $true; sent = $count; lost = $lost; median = $med; jitter = $q3 - $q1 }
}
# Current binds (game-written config.cfg, then autoexec.cfg outside our block); keys lower-case.
function Get-Binds([string]$cfgDir) {
    $b = @{}
    foreach ($n in 'config.cfg', 'autoexec.cfg') {
        $p = Join-Path $cfgDir $n
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $t = Remove-EttoBlockText ($CfgEnc.GetString([IO.File]::ReadAllBytes($p)))
        foreach ($mm in [regex]::Matches($t, '(?im)^\s*bind\s+"?([^"\s]+)"?\s+"?([^"\r\n]*)"?')) { $b[$mm.Groups[1].Value.ToLower()] = $mm.Groups[2].Value.Trim() }
    }
    return $b
}
function Remove-EttoBlockText([string]$t) {
    $pat = '(?s)(\r?\n)?' + [regex]::Escape($EttoBegin) + '(?:(?!' + [regex]::Escape($EttoBegin) + ').)*?' + [regex]::Escape($EttoEnd) + '[^\r\n]*(\r?\n)?'
    return [regex]::Replace($t, $pat, { param($mm) if ($mm.Groups[1].Success -and $mm.Groups[2].Success) { $mm.Groups[1].Value } else { '' } })
}
# Last value a cvar is set to in config.cfg, then autoexec.cfg outside our block (autoexec runs later, so it wins).
function Get-CfgValue([string]$cfgDir, [string]$name) {
    $val = $null
    foreach ($n in 'config.cfg', 'autoexec.cfg') {
        $p = Join-Path $cfgDir $n
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $t = Remove-EttoBlockText ($CfgEnc.GetString([IO.File]::ReadAllBytes($p)))
        $pat = '(?im)^[ \t]*"?' + [regex]::Escape($name) + '"?[ \t]+"?([0-9]+(?:\.[0-9]+)?)"?[ \t]*(?:;|//|\r?$)'
        foreach ($mm in [regex]::Matches($t, $pat)) { $val = $mm.Groups[1].Value }
    }
    return $val
}
function Get-EttoBlockBody([string]$t) {
    $mm = [regex]::Match($t, '(?s)' + [regex]::Escape($EttoBegin) + '((?:(?!' + [regex]::Escape($EttoBegin) + ').)*?)' + [regex]::Escape($EttoEnd))
    if ($mm.Success) { return $mm.Groups[1].Value } else { return '' }
}
# Steam launch options for L4D2 that set +fps_max (they run after autoexec, so they win). Only the "550" { ... } app
# block counts: the same id also appears earlier in the file as a ticket line.
function Get-LaunchFpsMax {
    try {
        foreach ($f in Get-ChildItem (Join-Path $steamPath 'userdata\*\config\localconfig.vdf') -ErrorAction Stop) {
            $t = [IO.File]::ReadAllText($f.FullName)
            foreach ($b in [regex]::Matches($t, '"550"\s*\{(?>[^{}]+|\{(?<d>)|\}(?<-d>))*(?(d)(?!))\}')) {
                $mm = [regex]::Match($b.Value, '"LaunchOptions"\s+"([^"]*)"')
                if ($mm.Success -and $mm.Groups[1].Value -match '\+fps_max\s+"?([0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
            }
        }
    } catch { }
    return $null
}
# ---- Steam launch option -heapsize (script v7) ----
# The engine keeps model meshes and sounds in one cache, 256 MB by default. On Etto's server every model is preloaded
# and locked in it, so on big maps sounds get pushed out and cut in and out. -heapsize <KB> raises that budget
# (engine.dll reads it once at start, no clamp). Steam rewrites localconfig.vdf when it exits, so it can only be edited
# with Steam closed: the script closes Steam, edits the "550" app block of the logged-in account, and starts Steam again.
$VdfBlock = '\{(?>"(?:[^"\\]|\\.)*"|[^{}"]+|\{(?<d>)|\}(?<-d>))*(?(d)(?!))\}'   # quoted strings may hold { }
function Get-ActiveUserConfig {
    $id = (Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue).ActiveUser
    if ($id -and [int64]$id -ne 0) {
        $p = Join-Path $steamPath "userdata\$id\config\localconfig.vdf"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
# "<key>" { ... } that is a direct child of the block whose text is $t (depth 0 = file root), as @{ start; len; text }
function Find-ChildBlock([string]$t, [string]$key, [int]$at) {
    $depth = 0
    foreach ($mm in [regex]::Matches($t, '"(?:[^"\\]|\\.)*"|[{}]')) {
        if ($mm.Value -eq '{') { $depth++ }
        elseif ($mm.Value -eq '}') { $depth--; if ($depth -lt $at) { break } }
        elseif ($depth -eq $at -and $mm.Value -ieq ('"' + $key + '"')) {
            $b = [regex]::Match($t.Substring($mm.Index), '\A"[^"]*"\s*' + $VdfBlock)
            if ($b.Success) { return @{ start = $mm.Index; len = $b.Length; text = $b.Value } }
        }
    }
    return $null
}
# UserLocalConfigStore > Software > Valve > Steam > apps > 550, one direct child at a time (keys compared ignoring case:
# Steam writes "valve"). The file also has 550 blocks for depots and controller config; only this one holds LaunchOptions.
function Find-AppBlock([string]$t) {
    $off = 0; $txt = $t; $at = 0
    foreach ($k in 'UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps', '550') {
        $c = Find-ChildBlock $txt $k $at
        if (-not $c) { return $null }
        $off += $c.start; $txt = $c.text; $at = 1
    }
    return @{ start = $off; len = $txt.Length; text = $txt }
}
# The "LaunchOptions" "value" pair that is a direct key of the app block text $b (not one nested in a sub-block), as a
# regex Match (Groups[1] = the spacing between key and value, Groups[2] = the value), or $null.
$LoPair = New-Object regex '\G"LaunchOptions"(\s+)"((?:[^"\\]|\\.)*)"', 'IgnoreCase'
function Find-LaunchOptionsPair([string]$b) {
    $depth = 0
    foreach ($tk in [regex]::Matches($b, '"(?:[^"\\]|\\.)*"|[{}]')) {
        if ($tk.Value -eq '{') { $depth++ }
        elseif ($tk.Value -eq '}') { $depth-- }
        elseif ($depth -eq 1 -and $tk.Value -ieq '"LaunchOptions"') {
            $mm = $LoPair.Match($b, $tk.Index)
            if ($mm.Success) { return $mm }
        }
    }
    return $null
}
# The LaunchOptions value ('' when there is none), or $null when the file or the game's app block can't be read.
function Get-LaunchOptionsText([string]$path) {
    try {
        $blk = Find-AppBlock ([IO.File]::ReadAllText($path))
        if (-not $blk) { return $null }
        $mm = Find-LaunchOptionsPair $blk.text
        if ($mm) { return $mm.Groups[2].Value } else { return '' }
    } catch { return $null }
}
# Returns the edited file text ($t unchanged when nothing to do), or $null when the app block can't be found.
function Edit-LaunchOptions([string]$t, [string]$token, [bool]$add) {
    $blk = Find-AppBlock $t
    if (-not $blk) { return $null }
    $b = $blk.text
    $mm = Find-LaunchOptionsPair $b
    $flag = ($token -split '\s+')[0]
    if ($add) {
        if ($mm) {
            if ($mm.Groups[2].Value -match ('(^|\s)' + [regex]::Escape($flag) + '(\s|=|$)')) { return $t }
            $nv = ($mm.Groups[2].Value.Trim() + ' ' + $token).Trim()
            $nb = $b.Substring(0, $mm.Index) + '"LaunchOptions"' + $mm.Groups[1].Value + '"' + $nv + '"' + $b.Substring($mm.Index + $mm.Length)
        } else {
            $ob = $b.IndexOf('{')
            $ind = [regex]::Match($b, '\{\r?\n(\t*)"').Groups[1].Value
            if (-not $ind) { $ind = "`t`t`t`t`t`t" }
            $nl = if ($b.Contains("`r`n")) { "`r`n" } else { "`n" }
            $nb = $b.Substring(0, $ob + 1) + $nl + $ind + '"LaunchOptions"' + "`t`t" + '"' + $token + '"' + $b.Substring($ob + 1)
        }
    } else {
        if (-not $mm) { return $t }
        $old = $mm.Groups[2].Value
        $nv = [regex]::Replace($old, '(^|\s+)' + [regex]::Escape($token) + '(?=\s|$)', '').Trim()   # the player's own spacing stays
        if ($nv -ceq $old) { return $t }
        $nb = $b.Substring(0, $mm.Index) + '"LaunchOptions"' + $mm.Groups[1].Value + '"' + $nv + '"' + $b.Substring($mm.Index + $mm.Length)
    }
    return $t.Substring(0, $blk.start) + $nb + $t.Substring($blk.start + $blk.len)
}
# Close Steam (after this script has let go of it), edit the launch options, start Steam again. $true when done.
function Set-HeapsizeOption([string]$path, [string]$token, [bool]$add) {
    $done = $false
    $steamExe = Join-Path $steamPath 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe)) { Say "  steam.exe not found in $steamPath." 'Yellow'; return $false }
    if (-not $script:SteamApiDown) {
        # let the last subscribe / re-subscribe calls settle with Steam before it closes
        for ($i = 0; $i -lt 12; $i++) { [EttoSteam]::SteamAPI_RunCallbacks(); Start-Sleep -Milliseconds 250 }
        [EttoSteam]::SteamAPI_Shutdown(); $script:SteamApiDown = $true
    }
    try {
        Say '  closing Steam for a moment (keep this window open)...'
        Start-Process -FilePath $steamExe -ArgumentList '-shutdown'
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Process steam -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Get-Process steam -ErrorAction SilentlyContinue) { Say '  Steam did not close within 2 minutes (if it closes later, start it again yourself).' 'Yellow'; return $false }
        Start-Sleep -Seconds 2
        $t = [IO.File]::ReadAllText($path)
        $u = Edit-LaunchOptions $t $token $add
        if ($null -ne $u) {
            if ($u -cne $t) {
                # write a temp file, then swap it in: a failed write never leaves a cut-off localconfig.vdf
                $tmp = "$path.etto-tmp"
                [IO.File]::WriteAllText($tmp, $u, (New-Object Text.UTF8Encoding $false))
                [IO.File]::Replace($tmp, $path, $null)
            }
            $done = $true
        }
    } catch { Say "  couldn't edit $path ($($_.Exception.Message))" 'Yellow' }
    finally {
        if (-not (Get-Process steam -ErrorAction SilentlyContinue)) {
            Say '  starting Steam again (it may ask you to log in)...'
            # not as "game 550" from this script's temp folder: a clean Steam start
            Remove-Item Env:SteamAppId, Env:SteamGameId -ErrorAction SilentlyContinue
            Start-Process -FilePath $steamExe -WorkingDirectory $steamPath
        }
    }
    return $done
}
function Show-HeapsizeManual([string]$token) {
    if (-not $DryRun) { try { Set-Clipboard -Value $token } catch { } }
    Say "  Please add it yourself$(if (-not $DryRun) {" (it's on your clipboard)"}): Steam > Library > right-click Left 4 Dead 2 > Properties >" 'Yellow'
    Say "  General > Launch Options, add:  $token" 'Yellow'
}
# VSync caps the frame rate at the monitor's refresh rate whatever fps_max says. Returns the refresh rate when VSync
# is on and the fastest active display runs below 100 Hz, else 0. (Advice only - nothing is changed.)
function Get-VsyncCap([string]$cfgDir) {
    try {
        $v = Join-Path $cfgDir 'video.txt'
        if (-not (Test-Path -LiteralPath $v)) { return 0 }
        if ([IO.File]::ReadAllText($v) -notmatch '"setting\.mat_vsync"\s*"1"') { return 0 }
        $hz = @(Get-CimInstance Win32_VideoController -OperationTimeoutSec 5 -ErrorAction Stop | ForEach-Object { [int]$_.CurrentRefreshRate } | Where-Object { $_ -gt 0 } | Sort-Object -Descending)
        if ($hz.Count -and $hz[0] -lt 100) { return $hz[0] }
    } catch { }
    return 0
}
# Desired file contents; returns @{ path = content } (content $null = leave alone).
function Get-ConfigPlan([string]$cfgDir, [string]$addr, $link) {
    # The server answers browser queries once per server frame (10 ms at 100 tick), so a clean line already shows
    # about 5-9 ms of spread; only clearly worse than that, or real loss, gets the more forgiving ratio 2.
    $ratio = if ($link.ok -and $link.lost -lt 2 -and $link.jitter -le 12) { 1 } else { 2 }
    $why = if (-not $link.ok) { "server didn't answer the probe; using the safer 2" } elseif ($link.lost -ge 2) { "$($link.lost) of $($link.sent) probes lost" } elseif ($link.jitter -gt 12) { "jitter $([Math]::Round($link.jitter, 1)) ms" } else { 'clean connection' }
    $binds = Get-Binds $cfgDir
    $lines = @('con_enable 1')
    $notes = @()
    if (-not $binds.ContainsKey('`') -or $binds['`'] -eq 'toggleconsole') { $lines += 'bind "`" "toggleconsole"' } else { $notes += "`` stays $($binds['`'])" }
    $mouse5Fresh = -not $binds.ContainsKey('mouse5')
    if ($mouse5Fresh -or $binds['mouse5'] -eq 'sm_mark') { $lines += 'bind "MOUSE5" "sm_mark"' } else { $notes += "mouse5 is taken ($($binds['mouse5'])), so the ping is on !mark only" }
    $join = "exec etto_net; connect $addr"
    if (-not $binds.ContainsKey('f8') -or $binds['f8'] -like 'exec etto_net; connect *') { $lines += "bind `"F8`" `"$join`"" } else { $notes += "F8 is taken ($($binds['f8'])); join with: connect $addr" }
    # fps_max: the game sends at most one command packet per frame, so below 100 fps cl_cmdrate 100 can't be met.
    $autoPath = Join-Path $cfgDir 'autoexec.cfg'
    $oldBlock = if (Test-Path -LiteralPath $autoPath) { Get-EttoBlockBody ($CfgEnc.GetString([IO.File]::ReadAllBytes($autoPath))) } else { '' }
    # The game doesn't save fps_max to config.cfg, so the user's value always comes from their own cfg lines (or a
    # launch option); re-read it every run so a later change of theirs (say to 144) is respected.
    $fps = Get-CfgValue $cfgDir 'fps_max'
    if ($fps -and [double]$fps -gt 0 -and [double]$fps -lt 100) {
        $lines += "// your fps_max $fps is raised to 100 here (removing this block puts yours back)"; $lines += 'fps_max 100'
        if ($oldBlock -notmatch '(?m)^fps_max 100') { $notes += "fps_max was $fps - raising it to 100 so you can send all 100 commands a second" }
    }
    $lfps = Get-LaunchFpsMax
    if ($lfps -and [double]$lfps -gt 0 -and [double]$lfps -lt 100) { $notes += "Your Steam launch options set +fps_max $lfps, which overrides this. Remove it there (Library > Left 4 Dead 2 > Properties) for the full 100." }
    $cap = Get-VsyncCap $cfgDir
    if ($cap) { $notes += "VSync is on and your monitor runs at $cap Hz, so the game is capped at $cap fps ($cap commands a second). Turning VSync off (Options > Video) lets it reach the full 100." }
    $lines += 'exec etto_net'
    $net = @(($EttoNetHeader + " (interp ratio $ratio)."),
             '// Server: 100 tick, ratio clamped to 1..2. Common infected are not lag compensated, so keep lerp low.',
             'rate 100000', 'cl_updaterate 100', 'cl_cmdrate 100', 'cl_interp 0', "cl_interp_ratio $ratio", 'cl_lagcompensation 1') -join "`r`n"
    $local = @('// Local games run at 30 tick: stock net settings while hosting (Etto''s server values come back with F8 / next launch).',
               'rate 30000', 'cl_updaterate 30', 'cl_cmdrate 30', 'cl_interp_ratio 2', 'cl_interp 0.1')
    $plan = [ordered]@{}
    $plan[(Join-Path $cfgDir 'etto_net.cfg')] = $net + "`r`n"
    foreach ($pair in @(@('autoexec.cfg', $lines), @('listenserver.cfg', $local))) {
        $p = Join-Path $cfgDir $pair[0]
        $old = if (Test-Path -LiteralPath $p) { $CfgEnc.GetString([IO.File]::ReadAllBytes($p)) } else { '' }
        $base = (Remove-EttoBlockText $old).TrimEnd("`r", "`n")
        $plan[$p] = ($(if ($base) { $base + "`r`n`r`n" } else { '' }) + $EttoBegin + "`r`n" + ($pair[1] -join "`r`n") + "`r`n" + $EttoEnd + "`r`n")
    }
    $keys = @(); if ($mouse5Fresh) { $keys += 'mouse5' }; if ($lines -match '^bind "F8"') { $keys += 'f8' }
    return [pscustomobject]@{ files = $plan; ratio = $ratio; why = $why; notes = $notes; link = $link; keys = $keys }
}
function Get-ConfigChanges($cp) {
    @($cp.files.Keys | Where-Object { -not (Test-Path -LiteralPath $_) -or $CfgEnc.GetString([IO.File]::ReadAllBytes($_)) -cne $cp.files[$_] })
}
function Write-ConfigPlan($cp, [string]$snapDir) {
    foreach ($p in (Get-ConfigChanges $cp)) {
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p (Join-Path $snapDir ('cfg_' + (Split-Path $p -Leaf))) -Force }
        [IO.File]::WriteAllText($p, $cp.files[$p], $CfgEnc)
        Say "  wrote $(Split-Path $p -Leaf)" 'Green'
    }
}
# Restore: take our blocks out (whatever else changed in those files stays) and delete etto_net.cfg if it's ours.
function Remove-EttoConfig([string]$cfgDir, [string[]]$keys) {
    $c = Join-Path $cfgDir 'config.cfg'
    if ($keys -and (Test-Path -LiteralPath $c)) {
        $t = $CfgEnc.GetString([IO.File]::ReadAllBytes($c)); $u = $t
        if ($keys -contains 'f8') { $u = [regex]::Replace($u, '(?im)^\s*bind\s+"F8"\s+"exec etto_net; connect [^"\r\n]*"[^\r\n]*\r?\n?', '') }
        if ($keys -contains 'mouse5') { $u = [regex]::Replace($u, '(?im)^\s*bind\s+"MOUSE5"\s+"sm_mark"[^\r\n]*\r?\n?', '') }
        if ($u -cne $t) { [IO.File]::WriteAllText($c, $u, $CfgEnc); Say '  removed the F8 / mouse5 binds Parity added from config.cfg' }
    }
    foreach ($n in 'autoexec.cfg', 'listenserver.cfg') {
        $p = Join-Path $cfgDir $n
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $t = $CfgEnc.GetString([IO.File]::ReadAllBytes($p)); $u = Remove-EttoBlockText $t
        if ($u -ne $t) { $u = $u.TrimEnd("`r", "`n"); if ($u) { $u += "`r`n" } [IO.File]::WriteAllText($p, $u, $CfgEnc); Say "  removed Etto's block from $n" }
    }
    $n = Join-Path $cfgDir 'etto_net.cfg'
    if ((Test-Path -LiteralPath $n) -and ($CfgEnc.GetString([IO.File]::ReadAllBytes($n))).StartsWith($EttoNetHeader)) { Remove-Item -LiteralPath $n -Force; Say '  removed etto_net.cfg' }
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
        $cfgMark = Join-Path $dir 'cfg_written.txt'; if (-not (Test-Path $cfgMark)) { $cfgMark = $null }
        $heapRec = $null
        $hf = Join-Path $dir 'heapsize_added.txt'
        if (Test-Path $hf) {
            $c = "$(Get-Content $hf -TotalCount 1)" -split "`t"
            # only when our exact token is still there (not after a second Restore or a manual removal)
            if ($c.Count -ge 2 -and $c[0] -match 'localconfig\.vdf\z' -and $c[1] -match '^-heapsize [0-9]+\z' -and (Test-Path -LiteralPath $c[0]) -and
                "$(Get-LaunchOptionsText $c[0])" -match ('(^|\s)' + [regex]::Escape($c[1]) + '(\s|$)')) { $heapRec = [pscustomobject]@{ path = $c[0]; token = $c[1] } }
        }
        Say "Restoring snapshot $(Split-Path $dir -Leaf): resubscribe $($add.Count), unsubscribe $($remove.Count), restore addonlist.txt$(if ($lpRecs) {", undo $($lpRecs.Count) local add-on(s)"})$(if ($cfgMark) {", remove Etto's game settings"})$(if ($heapRec) {", remove the launch option $($heapRec.token) (Steam closes for a moment)"})$(if (Test-Path (Join-Path $dir 'local_switched_off.txt')) {" (this also switches your own local add-ons back on)"})" 'Cyan'
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
        if ($cfgMark) { Remove-EttoConfig $cfgDir @(Get-Content $cfgMark | Where-Object { $_ -in 'f8', 'mouse5' }) }
        $al = Join-Path $dir 'addonlist.txt'
        if (Test-Path $al) { Copy-Item $al $addonList -Force }
        if ($heapRec) {
            if (Set-HeapsizeOption $heapRec.path $heapRec.token $false) { Say "  removed $($heapRec.token) from Left 4 Dead 2's launch options." }
            else { Say "  Couldn't edit the launch options; remove $($heapRec.token) yourself (Left 4 Dead 2 > Properties > Launch Options)." 'Yellow' }
        }
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
    # (v9) parityLocal items need one of Etto's local-pack files (LocalFixReady): Parity skips them without it, and
    # Standard/Parity warn about one that is subscribed without it.
    if ($Parity -and @($m.localPack.files | Where-Object { $_ }).Count) { Say "`nChecking Etto's local add-ons..." 'DarkGray' }
    $lp = if ($Parity) { Get-LocalPackPlan $m } else { $null }
    $needSkip = @(); $needWarn = @(); $skipIds = @()
    foreach ($it in @($m.parityLocal | Where-Object { $_ })) {
        $nid = [uint64]"$($it.id)"
        if (-not $Parity -and $before -notcontains $nid) { continue }
        if (LocalFixReady $it $lp) { continue }
        if ($Parity) { $needSkip += $it }
        if ($before -contains $nid) { $needWarn += $it }
    }
    if ($needSkip) { $skipIds = @($needSkip | ForEach-Object { [uint64]"$($_.id)" }); $want = @($want | Where-Object { $skipIds -notcontains $_ }) }
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
    if ($remove) { Say "`nWill UNSUBSCRIBE ($($remove.Count)):" 'Yellow'; foreach ($i in $remove) { $l = Label $m $i; $r = (@($m.knownBad) | Where-Object { $_ -and [uint64]"$($_.id)" -eq $i }).reason; if (-not $r -and $skipIds -contains $i) { $r = "needs one of Etto's local add-ons, which isn't installed" }; Say "  - $i  $l$(if ($r) {"  ($r)"})" } }
    $missingRec = @($rec | Where-Object { $before -notcontains $_ })
    if ($missingRec -and -not $Strict) { Say "`nRecommended (optional, not changed):" 'DarkCyan'; foreach ($i in $missingRec) { Say "  ? https://steamcommunity.com/sharedfiles/filedetails/?id=$i  $(Label $m $i)" } }
    $skipNew = @($needSkip | Where-Object { $before -notcontains [uint64]"$($_.id)" })   # subscribed ones: warned below
    if ($skipNew) {
        Say "`nNot subscribing (needs one of Etto's local add-ons, which isn't installed or current; get Etto's pack zip):" 'Yellow'
        foreach ($it in $skipNew) { Say "  ~ $($it.id)  $($it.label)  (needs $($it.needsLocal))" }
    }
    $needWarn = @($needWarn | Where-Object { $remove -notcontains [uint64]"$($_.id)" })
    if ($needWarn) {
        Say "`nNote - subscribed without the Etto local add-on it is meant to run with (it just misses the texture fixes):" 'Magenta'
        foreach ($it in $needWarn) { Say "  ! https://steamcommunity.com/sharedfiles/filedetails/?id=$($it.id)  $($it.label)  (needs $($it.needsLocal))" 'Magenta' }
        Say "  Put Etto's pack zip next to Parity.cmd and run Parity.cmd, or unsubscribe it." 'Magenta'
    }
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

    # ---- the player's own local add-ons and loose files (v8) ----
    # Local add-ons (addons\*.vpk) load ABOVE every Workshop item, so they override the server's add-ons and Etto's
    # Tweaks. Parity (and -Strict) switches them off in addonlist.txt; Standard only warns. -KeepLocalAddons keeps them.
    $ettoNames = @(@($m.localPack.files) | Where-Object { $_ } | ForEach-Object { "$($_.name)".ToLower() })
    $ownLocal = @(Get-OwnLocalAddons $ettoNames)
    $localOff = @()
    if ($ownLocal.Count) {
        $offNow = ($Parity -or $Strict) -and -not $KeepLocalAddons
        Say "`nYour own local add-ons ($($ownLocal.Count), in left4dead2\addons\, not from the Workshop): they load above every Workshop item and override the server's add-ons." 'Magenta'
        foreach ($l in $ownLocal) {
            $why = @()
            try {
                $files = [EttoSteam]::VpkFiles($l.path)
                if ($files | Where-Object { $_ -match '^models/survivors/anim_' -or $_ -match '/xdreanims/' }) { $why += 'replaces survivor ANIMATIONS (this exact kind of mod crashed players on this server)' }
                $mo = @($files | Where-Object { $_ -match '^missions/(.+\.txt)$' -and $reqMissions.ContainsKey($Matches[1].ToLower()) })
                if ($mo) { $why += "overrides a server campaign's mission file ($($mo -join ', '))" }
                if ($files -contains 'particles/particles_manifest.txt') { $why += 'replaces the particle list (Workshop particle effects can go missing)' }
            } catch { $why += "couldn't be read ($($_.Exception.Message))" }
            Say "  ! $($l.name)$(if ($why) {"  - $($why -join '; ')"})" 'Magenta'
        }
        if ($offNow) {
            $localOff = @($ownLocal | ForEach-Object { $_.name })
            Say "  Will SWITCH THEM OFF for Etto's setup (the files stay in addons\; turn one back on in the game's Add-ons menu, or Restore.cmd). Keep them with -KeepLocalAddons." 'Yellow'
        } elseif ($Parity -or $Strict) { Say '  -KeepLocalAddons given: left on.' 'DarkCyan' }
        else { Say '  Not changed. Parity.cmd switches them off; if you crash or things look wrong on the server, try without them.' 'DarkCyan' }
    }
    $loose = @()
    $lg = Join-Path $game 'left4dead2'
    if (@(Get-ChildItem (Join-Path $lg 'models\survivors') -Filter 'anim_*.mdl' -File -ErrorAction SilentlyContinue).Count) { $loose += 'left4dead2\models\survivors\anim_*.mdl (loose survivor ANIMATIONS - the crash kind)' }
    if (Test-Path -LiteralPath (Join-Path $lg 'particles\particles_manifest.txt')) { $loose += 'left4dead2\particles\particles_manifest.txt (loose particle list - Workshop particle effects can go missing)' }
    if (@(Get-ChildItem (Join-Path $lg 'missions') -Filter '*.txt' -File -ErrorAction SilentlyContinue).Count) { $loose += 'left4dead2\missions\*.txt (loose mission files - can break campaign names and map lists)' }
    if ($loose) {
        Say "`nLoose files in your game folder override every add-on (not changed - move them out if you have problems):" 'Magenta'
        foreach ($x in $loose) { Say "  ! $x" 'Magenta' }
    }

    # ---- Etto's local add-ons (Parity only; $lp was planned above, before the subscriptions) ----
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

    # ---- game config for Etto's server (Parity + hand-off folder only) ----
    $cp = $null; $cfgWork = $false
    if ($NoConfig -and -not $Parity) { Say "`n-NoConfig only applies to Parity.cmd (-Parity); ignored." 'Yellow' }
    if ($Parity -and -not $NoConfig) {
        $addr = Get-ServerAddress
        if ($addr) {
            Say "`nChecking your connection to Etto's server (10-25 s)..." 'Cyan'
            $link = Test-ServerLink $addr
            if ($link.ok) { Say ("  ping {0:N0} ms, jitter {1:N1} ms, lost {2}/{3}" -f $link.median, $link.jitter, $link.lost, $link.sent) }
            else { Say "  The server didn't answer (is it up?). Using the safe settings." 'Yellow' }
            $cp = Get-ConfigPlan $cfgDir $addr $link
            $chg = @(Get-ConfigChanges $cp)
            $cfgWork = $chg.Count -gt 0
            Say "  Net settings: rate 100000, 100 updates/commands per second, interp ratio $($cp.ratio) ($($cp.why))."
            foreach ($n in $cp.notes) { Say "  Note: $n" 'Yellow' }
            if ($cfgWork) { Say "  Will WRITE: $(@($chg | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')" 'Green' } else { Say '  Game config already up to date.' 'Green' }
        }
    }

    # ---- Steam launch option -heapsize (all modes; the manifest's heapsizeKB) ----
    $heapTok = $null; $heapCfg = $null; $heapWork = $false
    if ($m.heapsizeKB -and [int]$m.heapsizeKB -gt 0 -and $NoLaunchOption) { Say "`nLaunch option: -NoLaunchOption given, -heapsize left alone." 'DarkCyan' }
    elseif ($m.heapsizeKB -and [int]$m.heapsizeKB -gt 0) {
        $heapTok = "-heapsize $([int]$m.heapsizeKB)"
        $heapCfg = Get-ActiveUserConfig
        $lo = if ($heapCfg) { Get-LaunchOptionsText $heapCfg } else { $null }
        if ($null -eq $lo) {
            Say "`nLaunch option: couldn't find Left 4 Dead 2 in your Steam settings (launch the game once, then run this again)." 'Yellow'; Show-HeapsizeManual $heapTok
        } elseif ($lo -match '(^|\s)-heapsize(\s|=|$)') {
            Say "`nLaunch options: -heapsize already set." 'Green'
        } else {
            $heapWork = $true
            Say "`nWill ADD the Steam launch option $heapTok for Left 4 Dead 2 (a bigger model/sound cache, so sound doesn't cut out on big maps). Steam closes for a moment to save it and starts again." 'Green'
        }
    }

    if ($DryRun) { Say "`nDry run - nothing changed."; return }
    if (-not $add -and -not $remove -and $cycle.Count -eq 0 -and -not $lpWork -and -not $cfgWork -and -not $heapWork -and -not $localOff.Count) { Say "`nNothing to do."; return }
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
    if ($cp) {
        # marker first, so Restore can clean up even if a write below fails half-way
        @('config') + @($cp.keys) | Set-Content (Join-Path $snapDir 'cfg_written.txt') -Encoding ASCII
        if ($cfgWork) {
            Say "`nWriting the game config:" 'Cyan'
            try { Write-ConfigPlan $cp $snapDir }
            catch { Say "  Couldn't write the game config ($($_.Exception.Message)). Everything else is done." 'Yellow' }
        }
    }
    if ($lp) { Enable-LocalAddons @(@($lp.current) + @($lp.install) | ForEach-Object { $_.name } | Where-Object { Test-Path -LiteralPath (Join-Path $localDir $_) }) }
    # (v9) a parityLocal item added in this run, or whose file this run tried to install, that still lacks its file
    # (e.g. the install failed); items warned about in the plan above aren't repeated
    $lpTried = @(if ($lp) { @($lp.install) | Where-Object { $_ } | ForEach-Object { "$($_.name)".ToLower() } })
    foreach ($it in @($m.parityLocal | Where-Object { $_ })) {
        $nid = [uint64]"$($it.id)"
        if ($after -contains $nid -and ($add -contains $nid -or $lpTried -contains "$($it.needsLocal)".ToLower()) -and -not (LocalFixReady $it $null)) {
            Say "`nNote: $($it.label) ($($it.id)) is subscribed, but $($it.needsLocal) isn't in place, so it misses Etto's texture fixes. Get a fresh pack from Etto, or run Restore.cmd." 'Magenta'
        }
    }
    if ($localOff.Count) {
        $localOff | Set-Content (Join-Path $snapDir 'local_switched_off.txt') -Encoding UTF8
        Disable-LocalAddons $localOff
        Say "`nSwitched off your own local add-ons: $($localOff -join ', ')" 'Green'
    }
    Say "`naddonlist.txt updated: required items enabled." 'Green'
    # before the "Done" lines: a player who starts the game while Steam is still closing would lose the edit
    if ($heapWork) {
        Say "`nSetting the Steam launch option ${heapTok}:" 'Cyan'
        # record first, so Restore can take it out again even if Steam's restart goes wrong
        Copy-Item -LiteralPath $heapCfg (Join-Path $snapDir 'localconfig.vdf') -Force
        "$heapCfg`t$heapTok" | Set-Content (Join-Path $snapDir 'heapsize_added.txt') -Encoding UTF8
        if (Set-HeapsizeOption $heapCfg $heapTok $true) { Say "  added $heapTok to Left 4 Dead 2's launch options." 'Green' }
        else { Remove-Item (Join-Path $snapDir 'heapsize_added.txt') -ErrorAction SilentlyContinue; Show-HeapsizeManual $heapTok }
    }
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
    if (-not $script:SteamApiDown) { [EttoSteam]::SteamAPI_Shutdown() }
}
