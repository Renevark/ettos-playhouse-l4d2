# Etto's Playhouse: L4D2 Workshop sync

Keeps your Left 4 Dead 2 Workshop subscriptions compatible with Etto's Playhouse server: the campaigns it runs, the
survivor-set fix, and none of the add-ons known to crash on it.

## Use

1. Start Steam. **Close Left 4 Dead 2.**
2. Double-click **`Sync.cmd`**. Review the list it prints, then answer `y`. The first run of script v7 also closes Steam for
   a moment to add a launch option (see below) and starts it again; **keep the window open until it says Done**. Steam may
   ask you to log in again.
3. If it says add-ons still need downloading: launch Left 4 Dead 2 and **wait at the main menu until the add-on downloads finish**
   (Left 4 Dead 2 downloads Workshop items itself when it starts), then quit.
   Don't subscribe to big add-ons while you're in a game: the game loads the whole download into memory at once, and a large
   campaign (Vltava is 813 MB) can crash it with OUT OF MEMORY. Subscribe with the game closed, or at the main menu right after launch.
4. Launch the game and play. The load order is already set by the sync; the game applies it at launch.

Run it again any time. It always reads the current list from `manifest.json` in this repo, so you never need a new copy of the script
unless it tells you one is available.

### What it changes (Standard mode, the default)

- **Subscribes** to every add-on the server requires that you're missing.
- **Unsubscribes** only add-ons this list names: retired items (replaced by something newer) and known crash-causers. It shows each one with the reason.
- Puts the **Survivor Set Patch** first in your add-on load order (by re-subscribing it, see below) and switches on the required add-ons.
- The required add-ons include 27 **custom infected** (about 840 MB to download the first time). Their scripts also spawn
  them in your own local and hosted games, and a few of them restyle how all common infected look.
- Adds **`-heapsize 327680`** to Left 4 Dead 2's Steam launch options (script v7). The game keeps model meshes and sounds in
  one cache, 256 MB by default; on Etto's server every model is loaded up front, so on big maps sounds get pushed out and cut
  in and out. This raises the cache to 320 MB. Steam rewrites its settings when it exits, so the script closes Steam, edits
  only the `LaunchOptions` of Left 4 Dead 2 (app 550) in `Steam\userdata\<your id>\config\localconfig.vdf`, and starts Steam
  again. Skip it with `-NoLaunchOption`. If it can't (Steam won't close, say), it tells you how to add it yourself.
