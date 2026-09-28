# Handoff: Scribe (macOS tutorial recorder)
2026-09-28 · Building and iterating on a local recreation of scribehow.com for classroom/PD use.

## Objective
A menu-bar macOS app that records a workflow click by click and produces a numbered,
screenshotted how-to guide that can be edited and exported (web page, PDF, Markdown,
Gmail paste), with school branding. It is in real daily use: **17 guides recorded
Sep 1 – Sep 22**.

## Current state
Everything requested so far is built, signed, and running. **No request is pending.**
Last change (Sep 25–28): **GIF steps** (hold Fn while recording), a rebuilt
**three-pane studio editor**, crop / trim / spotlight / replace image, GIFs in every
export, plus a code-review pass with fixes. The project is now a **git repo**
(`main` branch, local only) and is split into several Swift files.

Project: `~/ClaudeCode/Scribe` — `main.swift`, `Core.swift`, `Media.swift`,
`Capture.swift`, `Recorder.swift`, `Export.swift`, `Editor.swift`, `SelfTest*.swift`
(~13.5k lines, no Xcode project), `build.sh`, `doctor.sh`, `make-cert.sh`, `README.md`,
`CLAUDE.md`, `assets/`.
**Read `CLAUDE.md` before changing anything** — it holds ~35 hard-won macOS gotchas that
this handoff deliberately does not repeat.

What exists:
- **Recording** `⌃⌥⌘R` · name prompt for new guides · screenshot = the frame *before* the
  click (continuous SCStream per display) · Accessibility element names · floating
  per-step "describe this step" box · double-click coalescing.
- **Capture Area** menu: Window You Click In (default) / Whole Screen / one app only.
- **GIF steps**: hold Fn while recording (or ⌃⌥⌘F toggle) → every click during the hold
  goes into one GIF step, max 15 s. Footage in `gif-NNN/` beside `shot-NNN.png`. Only Fn
  steps have footage; they flip between GIF and Screenshot in the editor.
- **Editor** `⌃⌥⌘E` (three-pane studio): step list (drag reorder, Backspace deletes, ⌘Z
  restores) · canvas with tools — Cover (Solid bar default, Pixelate; per-cover colour),
  Arrow, Line, Box, Circle, Pen, Marker, Text, Crop, Spotlight · GIF transport (Space,
  scrubber, trim bar, Use as Still / Revert Still) · inspector: step text, Media switch,
  show pointer, Crop / Spotlight (Dim, Magnify) / Replace Image / Auto highlight, covers,
  Undo / Clear · Expand · New Guide · Copy for Gmail · Export menu.
- **Library** `⌃⌥⌘G`: every guide, CURRENT badge, New Guide / Open / Show in Finder /
  Delete (moves to Trash).
- **New Guide** `⌃⌥⌘N`: non-destructive; the old guide stays in the library.
- **Exports** (GIF-aware: animated HTML/Markdown, budgeted Gmail GIF, PDF filmstrip):
  self-contained HTML · PDF (As many as fit / 1 / 2 / 3 / 4 per page; 4 is a
  2 × 2 grid; fixed layouts centered with rows aligned) · Markdown folder · Email HTML
  file · Copy for Gmail (clipboard).
- **Export Theme**: Scribe (default) / Kate Collins (Badgers) / Waynesboro Public Schools.
- **Context line** under each step: window name + element name, scrubbed of email,
  domains, browser profile, and Chrome's memory badge.
- **App icon**: generated "mark" (annotated-screenshot card).

## Decisions (and why)
- **Native Swift + `build.sh`, no Xcode**: user's choice at kickoff; mirrors the sibling
  project `~/ClaudeCode/CursorGlow`. Split out of one `main.swift` on Sep 25 so parallel
  agents could work; explicit `SOURCES=(…)` list in build.sh.
