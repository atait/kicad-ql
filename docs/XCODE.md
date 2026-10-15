# Building and installing with Xcode

This guide assumes you have never used Xcode or Swift. The Xcode project is already set up, so you
only need to sign it, build it and turn it on.

## How the pieces fit

A QuickLook plugin on modern macOS is an **app extension**: a small bundle (`.appex`) that macOS runs
in its own sandboxed process when Finder needs a preview. An extension cannot be installed on its
own. It has to be shipped inside an ordinary app (the **host app**). macOS finds the extension
when the host app is launched for the first time.

```
KiCadQL.app                          ← host app (KiCadQL/), just shows an "installed" window
└── Contents/PlugIns/
    └── KiCadQLPreview.appex         ← spacebar preview   (KiCadQLPreview/PreviewViewController.swift)
              links ↓
        KiCadPCBKit (Swift package) ← parser + renderer, testable without Xcode
```

The host app's `Info.plist` also declares the file type `org.kicad.pcb` for the `.kicad_pcb`
extension. macOS doesn't know this type otherwise, and the extension refers to it by that identifier.

## One-time setup

1. **Install Xcode's components.** Open Xcode once and accept whatever it offers to install. You can
   also run `sudo xcodebuild -runFirstLaunch` in Terminal.
2. **Add your Apple ID.** Go to Xcode ▸ Settings… ▸ Accounts and click **+** ▸ Apple ID. A free Apple ID
   is enough to run this on your own Mac. Xcode will make a "Personal Team" for it.
3. **Open the project.** Double-click `KiCadQL.xcodeproj` (or run `open KiCadQL.xcodeproj`).

### A short tour of the Xcode window

- **Left pane (Navigator):** files. You'll see the folders `KiCadQL` and `KiCadQLPreview`,
  and under **Package Dependencies** the `KiCadPCBKit` package. You can edit the
  package's sources right there.
- **Top bar:** the **scheme** selector (choose `KiCadQL`) and the run destination (`My Mac`). ▶ (⌘R)
  builds and runs the app. ■ (⌘.) stops it.
- **Clicking the blue `KiCadQL` project icon** at the top of the navigator opens the project editor.
  It lists the **targets** (the app and the extension), and each target has tabs such as
  *General*, *Signing & Capabilities* and *Build Settings*.

## Sign the targets

macOS will only load an extension if it is code-signed. Repeat these steps for **both targets**
(`KiCadQL` and `KiCadQLPreview`):

1. Click the blue project icon, then select the target in the TARGETS list.
2. Open the **Signing & Capabilities** tab.
3. Leave **Automatically manage signing** checked and set **Team** to your Personal Team.

Bundle identifiers come from one project-wide build setting, `BUNDLE_ID_PREFIX`, which is currently
`io.github.atait`. The app becomes `io.github.atait.KiCadQL` and the extension
`io.github.atait.KiCadQL.Preview`. To change the prefix, select the project (not a
target), open *Build Settings*, search for `BUNDLE_ID_PREFIX` and edit it. If Xcode says the identifier
is unavailable for your team, change the prefix to something unique.

> Choosing a Team writes your team ID into `project.pbxproj`. That is normal, and a team ID is not
> secret, so it's fine to commit.

## Build, install and enable

1. Press **⌘R**. Xcode builds everything and launches the host app, which shows a small "installed"
   window. Launching it registers the extension with macOS.
2. **Turn the extension on**, if needed: open System Settings ▸ General ▸ Login Items & Extensions,
   scroll to **Quick Look**, and make sure *KiCad PCB Preview* is enabled.
3. **Try it:** select a board in `examples/` in Finder and press Space. From Terminal:

   ```sh
   qlmanage -r                                   # make QuickLook rescan extensions
   qlmanage -p examples/LoomRide-v1.kicad_pcb    # open a preview window
   ```

### Install it permanently

⌘R is for development only. The app it runs lives in `~/Library/Developer/Xcode/DerivedData`, and
QuickLook stops using it once Xcode quits: previews go back to a generic icon even though the
extension is still enabled in System Settings. To keep the preview working all the time, install a
copy:

