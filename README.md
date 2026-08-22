<p align="center">
  <img src="docs/assets/hero.svg" alt="Nook — a calm menu bar for macOS" width="800">
</p>

<p align="center">
  <a href="https://github.com/fif7y/nook/releases/latest"><img src="https://img.shields.io/github/v/release/fif7y/nook?label=download&color=2ea44f" alt="Download latest release"></a>
  <a href="#install"><img src="https://img.shields.io/badge/requirements-macOS_27%2B-E8A33D" alt="Requires macOS 27 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/fif7y/nook" alt="License: GPL-3.0"></a>
  <a href="https://github.com/sponsors/fif7y"><img src="https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa" alt="Sponsor Nook"></a>
</p>

Nook hides the icons you don't need until you do — hover, click, or press a
shortcut and they slide back in. It's built natively on macOS 27's new menu
bar architecture instead of the window-juggling tricks older managers rely
on, which is why hiding feels like part of the system: no overlay windows, no
fake bars, no icons jumping when the bar reflows.

## Features

- **Hidden and always-hidden sections** — drag icons across the chevron to
  choose what stays, what hides, and what only appears when you ask.
- **A real layout editor** — app-icon previews, drag-and-drop ordering, and
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
- **Reveal styles** — Instant, Smooth, or Fade animation when hidden icons
  come back, with an adjustable auto-rehide delay.
- **Signed updates** — Sparkle with EdDSA signatures, checked against a
  signed appcast.

## How it works

macOS 27's menu bar can hide items natively — it's the mechanism behind the
system's assessment (exam lockdown) mode. Nook drives that mechanism directly:
it asserts a configuration listing what should stay visible, and macOS itself
hides the rest and reflows the bar. That's why hiding feels like part of the
system — it *is* the system.

The catch: this API lives in a **private Apple framework**
(`MenuBarClientCore`). It isn't documented or guaranteed, so a macOS update
could change or remove it. Nook resolves it at runtime and fails soft — if the
API ever disappears, Nook simply reports hiding as unavailable rather than
breaking your menu bar. Everything else (item positions, clicks, previews)
uses public APIs: Accessibility and ScreenCaptureKit.

## Install

Download the latest DMG from [Releases](https://github.com/fif7y/nook/releases),
drag Nook to Applications, and launch it. Or with Homebrew:

```sh
brew install fif7y/tap/nook
```

Requires **macOS 27 (Golden Gate)**. Earlier versions of macOS use a
different menu bar architecture that Nook does not target.

On first launch Nook asks for one permission:

- **Accessibility** (required) — how Nook sees the menu bar's items and
  positions, and how clicking a hidden item works without revealing
  everything.

Screen Recording is optional and never prompted for during onboarding — if
granted, Nook uses it to paint seamless cover strips over the bar while
items swap during reveals and reorders; without it, transitions simply run
uncovered.

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

## Licenses & acknowledgements

Nook was inspired by [Ice](https://github.com/jordanbaird/Ice), the open-source
menu bar manager for earlier versions of macOS — Nook picks up where Ice left
off, rebuilt from scratch for macOS 27's new menu bar architecture (no code is
shared between the projects).

Nook's only third-party dependency is
[Sparkle](https://github.com/sparkle-project/Sparkle) (in-app updates), used
under the [MIT-style Sparkle license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).
Everything else is custom code on top of Apple's system frameworks.

## License

© 2026 Gabriel Faucon. Licensed under the
[GNU General Public License v3.0](LICENSE) — use, study, and fork freely;
distributed derivatives must remain open under the same license.

Nook is an independent project, not affiliated with or endorsed by Apple Inc.
Apple, macOS, and the Mac are trademarks of Apple Inc.
