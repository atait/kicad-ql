# Releasing

How to make a build that other people can download and open with no warnings. This needs the paid
Apple Developer Program account.

## Why notarize

macOS (Gatekeeper) only opens a downloaded app without complaint if it is signed with a **Developer
ID** certificate and **notarized**: uploaded to Apple, scanned automatically and approved, usually in a
few minutes. A build signed only with *Apple Development* (what ⌘R and a free Apple ID give you) is
for your own Macs. Other people would have to override Gatekeeper in Privacy & Security.

## Make a release

1. Set the version: select the project in Xcode, then for **both targets** go to *General* and set
   **Version** (`MARKETING_VERSION`, e.g. `1.0.0`). Increase **Build** too (`CURRENT_PROJECT_VERSION`).
2. Product ▸ **Archive**. When the Organizer opens, choose **Distribute App** ▸ **Direct
   Distribution** ▸ Distribute. Xcode signs with Developer ID, uploads for notarization, waits, and
   staples the approval ticket to the app. Then click **Export** and save the app.
3. Zip it with `ditto`, which keeps the signature intact (Finder ▸ Compress also works):

   ```sh
   ditto -c -k --keepParent KiCadQL.app KiCadQL.zip
   ```

4. Check it:

   ```sh
   spctl -a -vv KiCadQL.app       # "accepted", "source=Notarized Developer ID"
   shasum -a 256 KiCadQL.zip      # needed for the Homebrew cask
   ```

5. Publish it as a GitHub release, with the zip attached as an asset:

   ```sh
   git tag v1.0.0 && git push origin v1.0.0
   gh release create v1.0.0 KiCadQL.zip --title "KiCad QuickLook 1.0.0" --notes "…"
   ```

   The README's Install section links to the Releases page.

## Homebrew

Homebrew installs apps with a **cask**, not a formula (formulas are for command-line tools built from
source). The quickest route is your own *tap*: a GitHub repo named `homebrew-tap` that holds the cask.

`Casks/kicadql.rb` in `github.com/<you>/homebrew-tap`:

```ruby
cask "kicadql" do
  version "1.0.0"
  sha256 "<shasum of KiCadQL.zip>"

  url "https://github.com/<you>/kicad-ql/releases/download/v#{version}/KiCadQL.zip"
  name "KiCad QuickLook"
  desc "QuickLook previews for KiCad boards and schematics"
  homepage "https://github.com/<you>/kicad-ql"

  depends_on macos: ">= :sonoma"

  app "KiCadQL.app"

  # register the QuickLook extension without asking the user to open the app
  postflight do
    system_command "/usr/bin/pluginkit", args: ["-a", "#{appdir}/KiCadQL.app/Contents/PlugIns/KiCadQLPreview.appex"]
    system_command "/usr/bin/qlmanage", args: ["-r"]
  end

  zap trash: "~/Library/Containers/io.github.atait.KiCadQL.Preview"
end
```

People then install it with:

```sh
brew install --cask <you>/tap/kicadql
```

For each new release, update `version` and `sha256`. `brew audit --cask --new <you>/tap/kicadql` and
`brew style` check the file.

The main `homebrew/cask` repository (where `brew install --cask kicadql` would work without the tap)
only accepts apps that are notarized and reasonably well known (stars, forks, users). Start with the
tap, and submit there later if the project gets popular.
