# Handoff: Scribe (macOS tutorial recorder)
2026-09-23 · Building and iterating on a local recreation of scribehow.com for classroom/PD use.

## Objective
A menu-bar macOS app that records a workflow click by click and produces a numbered,
screenshotted how-to guide that can be edited and exported (web page, PDF, Markdown,
Gmail paste), with school branding. It is in real daily use: **17 guides recorded
Sep 1 – Sep 22**.

## Current state
Everything requested so far is built, signed, and running. **No request is pending.**
Last change: the app icon.

Project: `~/ClaudeCode/Scribe` — `main.swift` (~6,060 lines, single file, no Xcode
project), `build.sh`, `doctor.sh`, `make-cert.sh`, `README.md`, `CLAUDE.md`, `assets/`.
**Read `CLAUDE.md` before changing anything** — it holds ~35 hard-won macOS gotchas that
this handoff deliberately does not repeat.

What exists:
- **Recording** `⌃⌥⌘R` · name prompt for new guides · screenshot = the frame *before* the
  click (continuous SCStream per display) · Accessibility element names · floating
  per-step "describe this step" box · double-click coalescing.
- **Capture Area** menu: Window You Click In (default) / Whole Screen / one app only.
- **Editor** `⌃⌥⌘E`: reorder, delete, edit text · preview canvas with tools — Cover (Solid
  bar default, Pixelate), Arrow, Line, Box, Circle, Pen, Marker, Text · Undo / Clear /
  Covers → All / Make Permanent… · Auto highlight toggle · Expand + ‹ › step nav ·
  New Guide · Copy for Gmail · Export menu.
- **Library** `⌃⌥⌘G`: every guide, CURRENT badge, New Guide / Open / Show in Finder /
  Delete (moves to Trash).
- **New Guide** `⌃⌥⌘N`: non-destructive; the old guide stays in the library.
- **Exports**: self-contained HTML · PDF (As many as fit / 1 / 2 / 3 / 4 per page; 4 is a
  2 × 2 grid; fixed layouts centered with rows aligned) · Markdown folder · Email HTML
  file · Copy for Gmail (clipboard).
- **Export Theme**: Scribe (default) / Kate Collins (Badgers) / Waynesboro Public Schools.
- **Context line** under each step: window name + element name, scrubbed of email,
  domains, browser profile, and Chrome's memory badge.
- **App icon**: generated "mark" (annotated-screenshot card).

## Decisions (and why)
- **Native Swift, one `main.swift` + `build.sh`**: user's choice at kickoff; mirrors the
  sibling project `~/ClaudeCode/CursorGlow`.
- **Step text is typed by the user** in a floating, non-blocking box after each click;
  rule-based sentence as fallback; **no AI**: user's choice.
- **Screenshot from a continuous stream, not per click**: a screenshot taken when the
  click is observed already shows the result of the click.
- **Signed with the existing "CursorGlow Dev" self-signed cert, never ad-hoc**: ad-hoc
  signing silently breaks the Screen Recording/Accessibility grants on every rebuild.
- **Editor and library switch the app to `.regular` while open** (Dock icon, ⌘-Tab):
  this was the real fix for "the editor isn't showing up" — an `LSUIElement` window that
  falls behind another app is otherwise unreachable.
- **"New Guide", not "Erase Current Guide"**: the old action never erased anything, and
  its scary name meant the user couldn't find a New Guide button.
- **Redaction defaults to Solid bar**: pixelation isn't safe for sensitive information.
- **The red annotation highlight stays red in every theme**: it must stay visible on any
  app's colors. Themes brand only the document chrome.
- **Gmail export is a separate renderer**: inline *longhand* CSS, tables, px
  line-heights, JPEG screenshots, PNG logo.
