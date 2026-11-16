<p align="center"><img src="Resources/AppIcon.png" width="128" alt="P7S Opener icon"></p>

# P7S Opener

**Double-click a .p7s file and get the document inside.**

Signed documents often arrive as `.p7s` or `.p7m` files: an invoice, a contract or a court paper,
wrapped together with its signature. macOS can't open them, so you're left with a file that does
nothing. P7S Opener takes the original document out, saves it next to the signed file and opens it
in the app it belongs to.

```
invoice.pdf.p7s   ──▶   invoice.pdf
act.pdf.p7m.p7m   ──▶   act.pdf
```

It doesn't check the signature. The point is to get the document back, even when the signer's
certificate has expired or isn't trusted.

## Using it

- **Double-click** a `.p7s` or `.p7m` file. The document opens in its app (a PDF in Preview, and so
  on), and P7S Opener quits.
- **Drag** files onto the app's icon, or **open the app** and drop them on its window or use
  **Choose Files…** (⌘O). The window lists what was extracted and who signed it.

The document is saved next to the signed file with `.p7s` / `.p7m` removed. If that name is taken it
becomes `name-1`, `name-2`, …, so nothing is ever overwritten. Files signed more than once (common
for Italian `.p7m.p7m` files) are unwrapped down to the original.

It reads every way these files are stored: binary (DER or BER, as Windows and Outlook write them),
PEM text, and S/MIME email attachments.

## Requirements

- macOS 27 or later
- Swift 6.3 or later, from Xcode or the Command Line Tools (`xcode-select --install`)

## Install

There is no prebuilt download; both ways below build it from source on your Mac.

### Homebrew

```sh
brew tap alxrxs/tap
brew trust alxrxs/tap
brew install alxrxs/tap/p7s-opener
ln -sfn "$(brew --prefix)/opt/p7s-opener/P7S Opener.app" "/Applications/P7S Opener.app"
open "/Applications/P7S Opener.app"
```

### From source

```sh
git clone https://github.com/alxrxs/p7s-opener.git
cd p7s-opener
./build.sh install
```

This builds a release copy and puts it at `/Applications/P7S Opener.app`.
`./build.sh` on its own only builds `build/P7S Opener.app`.

macOS hands `.p7s` files to Keychain Access by default. When that's the case, P7S Opener's window
shows **Make Default**; click it once and double-clicking works from then on.

### Uninstall

Delete `/Applications/P7S Opener.app` (and `brew uninstall p7s-opener` if you used Homebrew).

## Caveats

- **Detached signatures have nothing inside.** Some `.p7s` files carry only the signature, and the
  document is the file sent alongside it. P7S Opener says so instead of making an empty file.
- **Encrypted `.p7m` files can't be opened.** They need the recipient's private key; P7S Opener tells
  you when a file is encrypted rather than just signed.
- **Text signed in S/MIME text mode** comes back exactly as it was signed, which can differ from the
  original in line endings. Binary documents (PDFs, images, archives) come back byte for byte.

## Development

```sh
swift build        # debug build
swift test         # unit tests (P7SOpenerCore: every encoding, nesting, naming, hostile input)
./build.sh install # build, install to /Applications and register it
```

`Sources/P7SOpenerCore` reads the signed container; `Sources/P7SOpener` is the app. The icon is drawn
by `scripts/make-icon.swift`. The tests create real signed files with the `openssl` that ships with
macOS.

Releases are tagged `vX.Y.Z`; `build.sh` stamps the latest tag into the app's version.

## License

[GPL-3.0](LICENSE). Copyright © 2026 Andrei.
