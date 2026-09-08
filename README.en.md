<p align="center">
  <img src="Resources/VoxIcon.png" width="128" alt="vox icon">
</p>

# vox

[![release](https://img.shields.io/github/v/release/MizuRyu/vox)](https://github.com/MizuRyu/vox/releases)
[![license](https://img.shields.io/github/license/MizuRyu/vox)](LICENSE)

Speak, clean it up, paste it as is. A local Japanese voice-input HUD for macOS.

日本語版: [README.md](README.md)

## Features

- **Real-time display** — what you say appears immediately in a HUD at the bottom of the screen; nothing reaches the target app until you commit
- **Type while you speak** — edit directly in the HUD. Speech is appended at the end, typed characters go at the caret, and recording never stops
- **File search while speaking (`⌃P` / `@`)** — resolves the target repository from the frontmost editor or terminal and inserts a path into the text; recording continues during the search
- **Commit in one paste** — press the recording key again to return to the app you started in and insert the whole committed text at once
- **Runs locally** — uses Apple's `SpeechTranscriber`. Only the first model download needs the network. Nothing sends your text to the cloud
- **Filler removal** — rule-based removal of Japanese fillers before insertion; the raw text stays in the local history
- **Optional auto-Enter** — sends Enter after pasting once the input field reads back as expected; a single setting decides whether it also sends where the field cannot be read

![HUD showing dictated text and a file path while recording](images/hud-example.png)

*A HUD mock-up built from synthetic sentences and fictional paths. No real speech or third-party app screen is used.*

## Requirements

macOS 26 or later on Apple Silicon. An internet connection is needed once, for the initial speech model download.

## Speech recognition model

Vox uses Apple's `Speech` framework (`SpeechAnalyzer` + `SpeechTranscriber`, new in macOS 26) with the `ja_JP` locale. No other model is bundled.

| Item | Detail |
|---|---|
| Where it runs | On device. The OS manages the model; it is not part of the Vox binary or its memory |
| First run | The OS downloads the Japanese model once (tens of seconds). After that everything is local |
| Partial results | `.fastResults` is enabled, so the text updates roughly once a second while you speak |
| Network | Neither audio nor text leaves the machine |

Why this engine was chosen, and the candidates compared (Parakeet, Whisper variants), are in [docs/specs/02-speech-engines.md](docs/specs/02-speech-engines.md) (Japanese).

## Installation

One-line install or update (fetches the latest Release, copies it into `/Applications`, and removes the quarantine attribute):

```sh
curl -fsSL https://raw.githubusercontent.com/MizuRyu/vox/main/scripts/install.sh | bash
```

To install manually, download the `.dmg` from [Releases](https://github.com/MizuRyu/vox/releases), move `Vox.app` into `/Applications`, and remove the quarantine attribute (needed once because the build is not Developer ID signed or notarized):

```sh
xattr -dr com.apple.quarantine /Applications/Vox.app
```

On first launch the setup screen asks for Microphone, Accessibility, and Input Monitoring in order. If a grant is not reflected, press "状態を再確認" (re-check status); if macOS asks for a restart, quit Vox and open it again.

<img src="images/setup.png" alt="First-run setup screen showing three permissions with numbers and green checks" width="620">

*A display example with two of three permissions granted. The actual state is checked at launch.*

To build from source, `just install` places the app in `/Applications/Vox.app` (see [docs/development.md](docs/development.md), Japanese).

## Usage

1. Put the caret in the field you want to paste into and press `⌘⇧Space`.
2. Speak, and watch the text in the HUD. Type into it directly, or insert a path with the file search.
3. Press `⌘⇧Space` again to commit and paste into the original app.

| Key | Action |
|---|---|
| `⌘⇧Space` | Start recording / commit and paste |
| `⌃P`, or type `@` in the HUD | File search |
| `Enter` in the palette | Insert the path. Expands/collapses folder rows; switches the search target on worktree rows |
| `Esc` | Close the palette; discard the text on the recording screen |
| `⌘,` | Open settings while Vox is focused |

The file search toggles between `Changes` and `Tree`. Changes lists modified files first; Tree shows the indexed files as a hierarchy.

![File view showing a fictional project as a folder tree](images/palette-tree.png)

*The real view rendered with fictional file names and contents.*

Full details on operation, permissions, and limitations are in [docs/usage.md](docs/usage.md) (Japanese).

## Settings

<img src="images/settings.png" alt="Settings screen with the recording key changed to Command-Option-Space" width="548">

*The app's own settings view, rendered offscreen with synthetic settings and fictional microphone data.*

Open settings from the menu bar item, the gear in the HUD, or `⌘,`. You can change the recording and file-search shortcuts, enable auto-Enter and whether it also sends in terminals, turn on the experimental voice processing, and review the available microphones. See [docs/usage.md](docs/usage.md#設定) for what each item does.

## Development

```sh
nix develop
just setup
just build
just test
just verify
```

See [docs/development.md](docs/development.md) for setup, checks, and distribution, and [docs/README.md](docs/README.md) for specifications and technical decisions (both Japanese).

## License

[MIT](LICENSE)

The full license text for FluidAudio (Apache-2.0), which only the benchmark targets depend on, is in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). It is not part of the app.