- **Context line drops the app name** (user request: "just the name of the window and
  the element name"); element name is omitted when it's a code id (`menuOptions`) or
  already in the step text.
- **4 per page = 2 × 2 grid** (user asked for "a square"): about double the image size.
  1–3 per page stay stacked. Fixed layouts centered (user request); the flowing layout
  stays left-aligned (my call; user didn't object).
- **WPS theme is colors only**: user said "Just use the three main colors if needed."

## Dead ends — do not retry
- **WKWebView for PDF export**: `createPDF` gives one giant page; `printOperation` ran to
  80 MB and never returned. PDFs are drawn directly into a `CGPDFContext`.
- **`tccutil reset` for ScreenCaptureKit `-3801`**: there was nothing to reset. Fix was
  `CGRequestScreenCaptureAccess()` plus adding the app by hand in System Settings.
- **Terminal `screencapture` / the in-app browser on `file://`**: both blocked. Use the
  app's `--shot-*` flags and CoreGraphics/WebKit render helpers instead.
- **Subclassing NSImageView to draw on the preview**: `draw(_:)` isn't reliably called.
- **`font:` shorthand or unitless line-heights in the Gmail HTML**: Gmail rewrites them
  unevenly — the "wonky font sizes" the user reported.
- **Cleaning window titles by stripping `" - <app>"` and truncating at N characters**:
  leaked the user's email address, cut in half.
- **Knocking out the logo's white background for a dark icon tile**: the badger's own
  whites vanish with it.
- **Wide text-slice edits of `main.swift`**: twice deleted working functions as
  collateral (caught by the compiler, restored).

## Artifacts
- `~/ClaudeCode/Scribe/Scribe.app` — current build, running.
- `main.swift` — the live source.
- `CLAUDE.md` — authoritative gotchas, mostly current. **Stale:** Testing item 2 says
  "two annotated PNGs … 2-page PDF" (the self-test now builds 3 steps and many PDFs);
  "Rendering HTML to a picture" points at `scratchpad/html2png.swift`, which is gone.
- `README.md` — user-facing docs, current.
- `assets/kcms-logo.png` — rasterized from `~/Downloads/Document.svg` (the "MR. T"
  badger art; solid white background, not transparent).
- `assets/icon-1024.png` — current icon source ("mark"); `assets/make-icon.swift` draws it.
- `~/Library/Application Support/Scribe/<timestamp>/` — **17 real guides**
  (`shot-NNN.png` + `guide.json`). Never delete these.
- `scribe.log` — next to the app; read it first when debugging.
- Render helpers used last session (`html2png.swift`, `pdfpage.swift`, `crop.swift`,
  `svg2png.swift`) lived in that session's scratchpad and are **gone**. The patterns are
  described in `CLAUDE.md`; recreate them if needed.

## Verbatim essentials
- Hotkeys: `⌃⌥⌘R` record/stop · `⌃⌥⌘E` editor · `⌃⌥⌘G` library · `⌃⌥⌘N` new guide.
- Build: `bash build.sh` — quits the running copy first; can take ~2 minutes, so use a
  long timeout or run it in the background.
- Self-tests: `open Scribe.app --args --selftest-offline` (no permissions; must end
  `SELFTEST-OFFLINE PASSED`) and `--selftest` (real capture).
- Visual checks (write PNG/PDF/HTML beside the app): `--shot-editor`, `--shot-expanded`,
  `--shot-erase`, `--shot-library`, `--shot-nameprompt`, `--shot-pdf`, `--shot-themes`,
  `--dump-context`.
- Icon: `swift assets/make-icon.swift mark` or `badger`, then `bash build.sh`.
- Theme colors: Scribe `#E0234A` · KCMS accent `#4B1F87`, secondary `#260C47`
  (sampled from the art), tertiary `#1A1A1E` · WPS `#1B85C8` / `#F07E26` / `#7CB943`.
- Email type scale: font sizes 12/15/20 px; text line-heights 18/22/26 px (plus a
  structural 5 px stripe row).

## Working preferences
- The user reports symptoms, not causes ("the editor isn't showing up" meant "I can't get
  back to the window"). Reproduce and look before fixing.
- Verify visually before calling anything done — render it and look. That caught about
  eight bugs that reading the code did not.
- Keep the user's email address, district account, and name out of anything that gets
  shared or exported.
- The user wants school branding: Kate Collins purple/black with a badger; Waynesboro
  blue/orange/green.
- The user often sends follow-ups mid-task; fold them in rather than finishing the old
  thing first.
- The user asked for clarifying questions up front at kickoff.
- **Org rule: never include PII in prompts.**

### Method notes (for the agent)
- Each Bash call starts in the session's working directory: run
  `cd ~/ClaudeCode/Scribe && …` in the same command, or relative paths fail.
- zsh aborts the whole command on an unmatched glob — name files explicitly in `rm`.
- Edit `main.swift` with anchored find/replace that asserts the anchor exists; never slice
  between two anchors. After a big edit: build, then `--selftest-offline`.
- Self-tests and `--shot-*` flags create scratch guides in the library. Clean up only
  titles **"Scribe Offline Self Test"**, **"Page Layout Check"**, **"Adding a Class to a
  Room"**, and 0-step folders.
- Never print raw window titles — they contain the user's address. `--dump-context`
  prints only the cleaned lines.

## Open items
- **Next step:** none pending — take the user's next request.
- **Asked, never answered:**
  1. **KCMS logo mismatch.** `Document.svg` is the "MR. T" badger, not the "Kate Collins
     Middle School Badgers" mark the user showed in chat. MR. T is what ships. Need the
     school mark as a file if they want it.
  2. KCMS badge purple `#4B1F87` is a lightened `#260C47` — confirm, or get the official hex.
  3. WPS hexes were eyeballed from a pasted slide; official values welcome. No WPS logo
     file was supplied.
  4. App icon: "mark" ships; a "badger" version was rendered — user hasn't chosen.
  5. Exclude CursorGlow from capture? Its green cursor ring appears in screenshots.
  6. `git init` the project? It is not a repository.
- **Not yet tested by a human:** Copy for Gmail pasted into real Gmail (do the embedded
  images survive?); Capture Area cropping on real recordings (the math is self-tested);
  the markup tools (built and self-tested, no user feedback yet).
- **Known limits, by design:** clicks only (no typed-text steps); US Letter PDF only; no
  undo for deleting a step; markup can't be moved once drawn; the self-signed build only
  runs on this Mac.

## Suggested opening prompt
```
I'm continuing work on Scribe, my macOS click-by-click tutorial recorder in
~/ClaudeCode/Scribe. Before doing anything, read HANDOFF.md and CLAUDE.md in that
folder. The app is in daily use with real guides on disk, so don't delete anything in
~/Library/Application Support/Scribe except the scratch guides the handoff names.

Here's what I want next: [your request]
```