- **GIF trigger = hold Fn/Globe** (user's choice over hotkey/toggle); ⌃⌥⌘F added as a
  fallback. Fn is polled (no Input Monitoring permission). Confirmed working on a real
  recording Sep 25.
- **Only Fn steps get footage, 15 s cap, three-pane studio editor, PDF filmstrip, tools =
  crop, trim/still, spotlight/zoom, replace image**: all user choices (Sep 25).
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
- **Expecting ImageIO's GIF writer to be huge**: it already does global palette + delta
  frames on this macOS; the custom encoder is only ~10% smaller (kept for exact colours
  and budgets).

## Artifacts
- `~/ClaudeCode/Scribe/Scribe.app` — current build, running.
- The `*.swift` files — the live source; `git log` has the history since Sep 25.
- `CLAUDE.md` — authoritative gotchas, updated for GIF steps and the studio editor.
- `README.md` — user-facing docs, current.
- `assets/kcms-logo.png` — rasterized from `~/Downloads/Document.svg` (the "MR. T"
  badger art; solid white background, not transparent).
- `assets/icon-1024.png` — current icon source ("mark"); `assets/make-icon.swift` draws it.
- `~/Library/Application Support/Scribe/<timestamp>/` — the user's real guides
  (`shot-NNN.png`, `gif-NNN/`, `guide.json`). Never delete these.
- `scribe.log` — next to the app; read it first when debugging.
- Render helpers used last session (`html2png.swift`, `pdfpage.swift`, `crop.swift`,
  `svg2png.swift`) lived in that session's scratchpad and are **gone**. The patterns are
  described in `CLAUDE.md`; recreate them if needed.

## Verbatim essentials
- Hotkeys: `⌃⌥⌘R` record/stop · `⌃⌥⌘E` editor · `⌃⌥⌘G` library · `⌃⌥⌘N` new guide ·
  hold Fn = GIF step · `⌃⌥⌘F` GIF toggle.
- Build: `bash build.sh` — quits the running copy first; can take ~2 minutes, so use a
  long timeout or run it in the background.
- Self-tests — run the binary with the data root redirected so nothing lands in the
  library, one flag at a time (the log is truncated per launch):
  `SCRIBE_DATA_ROOT=<scratch> Scribe.app/Contents/MacOS/Scribe --selftest-offline`, then
  `--selftest-media`, `--selftest-gif`, `--shot-studio`; each must end `… PASSED`.
  `--selftest` needs real capture. `SCRIBE_NO_KILL=1 bash build.sh` builds without
  quitting a running copy.
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
- Always set `SCRIBE_DATA_ROOT` for self-tests. Older runs left scratch guides in the
  library; clean up only titles **"Scribe Offline Self Test"**, **"Page Layout Check"**,
  **"Adding a Class to a Room"**, and 0-step folders.
- Parallel agents: git worktrees (`isolation: worktree`), `SCRIBE_NO_KILL=1`, isolated
  data roots; merge one at a time and run all four suites after each merge.
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
  6. ~~git init~~ — done Sep 25 (local only, no remote).
- **Not yet tested by a human:** Copy for Gmail pasted into real Gmail (do the embedded
  images — and animated GIFs — survive?); the 15 s cap; ⌃⌥⌘F; holding an arrow key while
  recording (must not start a GIF); drag-reorder, crop handles, magnifier drag and
  Replace Image by hand. The user did record one real GIF step, crop, replace an image
  and export a PDF on Sep 25 with no errors in the log.
- **Known limits, by design:** clicks only (no typed-text steps); US Letter PDF only;
  step-delete undo only while the editor is open; markup can't be moved once drawn; a
  plain click within 80 ms of releasing Fn ends the clip and the GIF step gets no prompt;
  the self-signed build only runs on this Mac.

## Suggested opening prompt
```
I'm continuing work on Scribe, my macOS click-by-click tutorial recorder in
~/ClaudeCode/Scribe. Before doing anything, read HANDOFF.md and CLAUDE.md in that
folder. The app is in daily use with real guides on disk, so don't delete anything in
~/Library/Application Support/Scribe except the scratch guides the handoff names.

Here's what I want next: [your request]
```
