# Treemap

A native macOS app that shows what fills your disk, then helps you reclaim it. The scan
runs in parallel and the treemap (drawn with Metal) reflows live while sizes arrive. Pick
items, collect them in the Reclaim tray, and move them to the Trash in one step.

Requires macOS 26 (Tahoe). Swift 6, no third-party dependencies, no sandbox.

![Treemap screenshot](docs/screenshot.png) <!-- placeholder: add docs/screenshot.png -->

## Install and build

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
# optional: cp .env.example .env to set BUNDLE_ID / CODESIGN_IDENTITY (default: ad hoc "-")
make app               # builds build/Treemap.app
make run               # build and launch; ARGS=/some/folder opens a folder directly
make dmg               # build/Treemap.dmg with an /Applications link
make install           # copies the app to /Applications
make test              # swift test (Core library)
```

`make notarize` signs with a Developer ID certificate, notarizes the disk image and staples
the ticket. It needs `NOTARY_IDENTITY` and `NOTARY_PROFILE` in `.env` (see `.env.example`)
and stops with a message if they are missing.

## Command line

`App/Resources/treemap` is a small shell script bundled in the app. Choose
**Treemap > Install Command Line Tool…** to link it to `/usr/local/bin/treemap` (or
`~/.local/bin/treemap` when `/usr/local/bin` is not writable; no admin prompt).

```sh
treemap            # current folder
treemap ~/Library /Volumes/Backup
```

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Click, Shift/Cmd-click | Select, toggle multi-select |
| Arrow keys | Move the selection between sibling cells |
| Return, double-click | Zoom into the selected folder |
| Cmd-Up, Esc | Zoom out |
| Cmd-[ , Cmd-] , swipe | Back, forward |
| Delete | Add selection to the Reclaim tray |
| Cmd-Delete | Move selection (or tray) to the Trash, with confirmation |
| Space | Quick Look |
| Cmd-Return | Open |
| Cmd-Shift-R | Reveal in Finder |
| Cmd-Option-C | Copy path(s) |
| Cmd-R | Rescan selection or current folder |
| Cmd-Shift-. | Hide hidden items from the drawing (totals do not change) |
| Cmd-Option-I | Show or hide the inspector |
| Cmd-N, Cmd-O | New window (start window), open folder |

One root per window; windows can be grouped as native tabs. Opening a folder that is
already open focuses its window.

## How sizes are counted

- Size is allocated space on disk (`st_blocks * 512`), not the logical file size.
- Every inode counts once. Hard links to the same file are not added twice.
- A scan stays on one volume, like `du -x`. Other volumes appear as grey leaf cells; open
  them in their own tab.
- Scanning "Macintosh HD" counts the System and Data volumes once (APFS firmlinks).
- Symbolic links are leaves and are never followed.
- Freed space is shown as "up to X": APFS clones and snapshots can share blocks, so
  trashing a file may free less than its size. Nothing is deleted permanently; items go
  to the Trash.
- The map updates by itself when files change (FSEvents); changed folders are rescanned.

## Full Disk Access

macOS protects folders such as Mail, Safari and Messages. Without Full Disk Access Treemap
cannot read them; they show as hatched "Unreadable" cells and a banner offers a shortcut to
System Settings > Privacy & Security > Full Disk Access. Grant access, then restart Treemap.

## Layout

- `Sources/TreemapCore`: scanner, tree, layout, file watcher (no AppKit).
- `App/`: SwiftUI + AppKit app, Metal map view (`project.yml` is the XcodeGen spec).
- `Sources/make-icon`: draws the app icon with TreemapCore's layouter (`make icon`).
- `PLAN.md`: product and design decisions.

## License

MIT, see [LICENSE](LICENSE).
