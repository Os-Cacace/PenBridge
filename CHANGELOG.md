# Changelog

## 3.1

- **Auto-rotate**: the screen turns when you turn the laptop, and pen and touch follow.
  It stays put while the laptop lies flat. Needs the new IntelISH sensor driver in the
  OpenCore EFI (`Driver/IntelISH`, a GPL-2.0 port of yjmd2222/IntelISH for Comet Lake
  sensor hubs). Tested on the Dell Latitude 7410 2-in-1 only.
- **Control Center switch** for auto-rotate on macOS 26: Edit Controls → Add a Control → Touchintosh.
- Dragging, two-finger gestures and the on-screen keyboard now map correctly on a screen
  rotated to portrait.

## 3.0: PenBridge is now Touchintosh

- New name and icon (several other projects were already called PenBridge).
- Your settings, learned keyboard words and EFI backups carry over automatically. The
  installer replaces an existing PenBridge install, so the two never run at once.
- macOS asks for Input Monitoring and Accessibility again, because it sees a new app.

## 2.2.1

- The menu bar keyboard icon now turns automatic showing on or off (filled when on), so the
  on-screen keyboard stays away while you use a hardware keyboard. Right-click or ⌥-click it
  to show or hide the keyboard right away.

## 2.2

- **On-screen keyboard**: iPad-style keyboard for the touchscreen, English and Arabic, shown
  automatically in text fields. Glide typing, word suggestions, auto-capitals, accents on long-press,
  space-bar cursor, number row, resizable, floating or docked (drop it near the bottom edge to dock).
  - **Advanced** layout: a full Mac keyboard with esc, tab and arrows. ⌘ ⇧ ⌥ ⌃ really hold the key
    (tap for the next click or key, double-tap to lock), so Photoshop's ⌥-click or ⇧-click work with the pen.
  - **Shortcut bar** on both layouts: Edit, Apps, Move and System shortcuts, one tap each.
  - **Arabic** uses the Mac Arabic positions, with a shift layer for the harakat.
  - Glide word lists are built on your own Mac from the macOS spell checker the first time
    each language is used (a few minutes, in the background).
- **Touch**: two- and three-finger taps run any pen-button action or a recorded shortcut.
  Fingers lifting slightly out of step no longer count as a swipe.
- **Charger noise filter**: stops the pen clicking on its own and steadies hover while charging.

## 2.1 (first public release)

- Guided installer: compatibility checks, PenBridge install, optional reversible VoodooI2C tune-up, permissions.
- Claude helper: "Copy for Claude" report and `CLAUDE.md` porting guide; driver patches in a plain text table.
- Pen buttons: every button configurable, per-app settings, recorded shortcuts, eraser toggle,
  Accessibility Keyboard, guided button test, Bluetooth top button (HP Active Pen G3).
- Menu bar panel: Pen, Buttons, Touch, Gestures and Status tabs, live changes.
- Touch: momentum scrolling, pinch, rotate, two-finger tap, configurable 3/4-finger swipes.
