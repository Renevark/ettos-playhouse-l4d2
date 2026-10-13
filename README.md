# Etto's Playhouse: L4D2 Workshop sync

Keeps your Left 4 Dead 2 Workshop subscriptions compatible with Etto's Playhouse server: the campaigns it runs, the
survivor-set fix, and none of the add-ons known to crash on it.

## Use

1. Start Steam. **Close Left 4 Dead 2.**
2. Double-click **`Sync.cmd`**. Review the list it prints, then answer `y`.
3. Launch Left 4 Dead 2 once (it cleans up removed add-ons), quit, then launch again and play.

Run it again any time. It always reads the current list from `manifest.json` in this repo, so you never need a new copy of the script
unless it tells you one is available.

### What it changes (Standard mode, the default)

- **Subscribes** to every add-on the server requires that you're missing.
- **Unsubscribes** only add-ons this list names: retired items (replaced by something newer) and known crash-causers. It shows each one with the reason.
- Puts the **Survivor Set Patch** first in your add-on load order and switches on the required add-ons.
- **Doesn't touch anything else you're subscribed to.** It only *warns* (doesn't remove) if one of your other add-ons:
  - replaces survivor animations (the kind of mod that crashed players here), or
  - overrides one of the server's campaign mission files, or
  - contains maps the server already gets from another add-on.

### Other modes

| Run | Does |
|---|---|
| `Sync.cmd -DryRun` | Shows what it would do and changes nothing |
| `Sync.cmd -Strict` | Makes your subscriptions match this list **exactly** (required + recommended). Use it if you keep crashing. |
| `Restore.cmd` | Undoes the most recent sync: resubscribes what it removed and restores your `addonlist.txt` |

Every run that changes something first saves a snapshot to `Documents\EttosPlayhouse\backups\`. `Restore.cmd -Backup <folder>`
restores an older one. Anything that was removed is downloaded again by Steam the next time you launch the game.

## How it works

`EttoSync.ps1` runs in 32-bit Windows PowerShell and loads the `steam_api.dll` that ships with **your own** Left 4 Dead 2 install. It
calls the same Steamworks functions the Workshop "Subscribe" button uses, as the account logged in to your Steam client. Nothing
else is downloaded or installed. `manifest.json` is data only (Workshop IDs and labels); the script validates it and never executes
anything from it.

While it runs, Steam briefly shows you as "playing Left 4 Dead 2".

## For maintainers

Edit `manifest.json`:

- `required` / `recommended` / `retired` / `knownBad`: lists of `{ "id": "<workshop id>", "label": "..." }`. `knownBad` entries also take a `"reason"`.
- `loadFirst`: the ID that must be first in `addonlist.txt` (the survivor-set patch).
- `latestScript`: bump it when `EttoSync.ps1` changes, so older copies tell players to update.

GitHub caches raw files for a few minutes, so players see an edit after roughly 5 minutes.
