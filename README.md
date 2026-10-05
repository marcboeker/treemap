<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="160" alt="Treemap app icon">
</p>

<h1 align="center">Treemap</h1>

<p align="center">
  <strong>See what fills your disk. Then get it back.</strong>
</p>

---

Your Mac says the disk is almost full, but you do not know why. You did not save 200 GB
of files. So where did the space go?

Usually it is not one big file. It is the stuff you forgot about:

- **Local LLM models.** You tried Ollama, LM Studio and a few Hugging Face models. Each
  tool keeps its own copy, in its own hidden folder. Now 80 GB of model weights sit on
  your disk, and you use one of them.
- **Caches that never get cleaned up.** Browsers, Xcode, Docker, package managers and
  chat apps all write caches. Many apps forget to delete them. Some never stop growing.
- **Old leftovers.** Installers in Downloads, simulator images, backups of a phone you
  sold two years ago, a `node_modules` folder from a project you deleted.

Finder does not help much here. It hides most of these folders and does not show folder
sizes. Treemap shows all of it in one picture, so you can find the large items in seconds
and delete them.

<p align="center">
  <video src="assets/demo.mp4" width="800" autoplay loop muted playsinline>
    <a href="assets/demo.mp4">Watch the demo (demo.mp4)</a>
  </video>
</p>

## How it works

Each folder is a rectangle. Each file inside it is a smaller rectangle. The bigger the
rectangle, the more space it uses. You do not have to read a list: the large items are
the large blocks on the screen.

1. Open a disk or a folder.
2. Look for the big blocks. Click to see what they are, double-click to go deeper.
3. Collect the items you do not need in the **Reclaim tray**.
4. Move them to the Trash in one step.

## Features

- **Fast scan.** Treemap reads your disk in parallel. The map is ready to use while the
  scan is still running, and it fills in live.
- **One picture of everything.** Hidden folders, `~/Library`, caches and app data are all
  visible. Nothing is skipped because Finder thinks you should not see it.
- **Reclaim tray.** Collect items from different folders, check the total, then delete
  them all together. Treemap tells you how much space you get back.
- **Safe delete.** Items go to the Trash, never straight into oblivion. You confirm first,
  and you can still put things back.
- **Honest numbers.** Treemap counts the real space on disk. Files that share space (hard
  links, APFS clones) are not counted twice, so the totals do not lie to you.
- **Live updates.** When files change on disk, the map updates by itself. No need to
  scan again.
- **Quick Look and Finder.** Press Space to preview a file. Reveal it in Finder, open it,
  or copy its path.
- **Keyboard friendly.** Arrow keys to move, Return to zoom in, Esc to zoom out, Delete
  to add to the tray.
- **Command line.** Type `treemap ~/Downloads` in Terminal to open a folder directly
  (install it from the **Treemap** menu).
- **Native Mac app.** Made for macOS, fast on Apple silicon, no extra dependencies.

## Install

Treemap needs **macOS 26 (Tahoe)** or later.

With [Homebrew](https://brew.sh):

```sh
brew tap marcboeker/treemap https://github.com/marcboeker/treemap
brew install --cask treemap
```

Or download `Treemap-macos.zip` from the
[latest release](https://github.com/marcboeker/treemap/releases/latest), unzip it and
move `Treemap.app` to your Applications folder.

## First run: expect some permission dialogs

macOS protects some of your folders. The first time Treemap scans them, macOS asks you
for permission, sometimes a few times in a row (for example for Desktop, Documents,
Downloads, external disks or data from other apps). This is normal. Treemap only reads
file sizes and names. It does not open or upload your files.

To see everything (Mail, Messages, Safari and other protected app data), give Treemap
**Full Disk Access**. If it is missing, Treemap shows the protected folders as hatched
"Unreadable" blocks and a banner with a shortcut to
**System Settings > Privacy & Security > Full Disk Access**. Turn it on, then restart
Treemap.

## Good to know

- Treemap never deletes a file permanently. Everything goes to the Trash first.
- The space you get back is shown as "up to X". APFS can share data between files and
  snapshots, so the real amount can be a little smaller.
- A scan stays on one disk. Other disks show as grey blocks; open them in their own tab.

## Build from source

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make app       # builds build/Treemap.app
make run       # build and launch
make test      # run the tests
```

## License

MIT, see [LICENSE](LICENSE).
