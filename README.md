<p align="center">
  <img src="docs/assets/hero.svg" alt="Nook — a calm menu bar for macOS" width="800">
</p>

Nook hides the icons you don't need until you do — hover, click, or press a
shortcut and they slide back in. It's built natively on macOS 27's new menu
bar architecture instead of the window-juggling tricks older managers rely
on, which is why hiding feels like part of the system: no overlay windows, no
fake bars, no icons jumping when the bar reflows.

## Features

- **Hidden and always-hidden sections** — drag icons across the chevron to
  choose what stays, what hides, and what only appears when you ask.
- **A real layout editor** — live icon previews, drag-and-drop ordering, and
  honest badges for what macOS groups together or protects.
- **Per-display behavior** — set a display to always show everything or to
  collapse; whichever display your pointer is on wins.
- **System icons too** — Sound, Battery, Wi-Fi and friends can hide like
  anything else. The few macOS protects (Clock, Control Center, Siri) are
  shown locked, not pretended away.
- **Built-in replacements** — media controls, AirDrop, camera/mic indicator,
  and Shortcuts items that survive hiding, since macOS temporarily removes
  its own extras while hiding is active.
- **Separators** — visual dividers that behave like icons, with adjustable
  opacity.
- **Signed updates** — Sparkle with EdDSA signatures, checked against a
  signed appcast.

## Install

Download the latest DMG from [Releases](https://github.com/fif7y/nook/releases),
drag Nook to Applications, and launch it.

Requires **macOS 27 (Golden Gate)**. Earlier versions of macOS use a
different menu bar architecture that Nook does not target.

On first launch Nook asks for:

- **Accessibility** (required) — how Nook sees the menu bar's items and
  positions, and how clicking a hidden item works without revealing
  everything.
- **Screen Recording** (optional) — only for live icon previews in the
  layout editor. Decline it and the editor shows app icons instead.

Nook is notarized by Apple and ships with the hardened runtime. It is not
sandboxed — managing the menu bar requires APIs the App Store sandbox
forbids.

More in the [FAQ](docs/FAQ.md).

## Build from source

Requires Xcode with the macOS 27 SDK and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/fif7y/nook.git
cd nook
xcodegen
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release build
```

The engine logic lives in two local Swift packages — `Packages/NookCore`
(section model, rehide state machine) and `Packages/NookEngine` (menu bar
convergence) — each with its own test suite:

```sh
swift test --package-path Packages/NookCore
swift test --package-path Packages/NookEngine
```

## License

© 2026 Gabriel Faucon. All rights reserved.
