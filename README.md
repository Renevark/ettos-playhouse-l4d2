# Etto's Playhouse: L4D2 Workshop sync

Keeps your Left 4 Dead 2 Workshop subscriptions compatible with Etto's Playhouse server: the campaigns it runs, the
survivor-set fix, and none of the add-ons known to crash on it.

## Use

1. Start Steam. **Close Left 4 Dead 2.**
2. Double-click **`Sync.cmd`**. Review the list it prints, then answer `y`.
3. If it says add-ons still need downloading: launch Left 4 Dead 2 and **wait at the main menu until the add-on downloads finish**
   (Left 4 Dead 2 downloads Workshop items itself when it starts), then quit.
4. Launch the game and play. The load order is already set by the sync; the game applies it at launch.

Run it again any time. It always reads the current list from `manifest.json` in this repo, so you never need a new copy of the script
unless it tells you one is available.

### What it changes (Standard mode, the default)

- **Subscribes** to every add-on the server requires that you're missing.
- **Unsubscribes** only add-ons this list names: retired items (replaced by something newer) and known crash-causers. It shows each one with the reason.
- Puts the **Survivor Set Patch** first in your add-on load order (by re-subscribing it, see below) and switches on the required add-ons.
- **Doesn't touch anything else you're subscribed to.** It only *warns* (doesn't remove) if one of your other add-ons:
  - replaces survivor animations (the kind of mod that crashed players here), or
  - overrides one of the server's campaign mission files, or
  - contains maps the server already gets from another add-on.

### Other modes

| Run | Does |
|---|---|
| `Sync.cmd -DryRun` | Shows what it would do and changes nothing |
| `Sync.cmd -Strict` | Makes your subscriptions match this list **exactly** (required + recommended). Use it if you keep crashing. |
| **`Parity.cmd`** | **Optional:** also installs Etto's own client setup (weapons, sounds, textures, survivor models; about 1.5 GB) **in the exact same load order**, so your game looks and sounds the same as Etto's. Doesn't remove anything of yours. |
| `Parity.cmd -Strict` | An exact mirror of Etto's setup: everything not in it is unsubscribed (snapshot first; `Restore.cmd` undoes it). |
| `Restore.cmd` | Undoes the most recent sync: resubscribes what it removed and restores your `addonlist.txt` |

### Load order (why the script re-subscribes things)

Left 4 Dead 2 orders add-ons by **when you subscribed to them, newest first**. When two add-ons contain the same file, the
higher one wins. The game rebuilds `addonlist.txt` in that order at every launch, so editing the file doesn't stick.
To put the Survivor Set Patch on top, or to reproduce Etto's order in `Parity.cmd`, the script unsubscribes and
re-subscribes add-ons one at a time in the right sequence. Nothing is re-downloaded, and the new order applies at your next launch.

Every run that changes something first saves a snapshot to `Documents\EttosPlayhouse\backups\`. `Restore.cmd -Backup <folder>`
restores an older one. Anything that was removed is downloaded again the next time you launch the game.

## How it works

`EttoSync.ps1` runs in 32-bit Windows PowerShell and loads the `steam_api.dll` that ships with **your own** Left 4 Dead 2 install. It
calls the same Steamworks functions the Workshop "Subscribe" button uses, as the account logged in to your Steam client. Nothing
else is downloaded or installed. `manifest.json` is data only (Workshop IDs and labels); the script validates it and never executes
anything from it.

While it runs, Steam briefly shows you as "playing Left 4 Dead 2".

## For maintainers

Edit `manifest.json`:

- `required` / `recommended` / `retired` / `knownBad`: lists of `{ "id": "<workshop id>", "label": "..." }`. `knownBad` entries also take a `"reason"`.
- `loadFirst`: the ID that must have top priority (the survivor-set patch). It is always subscribed last.
- `parity` (`{ "id", "label", "mb" }`) and `loadOrder` (top → bottom IDs): Etto's optional client setup, used by `Parity.cmd`.
  Regenerate both from Etto's PC with `python -I tools/gen_parity.py` after changing the add-ons, after a game launch
  so `addonlist.txt` reflects the real order.
- `latestScript`: bump it when `EttoSync.ps1` changes, so older copies tell players to update.

GitHub caches raw files for a few minutes, so players see an edit after roughly 5 minutes.
