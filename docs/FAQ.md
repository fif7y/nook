# Nook FAQ

**Which macOS versions does Nook support?**
macOS 27 (“Golden Gate”) only. Nook is built natively on macOS 27’s new menu
bar architecture rather than the window-juggling tricks older managers use —
that’s why it’s smooth, and why it can’t run on macOS 26 or earlier.

**Why do some icons hide or move together?**
macOS hides items per *app*, not per icon. If an app puts several icons in the
menu bar, they share one visibility setting — the layout editor shows these as
a grouped “moves together” badge.

**An icon I didn’t hide disappeared (AirDrop, Focus, fast user switching).**
While hiding is active, macOS itself temporarily removes a few of its own
extras. Nook can’t exempt them individually; they come back the moment hiding
is off. Nook ships its own replacements for the common ones (media controls,
AirDrop, camera/mic indicator, Shortcuts) — add them in Settings → Menu Bar.

**Why does Nook ask for Accessibility?**
It’s how Nook sees the menu bar’s items and their positions, and how clicking
a hidden item works without revealing everything. Required.

**Why does Nook ask for Screen Recording? Do I need it?**
Only for live icon previews in the layout editor. It’s optional — without it
the editor shows app icons instead. macOS re-confirms Screen Recording roughly
monthly for all apps; if the nag bothers you, turn the permission off and keep
using app icons.

**Some system icons can’t be hidden.**
macOS protects a small set of system items (Clock, Control Center, Siri). Nook
shows them locked in the editor rather than pretending.

**Can I have different layouts on each display?**
macOS mirrors the same items on every display, so layouts are global. What
*is* per-display is behavior: set a display to “always show” or “collapse”,
and whichever display your pointer is on wins.

**Is Nook sandboxed?**
No — managing the menu bar requires APIs the App Store sandbox forbids. Nook
is notarized by Apple, ships with the hardened runtime, and updates are signed
(Sparkle, EdDSA).

**How do updates work?**
Nook checks a signed appcast and offers updates in-app (Sparkle). You can
check manually in Settings → About.

**How do I open Settings if I turned the Nook icon off?**
Any of: the global shortcut (⌥⌘, by default), right-click a Nook separator,
right-click empty menu bar space, or launch Nook again from Finder/Spotlight.