- **Your own local add-ons** (script v8): `.vpk` files directly in `left4dead2\addons\` that aren't Etto's load *above*
  every Workshop item, so they override the server's add-ons. Every run lists them with the same crash checks as below;
  Standard only warns, while `Parity.cmd` and `-Strict` switch them off (every such run does it again, unless you add
  `-KeepLocalAddons`). Risky loose files in the game folder (`models\survivors\anim_*.mdl`,
  `particles\particles_manifest.txt`, `missions\*.txt`) are reported too, never changed.
- **Doesn't touch any other add-on you're subscribed to.** It only *warns* (doesn't remove) if one of your other add-ons:
  - replaces survivor animations (the kind of mod that crashed players here), or
  - overrides one of the server's campaign mission files, or
  - contains maps the server already gets from another add-on.

### Other modes

| Run | Does |
|---|---|
| `Sync.cmd -DryRun` | Shows what it would do and changes nothing |
| `Sync.cmd -Strict` | Makes your subscriptions match this list **exactly** (required + recommended), and switches your own local add-ons off (`-KeepLocalAddons` keeps them). Use it if you keep crashing. |
| **`Parity.cmd`** | **Optional:** also installs Etto's own client setup (weapons, sounds, textures, survivor models; about 2 GB) **in the exact same load order**, so your game looks and sounds the same as Etto's. Doesn't remove anything of yours, but switches your own local add-ons (in `addons\`) off in `addonlist.txt`, since they'd override Etto's setup; the files stay, and the game's Add-ons menu or `Restore.cmd` turns them back on (`-KeepLocalAddons` leaves them on). With Etto's local pack next to it, it also installs Etto's non-Workshop tweaks (see below); a same-named file already in `addons\` is replaced (the old copy goes into the snapshot). |
| `Parity.cmd -Strict` | An exact mirror of Etto's setup: everything not in it is unsubscribed (snapshot first; `Restore.cmd` undoes it). |
| `Restore.cmd` | Undoes the most recent sync: resubscribes what it removed, restores your `addonlist.txt`, takes back any local-pack files it installed and the game settings it wrote, and removes the `-heapsize` launch option if that run added it (closing Steam for a moment). It only undoes the latest snapshot: to undo an older run use `Restore.cmd -Backup <folder>`. After a Restore, run `Sync.cmd -NoLaunchOption` if you don't want the launch option back. |

### Etto's local pack (Parity only)

A few of Etto's tweaks aren't on the Workshop because they're modified copies of other people's add-ons (dimmer HD Lighting
glows, lighter gun/skin textures, the ekgHUD patch, and `etto_lite_ci.vpk`: smaller copies of the custom infected,
campaign, survivor and Valve model textures). Left 4 Dead 2 is a 32-bit game that can only use 4 GB of memory, and with
the custom infected the full-size textures don't fit on big maps, which then crash while loading; these capped textures
are what keep it under the limit. They are made for Etto's exact add-on set, which is why they come with Parity.
The pack zip is about 580 MB. Etto hands them out personally as `EttosPlayhouse_LocalPack.zip`; this repo
only lists their names, sizes and SHA-256s in `manifest.json` (`localPack`). Put the zip next to `Parity.cmd` (or pass
`-LocalPack <path>`): Parity checks each file against its SHA-256, copies it into `left4dead2\addons\` and switches it on.
Anything in the zip that isn't on the list is ignored. If a file is outdated, Parity says so; ask Etto for a fresh pack.

### Game settings for Etto's server (Parity, Etto's hand-off folder only)

When Etto's hand-off folder also holds `EttosPlayhouse_Server.txt` (the server address; it isn't in this repo), `Parity.cmd`
sets your game up for that server. Skip it with `Parity.cmd -NoConfig`.

- It checks your connection with 24 server-browser queries (10-25 seconds) and picks your interpolation from it.
- `cfg\etto_net.cfg`: `rate 100000`, `cl_updaterate 100`, `cl_cmdrate 100`, `cl_interp 0`, and `cl_interp_ratio` 1, or 2
  if your connection loses packets or is jittery. The server runs at 100 tick and allows ratio 1-2 (10-20 ms). Common
  infected aren't lag compensated, so a low ratio is what keeps them hittable.
- A marked block at the end of `cfg\autoexec.cfg`: the console on, the server's ping on mouse 5, **F8 joins the server**
  (after loading `etto_net`), and `exec etto_net` at launch. Keys you've already bound to something else are left alone.
- Frame rate: the game sends at most one command per frame, so 100 commands a second need 100 fps. If your own cfg
  files set `fps_max` between 1 and 99, the block raises it to 100 (0 = unlimited and 100+ are left alone; removing the
  block puts yours back). Parity warns you, without changing anything, when Steam launch options set `+fps_max` below
  100 (those run later and win) or when VSync is on with a monitor below 100 Hz.
- A marked block in `cfg\listenserver.cfg`: the game's stock settings whenever you host a local game (those run at 30
  tick, where the server values feel wrong). If you then join the server some other way than F8 in the same session,
  you keep the local values until you press F8 or restart the game.
- `Restore.cmd` removes the blocks, `etto_net.cfg`, and the F8 / mouse 5 binds Parity added (the game also saves those in
  `config.cfg`); your own lines stay as they are. Settings the game saved by itself (the console switch, 100 updates/commands
  per second) stay until you change them in Options or the console.

### Load order (why the script re-subscribes things)

Left 4 Dead 2 orders add-ons by **when you subscribed to them, newest first**. When two add-ons contain the same file, the
higher one wins. The game rebuilds `addonlist.txt` in that order at every launch, so editing the file doesn't stick.
To put the Survivor Set Patch on top, or to reproduce Etto's order in `Parity.cmd`, the script unsubscribes and
re-subscribes add-ons one at a time in the right sequence. Nothing is re-downloaded, and the new order applies at your next launch.

Every run that changes something first saves a snapshot to `Documents\EttosPlayhouse\backups\`. `Restore.cmd -Backup <folder>`
restores an older one. Anything that was removed is downloaded again the next time you launch the game. When a run adds the
launch option, its snapshot also keeps a copy of your `localconfig.vdf` (your personal Steam settings), so don't share
your backups folder.

## How it works

`EttoSync.ps1` runs in 32-bit Windows PowerShell and loads the `steam_api.dll` that ships with **your own** Left 4 Dead 2 install. It
calls the same Steamworks functions the Workshop "Subscribe" button uses, as the account logged in to your Steam client. Nothing
else is downloaded or installed. `manifest.json` is data only (Workshop IDs and labels); the script validates it and never executes
anything from it.

While it runs, Steam briefly shows you as "playing Left 4 Dead 2".

## Weapon pool (archived 2026-10-15)

> **Archived, not in use.** The idea worked server-side, but L4D2's client re-applies the weapon script's viewmodel inside
> its own prediction on every shot, reload and deploy, so the first-person gun flickered back to the slot's normal model
> and played its reload sounds. Fixing that needs client code, so the experiment was stopped. The tools are kept for
> reference; you don't need them.

The idea: the server gives each spawned gun of a class a random look from a pool of Workshop gun mods (model, animations,
its own reload sounds). Because gun mods all overwrite the same stock files, each variant has to live at its own path:
`tools/pool_build.py` builds that from **your own** subscribed copies (nothing third-party is redistributed here).

- `tools/pool.json` lists the variants per slot (Workshop IDs). Subscribe to them, launch L4D2 once so they download, then
  **disable** them in the in-game Add-ons list (they're only used as sources).
- `python -I tools/pool_build.py <out_dir>` builds the tree; pack it with L4D2's `bin\vpk.exe` into `addons\etto_pool.vpk`.
  New sounds also need a `sound\sound.cache` (built in-game with `snd_buildsoundcachefordirectory <dir>`).
- Model output is deterministic; `tools/pool_model_hashes.txt` lists the expected hashes (the server checks the same).
- Optional: put Microsoft's `texconv.exe` ([DirectXTex releases](https://github.com/microsoft/DirectXTex/releases)) in
  `tools/bin/` to re-encode uncompressed textures as DXT (much less memory; scope glass is left alone). Without it,
  textures are copied as they are.
- Set `L4D2_DIR` if Left 4 Dead 2 isn't in the default Steam library.

The server plugin is unloaded; don't install a pool add-on.

## For maintainers

Edit `manifest.json`:

- `required` / `recommended` / `retired` / `knownBad`: lists of `{ "id": "<workshop id>", "label": "..." }`. `knownBad` entries also take a `"reason"`.
- `loadFirstAll` (script v3+): the IDs that must have top priority, top first: Etto's Playhouse Custom Campaign
  Fixes (mission overrides) and Etto's Playhouse Tweaks and Additions (content that applies on every map). They are
  always subscribed last, in reverse, so they end up on top in this order.
- `loadFirst`: the single top-priority ID read by older scripts (v2). Keep it set to the first `loadFirstAll` entry.
- An add-on that contains `missions/*.txt` is a *mission* add-on: L4D2 only mounts it while one of its own campaigns
  is played. Anything that must apply on every map (models, particles, sounds, script lists) goes in the Tweaks item,
  which has no `missions/`.
- `parity` (`{ "id", "label", "mb" }`) and `loadOrder` (top → bottom IDs): Etto's optional client setup, used by `Parity.cmd`.
  Regenerate both from Etto's PC with `python -I tools/gen_parity.py` after changing the add-ons, after a game launch
  so `addonlist.txt` reflects the real order.
- `localPack` (script v4+): `{ "zip": "<name>.zip", "files": [{ "name", "label", "bytes", "sha256" }] }` for Etto's
  non-Workshop add-ons. `gen_parity.py` refreshes `bytes`/`sha256` from Etto's `addons` folder. Push the manifest
  **before** handing out a new pack zip: friends' `Parity.cmd` checks the zip against the published list.
- `latestScript`: bump it when `EttoSync.ps1` changes, so older copies tell players to update.
- `heapsizeKB` (script v7+): the `-heapsize` value in KB the script makes sure is in Left 4 Dead 2's Steam launch options
  (327680 = 320 MB). Remove the key to stop adding it.

GitHub caches raw files for a few minutes, so players see an edit after roughly 5 minutes.
