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
    [string]$ManifestFile
)

$ScriptVersion = 2
$ErrorActionPreference = 'Stop'

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
    foreach ($o in @($m.loadOrder)) { if ($o -and "$o" -notmatch '^\d{6,12}$') { Fail "Manifest loadOrder has an invalid Workshop id '$o'." } }
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
function Update-AddonList([uint64]$first, [uint64[]]$enable, [uint64[]]$drop) {
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
    if ($first) {
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
        Say "Restoring snapshot $(Split-Path $dir -Leaf): resubscribe $($add.Count), unsubscribe $($remove.Count), restore addonlist.txt" 'Cyan'
        if ($DryRun) { Say 'Dry run - nothing changed.'; return }
        if (-not $Yes -and (Read-Host 'Proceed? (y/n)') -notmatch '^y') { return }
        Apply-Changes $add $remove
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
    $first = if ($m.loadFirst) { [uint64]"$($m.loadFirst)" } else { [uint64]0 }
    $removeSet = @(Ids $m.retired) + @(Ids $m.knownBad)
    if ($Strict) { $removeSet += @($before | Where-Object { $want -notcontains $_ -and $rec -notcontains $_ }) }
    $remove = @($before | Where-Object { $removeSet -contains $_ } | Select-Object -Unique)
    $add = @($want | Where-Object { $before -notcontains $_ -and $_ -ne $first } | Select-Object -Unique)
    if ($first -and $before -notcontains $first) { $add += $first }   # load-first item is subscribed last

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
    if ($first -and $cycle.Count -eq 0 -and ($add.Count -gt 0 -or ($gameOrder.Count -gt 0 -and $gameOrder[0] -ne $first))) { $cycle = @($first) }
    if ($first -and $cycle.Count -gt 0) { $cycle = @($cycle | Where-Object { $_ -ne $first }) + @($first) }   # load-first is always last = top

    Say "`nSubscribed now: $($before.Count) items.  Mode: $(if ($Strict) {'STRICT'} else {'Standard'})$(if ($Parity) {' + PARITY'})"
    if ($add) { Say "`nWill SUBSCRIBE ($($add.Count)):" 'Green'; foreach ($i in $add) { Say "  + $i  $(Label $m $i)" } }
    if ($remove) { Say "`nWill UNSUBSCRIBE ($($remove.Count)):" 'Yellow'; foreach ($i in $remove) { $l = Label $m $i; $r = (@($m.knownBad) | Where-Object { $_ -and [uint64]"$($_.id)" -eq $i }).reason; Say "  - $i  $l$(if ($r) {"  ($r)"})" } }
    $missingRec = @($rec | Where-Object { $before -notcontains $_ })
    if ($missingRec -and -not $Strict) { Say "`nRecommended (optional, not changed):" 'DarkCyan'; foreach ($i in $missingRec) { Say "  ? https://steamcommunity.com/sharedfiles/filedetails/?id=$i  $(Label $m $i)" } }
    if (-not $add -and -not $remove) { Say "`nSubscriptions already match." 'Green' }
    if ($cycle.Count -eq 1) { Say "`nLoad order: will re-subscribe $($cycle[0]) ($(Label $m $cycle[0])) so it loads first (takes effect at your next launch)." 'Green' }
    elseif ($cycle.Count -gt 1) { Say "`nLoad order: will (re)subscribe $($cycle.Count) add-ons one by one in Etto's order (about $([int]($cycle.Count * 1.6)) s; takes effect at your next launch). Nothing is re-downloaded." 'Green' }
    elseif ($first) { Say "`nLoad order OK: $first is already on top." 'Green' }
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
        if (Test-Path $f) { foreach ($p in [EttoSteam]::VpkFiles($f)) { if ($id -ne $first -and $p -match '^missions/(.+\.txt)$') { $reqMissions[$Matches[1].ToLower()] = $id }; if ($p -match '^maps/(.+)\.bsp$') { $reqMaps[$Matches[1].ToLower()] = $id } } }
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

    if ($DryRun) { Say "`nDry run - nothing changed."; return }
    if (-not $add -and -not $remove -and $cycle.Count -eq 0) { Say "`nNothing to do."; return }
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
    Update-AddonList $first $want $remove
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
