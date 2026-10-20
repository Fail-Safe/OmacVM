# 0044: Omanotch is the shared notch integration; FullPanel is OmacVM.app only, experimental

Status: accepted, built (FullPanel: off by default, experimental, OmacVM.app
only; next release after 3.0.15). Proposed with a working branch by
@brianmerchant in [#339](https://github.com/gillesgoetsch/OmacVM/issues/339).

## Context

On a MacBook with a notch, macOS keeps a full-screen window below the camera
housing and covers the strip beside it with the full-screen Space's menu
bar. Omanotch fills that strip on every route: a hidden `NOTCH` output in
the VM renders Omarchy's bar, notchcast streams it, and a small Mac app
draws it above the menu bar. UTM, VMware Fusion and Parallels enforce
macOS's full screen, so this is their only way to use the strip.

OmacVM.app runs its own QEMU and owns its window. #339 showed that its full
screen can cover the strip itself: the window covers the whole display, and
that Space's menu bar is made transparent (SkyLight), as UTM does on macOS 27.
The guest then draws its own bar in the strip, with no stream. (Previously,
the window got there through a hook on AppKit's private full-screen frame;
since the replacement below, AppKit lays it out there itself.)

## Decision

- **Omanotch stays the default and the shared integration** for all four
  routes. Nothing in it is removed.
- **FullPanel is an addition for OmacVM.app**, experimental, off by default,
  per VM (the VM folder's `notch-mode` file, like Graphics). Its name for
  people: **Full screen including notch, no Omanotch needed
  (experimental)**, one of the VM window's **Start in** choices with
  **Window** and **Full screen, notch via Omanotch** (only one can be
  active, so one setting: Window = the app's `startFullScreen` off, the
  other two = on with `notch-mode` native or fullpanel; the third listed
  only on a Mac with a notch). Also `omacvm fullscreen --vm NAME
  notch|standard` (= `omacvm notch --vm NAME fullpanel|native`) and the
  control centre's Full screen row. "FullPanel" stays the name in the code.
- **One start, one mode.** The app decides at each start
  (`NotchArea.start`): FullPanel only with the setting, a full-screen start,
  a notch now, and the VM ready for it (`fullpanel-ready` from `omacvm
  apply`). Then QEMU gets `OMACVM_FULLPANEL=1`, the guest gets the camera
  housing in Mac points (SMBIOS `omacvm.fullpanel=LxRxHxWxD`, measured from
  the built-in screen at that start, so every MacBook gets its own height),
  and the VM gets no Omanotch link for that start. Its features keep
  Omanotch on, so the next native start has it again without any change.
- **QEMU:** a regular pinned patch pair
  (`omacvm-cocoa-fullpanel-logic.patch`: the rules, tested without a notch;
  `omacvm-cocoa-fullpanel.patch`: the wiring), applied after the other
  cocoa patches. Per window: only a window on a display with a camera
  housing; external displays keep normal full screen. Anything private that
  is missing or changed gives normal full screen, logged once. AppKit's
  full-screen content controller asks whether the window keeps the menu
  bar's band free (`-reservesSpaceForMenuBarInFullScreen`); for a VM window
  in a FullPanel full screen the answer is no, and AppKit lays the window
  out over the whole display. No window class or frame setter is
  overridden; QEMU's own full-screen resize leaves such a window as AppKit
  laid it out.
- **Guest:** no second bar. Omanotch's bar patch (v20) has a FullPanel
  mode: on the built-in display's output, only while the app's layout says
  that output covers the whole display in full screen, the bar is the
  strip's height, split around the housing, and reserves the strip.
  notchcast's unit skips such a boot (`ExecCondition`).
- **Check:** `omacvm check` names the mode, and for FullPanel whether QEMU
  covers the strip and that Omanotch is idle.

## Not done, and why

- **No app-wide setting** (#339's branch had one): a VM moved to a Mac
  without a notch, or to the other route, must not change behaviour.
- **No build-time source transformer** for `ui/cocoa.m`: every QEMU change
  is a pinned patch with a test, as the others.
- **Not the default.** It uses private AppKit and SkyLight interfaces and
  has not been tested on enough MacBooks, Spaces transitions and display
  setups. If it holds up, it can be evaluated as the app's default later.

## Consequences

- Real tests need a notched MacBook (the Mac mini has none: there the
  rules, a made-up notch through `OMACVM_TEST_NOTCH_GEOMETRY` in test
  builds and a simulated guest cover the plumbing).
- FullPanel keeps the display covered across the tested macOS resolution
  changes. The guest's camera-housing geometry is measured at VM startup;
  restart the VM if that geometry needs to be refreshed.

## Replacement

Status: accepted with #480 (@brianmerchant). Nothing the user sees, sets or
reads changes: the same Start in choice, `OMACVM_FULLPANEL=1`, the same
`fullpanel-scale` file, the same qemu.log lines for `omacvm check`, the same
guest side.

**Why.** FullPanel in OmacVM 3.0.16-3.1.26 contained code adapted from UTM
(Apache-2.0). Parts of that QEMU code were a close translation of UTM's
`Platform/macOS/Display/VMDisplayWindow.swift` (Copyright © 2026 Turing
Software, LLC): the menu bar reveal observer on AppKit's
`_NSFullScreenMenuBarCompanionController`, the reveal and presentation
state machine, the hide/show sequence, the toolbar window handling, the
lifecycle wiring, the state set and the full-screen frame hook. They came
in through #339's branch, whose headers (and so these patches' headers)
said no UTM code was copied; that was wrong. This rewrite replaces all of
it.

**What was removed** (none of it is in the new patches;
`test-fullpanel.sh` fails the build if any of it comes back):

| Removed (previous implementation) | Replaced by |
| --- | --- |
| `-_frameForFullScreenMode` hook on QemuWindow and OmacVMHeadWindow, `-_tileFrameForFullScreen` reads, `omacvm_fp_frame` | AppKit's own layout: the reservation answer (`omacvm_fullpanel_install_reservation`), the entry checked once (`omacvm_fp_verdict`) |
| `-toggleFullScreen:` overrides on both window classes | one `NSWindowWillEnterFullScreenNotification` observer from the start (`omacvm_fullpanel_init`) |
| guards on `setFrame:display:`, `setFrame:display:animate:`, `setFrameOrigin:`, `setFrameTopLeftPoint:`, `setContentSize:` on both classes, `omacvm_fp_keep` | none: AppKit keeps its layout; QEMU's own full-screen resize (`resizeWindow`) leaves a FullPanel window as laid out instead of fitting it to the guest's mode (the picture is scaled), and QEMU's full-screen size follows AppKit's proposal |
| the forced size in `window:willUseFullScreenContentSize:` | AppKit's proposal (the whole display under the answer) |
| setter hooks on `_NSFullScreenMenuBarCompanionController` (`setMenuBarReveal:`, `setToolbarWindowReveal:`) | KVO on AppKit's titlebar window's `alphaValue` (public API) |
| `updateMenuBarHidden` / `showMenuBar` / `updatePresentationOptions` / `applyMenuBarReveal` / `menuRevealChanged:`, `omacvm_fp_reveal_allowed`, `omacvm_fp_presentation`, `omacvm_fp_strip_lost`, `omacvm_fp_display_ok` | facts → `omacvm_fp_intent` → one apply step (`-apply:`); `omacvm_fp_zone` / `omacvm_fp_asked_after_move`; `omacvm_fp_lost`; `omacvm_fp_fallback` |
| hiding the toolbar window's views | the titlebar window lets clicks through while no reveal is on screen |
| the Mission Control refresh (240 checks) | the return checks (`omacvm_fp_return_ready`, one restart, one presentation re-assert) |

**What stayed** (OmacVM's own): the QEMU integration (the whole display in
`screenSafeAreaSize`, the display box, `omacvm_fp_cut_rows`), the scale
patches (`omacvm-cocoa-fullpanel-scale*.patch`, unchanged), the window-gone
owner (#402, the same design on the new state), "Keep the Dock away"
keeping the menu bar hidden and `omacvm_fp_menu_bar_in_the_way` (#356),
`omacvm_fp_reveal_shown`, the relaxed options with the menu bar
auto-hidden, `SLSTransactionCommit` as `void`, the menu bar transaction
latch, `@try` around `setPresentationOptions:`, the build-time bit checks,
the WindowServer bounds check, the per-window state, the log lines.

**Where the new code comes from.** The reservation answer, the SkyLight
backdrop, the titlebar sensor, the facts-to-intent rules and the return
checks are new code. That the reservation question decides the layout
came from Try Omarchy's pull request #361 (themartiano, MIT; idea and
selector only, no code). Since #480 (@brianmerchant) FullPanel is
rewritten and has no code from UTM. It still follows UTM's approach: the
menu bar's backdrop made transparent with SkyLight, the menu bar held back
with the app's presentation options. Compared with UTM's file (commit
224ffec6) before it landed, it shares what any code of that approach
shares: AppKit's and SkyLight's class, selector, symbol and constant
names, SkyLight's create/set/commit order, the presentation option values,
the four pointer event masks, the `AppleMenuBarVisibleInFullscreen` key and
the titlebar window's class name. It was written by people who had read
the earlier code (not a clean-room rewrite).

**Past releases.** OmacVM 3.0.16-3.1.26 shipped QEMU with the earlier code
compiled in (it ran only with FullPanel on). Those releases are not
changed; UTM is credited in `THIRD_PARTY_NOTICES.md`.

**Tested** (2026-10-19, MacBook Pro 14-inch, macOS 27.0.1, 1800x1169 pt,
QEMU from this branch with the firmware only, no VM): with Keep the Dock
away on and off, the window covers the whole display and the strip shows
the guest (screen captures), after Mission Control opened and closed with
Escape, after its own thumbnail, after another Space's thumbnail, after
Command-Tab and after the Dock icon (each 1.2 s and 3 s later); the menu
bar stays hidden at the top edge with Keep the Dock away and comes down
and goes again without it; leaving and entering full screen again (twice)
covers the strip each time; quitting leaves the normal menu bar. Normal
full screen without OMACVM_FULLPANEL is unchanged (the same steps). That
run found one thing the old frame guards had hidden: QEMU's own full-screen
resize fitted the window to the firmware's 1920x1080 and moved it off the
strip; it now leaves a FullPanel window as AppKit laid it out.

**Tested with a real VM** (2026-10-19, the same MacBook, OmacVM Test.app
from this branch, an APFS clone of a configured Omarchy VM, a Sidecar iPad
as the external display): the window covers the whole display and
Omarchy's bar sits in the strip (Virtual-1 3600x2344 at scale 1.6, the bar
49 px = the 39.5 pt strip, split at the notch), Bridge widgets work; Mission
Control (Escape and thumbnails); top edge with Keep the Dock away on (the
menu bar stays away) and off (it comes down and goes again); exit and
re-entry; a display mode change (1512x982 and back: covered both times;
this found and fixed a "strip lost" on the mode change); FullPanel to
native (window below the notch, Omanotch streams the bar) and back to
FullPanel (Omanotch idle); the Sidecar display keeps normal full screen.

**Not tested on this patch:** Split View (Window > Full Screen Tile from
full screen did nothing; pairing would need another app's window),
display unplug (#402), sleep and lock, Stage Manager, macOS 15 and 26 on
screen. With an external display attached, the Dock icon does not switch
the MacBook's Space back (native full screen behaves the same).

**Changed when it landed** (2026-10-20): SkyLight's functions are looked
up one by one, and a failed `dlopen` or `dlsym` logs its reason; the
reservation's fallback line names the class, method or types that differ;
when a full screen stops claiming the strip (Split View's rejection, a
strip lost, another display) or claims it again, QEMU's resize handler and
the display arrangement run once more, so the guest is not left at the
whole panel's size (AppKit's layout of a rejected tile is not changed); a
window on an external display beside the open MacBook logs "a window on
another display than the built-in one: macOS's own full screen there",
which `omacvm check` does not read, so it no longer warns about it. The
run-time checks (the controller class, the method with `B16@0:8`, `-window`
with `@16@0:8`, AppKit's own implementation in AppKit's image, SkyLight's
six functions) pass on macOS 15.7.9 and 26.6.2 (GitHub's arm64 runners)
and 27.0 (the Mac mini).