1. In Xcode, choose Product ▸ **Archive**. This makes a Release build. When the Organizer window
   opens, select the new archive and choose **Distribute App** ▸ **Custom** ▸ **Copy App**, then save
   it somewhere such as the Desktop.
2. Quit any running `KiCadQL`, move the exported `KiCadQL.app` into `/Applications`, and open it once.
   You can quit it right away.
3. Run `qlmanage -r && qlmanage -r cache`, then check that the registered path is now under
   `/Applications`:

   ```sh
   pluginkit -mv -p com.apple.quicklook.preview | grep -i kicad
   ```

After a change you want to keep, repeat these steps to replace the copy in `/Applications`. While you
are developing, ⌘R in Xcode may temporarily take over from the installed copy. Quit Xcode and run
`qlmanage -r` to go back to it.

## The edit → test loop

Most work happens in the renderer, which you can iterate on without QuickLook at all:

```sh
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200
open out.png
swift test --package-path KiCadPCBKit
```

When you want to see the change in Finder:

1. Press ⌘R in Xcode to rebuild and re-register.
2. Run `qlmanage -r && qlmanage -r cache`. This clears cached previews.
3. If an old version is still showing, run `killall -9 KiCadQLPreview` and try
   again. QuickLook keeps extension processes alive for a while.

## Debugging an extension

`print()` output from an extension goes nowhere visible. You have two options:

- **Attach the debugger.** In Xcode, choose Debug ▸ **Attach to Process by PID or Name…**, type
  `KiCadQLPreview` and click Attach. Xcode waits until the process starts. Then press Space on a
  board in Finder. Breakpoints you set (click a line number) will now stop execution.
- **Log.** Add `import os` and `Logger(subsystem: "KiCadQL", category: "preview").error("…")`, then
  watch in Console.app with a filter on `KiCadQL`. Run *Start streaming* first.

## Troubleshooting

| Symptom | Things to check |
| --- | --- |
| Space shows a generic file icon | Did the app launch at least once? Is the extension enabled in System Settings? Is it listed by `pluginkit -mv -p com.apple.quicklook.preview \| grep -i kicad`? |
| Still generic after that | `mdls -name kMDItemContentType board.kicad_pcb` should print `org.kicad.pcb`. If it prints `dyn.…`, the type declaration hasn't been picked up. Relaunch the app, then run `touch board.kicad_pcb`. |
| Works only while Xcode is open | You are running the DerivedData build. Install a copy in `/Applications` (see *Install it permanently*) |
| Preview is stale after a rebuild | `qlmanage -r && qlmanage -r cache`, and `killall -9 KiCadQLPreview` |
| "Signing for … requires a development team" | Set the Team on **both** targets (see above) |
| Build errors mentioning `KiCadPCBKit` | File ▸ Packages ▸ **Reset Package Caches**, then build again |

## Swift in ten lines (enough to read this code)

- `let` is a constant and `var` is a variable. Types come after the name: `let w: CGFloat = 1`.
- `String?` is an *optional*: either a `String` or `nil`. `x?.foo` calls `foo` only if `x` isn't
  nil, and `a ?? b` means "a, or b if a is nil".
- `guard let x = maybeX else { return }` unwraps an optional or exits early. This shows up everywhere
  in the parser.
- `struct` and `enum` are value types (copied), and `class` is a reference type. An `enum` can carry
  data, as in `case atom(String)`.
- `func f(_ a: Int, label b: Int)` is called as `f(1, label: 2)`. Argument labels are part of the
  name.
- `{ x in x * 2 }` is a closure (lambda), and `$0` is its first argument.
- `throws`, `try` and `do { } catch { }` handle errors. `async` and `await` mark asynchronous code.
- `public` makes something visible outside its module. The package has to mark things the
  extension uses as `public`.

## Later: sharing it with others

To give the app to other people without Gatekeeper warnings, you need a paid Apple Developer
account. You sign the app with a *Developer ID* certificate and have it notarized: Product ▸
Archive ▸ Distribute App ▸ **Direct Distribution**. Without a paid account, people can still build
it themselves from source with these instructions.
