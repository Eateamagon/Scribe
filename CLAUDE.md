# Scribe — notes for Claude Code

Click-by-click tutorial recorder. Record a workflow by doing it; get a
numbered, screenshotted how-to guide out the other end.

A local recreation of **scribehow.com**, built for Ethan Truslow's own
classroom/PD use. It is **not** the commercial Scribe product, and it is
**not** an AI note-taker or transcription "scribe" — check which one is meant
before acting on a request that says only "scribe". (The sibling project
CursorGlow lost a round of work to exactly this kind of name collision.)

Swift AppKit app, no Xcode project, built by a shell script — the same shape
as `../CursorGlow`, deliberately. It was one `main.swift` until GIF steps and
the studio editor pushed it past 13,000 lines; it is now a handful of files
compiled together (see Layout). Most of the hard-won macOS
knowledge in `../CursorGlow/CLAUDE.md` applies here too; read it.

## Commands

```bash
bash build.sh                          # compile + sign + bundle
open Scribe.app                        # launch (menu-bar only, no Dock icon)
killall Scribe                         # quit
bash doctor.sh                         # read-only permissions/signing diagnostic
cat scribe.log                         # what the app logged this run

open Scribe.app --args --selftest-offline   # whole pipeline, synthetic frame, no permissions
open Scribe.app --args --selftest           # same but from a real captured frame
open Scribe.app --args --shot-editor        # reopen newest guide, photograph the editor window
open Scribe.app --args --shot-erase         # ...then erase it and photograph the empty state
open Scribe.app --args --shot-library       # photograph the guide library window
open Scribe.app --args --shot-expanded      # ...the editor with the canvas expanded
open Scribe.app --args --dump-context       # context line for every saved guide, PII-safe
open Scribe.app --args --shot-nameprompt    # photograph the guide-name panel
open Scribe.app --args --shot-pdf           # synthetic 6-step guide at every page density
open Scribe.app --args --shot-themes        # the same guide exported in every theme
open Scribe.app --args --selftest-media     # renderer, crop, spotlight, GIF encoder, flatten
open Scribe.app --args --selftest-gif       # GIF recorder (synthetic) + GIF-aware exports
open Scribe.app --args --shot-studio        # synthetic guide with a GIF step, editor photographed
open Scribe.app --args --probe-fn           # 20 s log of every Fn signal — a human holds Fn
```

For tests, prefer running the binary directly with the data root redirected,
so synthetic guides never land in the real library:

```bash
SCRIBE_DATA_ROOT=/tmp/scribe-test Scribe.app/Contents/MacOS/Scribe --selftest-offline
SCRIBE_NO_KILL=1 bash build.sh     # build without quitting a running copy
```

`scribe.log` is **truncated on every launch** — run one flag, read the log,
then the next. Grepping after two runs shows only the second.

`--shot-editor` writes `editor-shot.png` beside the .app and dumps every view's
frame to the log as `SHOT` lines. It exists because the terminal's
`screencapture` has no Screen Recording grant of its own ("could not create
image from display"), so the app photographing its own window is the only way
to actually look at the editor instead of reasoning about it. Both flags load
the most recent session with steps, so they need a real recording to have
happened first.

`build.sh` quits any running copy first, so it doubles as the update command.

## Layout

`build.sh` compiles an explicit `SOURCES=(…)` list (never a `*.swift` glob,
which would pick up stray scripts). Top-level entry code stays in `main.swift`.

| File | Holds |
|---|---|
| `main.swift` | `HotKeyCenter`, `AppDelegate` (menu, recording, GIF wiring), entry point |
| `Core.swift` | `Diag`, `Geo`, `CaptureScope`/`Settings`, `Img`, `Redaction`, `Markup`, `Annotator`, `GuideStep`, `Guide` |
| `Media.swift` | GIF clip model, `RenderSpec`, `FrameRenderer`, `PointerOverlay`, key frames, the GIF89a encoder, `MediaPreparer` |
| `Capture.swift` | `Capture`/`DisplayStreamOutput`, `AXInspector`, prompt box, guide-name panel |
| `Recorder.swift` | `FnMonitor`, `GifRecorder`, recording HUD, Globe-key notice |
| `Export.swift` | `ExportTheme`, `Export` (HTML, email, Markdown, PDF + filmstrips, async doorways) |
| `Editor.swift` | `MarkupCanvas`, transport/trim views, `ClipPlayer`, the studio `EditorWindowController`, library |
| `SelfTest*.swift` | `extension AppDelegate` self-tests and window photographs |

Types by section:

| Section | What it does |
|---|---|
| `Diag` | Appends to `scribe.log` beside the .app. **Read this first when debugging.** |
| `Geo` | The three coordinate systems and the conversions between them |
| `Img` | Downscale, PNG read/write, in-memory PNG encode |
| `Redaction` / `RedactionStyle` | Normalised cover rects stored on a step |
| `Annotator` | Redacts, then draws the red box / ring and the numbered badge |
| `Markup` / `MarkupKind` / `MarkupColor` | Arrows, outlines, freehand, highlighter, text |
| `MarkupCanvas` | The editor canvas: draw, crop and spotlight modes; click anything to remove |
| `FrameRenderer` | The one place pixels are produced — stills and GIF frames alike |
| `GifRecorder` / `FnMonitor` | Fn-held footage: region, frames to disk, pointer track, clicks |
| `GuideStep` / `Guide` | Model + `guide.json` persistence |
| `DisplayStreamOutput` / `Capture` | One `SCStream` per display — needs Screen Recording |
| `AXInspector` | What was clicked, and where its frame is — needs Accessibility |
| `PromptWindow` / `PromptBox` | The floating "describe this step" panel |
| `CaptureScope` / `Settings` | What goes in the shot; UserDefaults-backed |
| `SeparatorRowView` | Table rows that draw their own hairline |
| `EditorWindowController` | Three-pane studio: list, canvas + transport, inspector |
| `GuideSummary` / `LibraryWindowController` | Every guide on disk |
| `ExportTheme` | School branding: colours, stripe, optional logo from `assets/` |
| `Export` | HTML, Gmail-safe HTML, Markdown, PDF (`PageDensity` picks the layout) |
| `HotKeyCenter` | Carbon `RegisterEventHotKey` — needs no permission |
| `AppDelegate` | Menu, click monitor, recording lifecycle, self-tests |

Entry point is top-level code at the bottom of `main.swift` — that file **must**
keep its name for it to compile. Anything a self-test extension in another file
touches cannot be `private` on `AppDelegate`.

## Hard-won gotchas

### ScreenCaptureKit returns -3801 with no TCC traffic, and it is NOT a refusal

This cost the whole first session. A brand-new build gets:

```
SCShareableContent FAILED: ... Code=-3801 "The user declined TCCs ..."
```

in 50 ms, and `log show --predicate 'subsystem == "com.apple.TCC"'` shows
**nothing at all** for the bundle id. It reads exactly like the sticky "Don't
Allow" that `../CursorGlow/CLAUDE.md` warns about. It is not one.
`tccutil reset ScreenCapture com.ethantruslow.scribe` reports success and
changes nothing, because there was never a row to reset.

What is actually happening: nothing ever asked. `Capture.requestAccess()` now
calls `CGRequestScreenCaptureAccess()` before the first
`SCShareableContent` — that is the call that registers the app with TCC. Note
it is a different call from `CGPreflightScreenCaptureAccess()`, which is still
the one to avoid for *checking* state (it reports stale results after a
rebuild).

On this machine even `CGRequestScreenCaptureAccess()` returned false without
producing a prompt or any tccd log line, so the app had to be added by hand:
**System Settings › Privacy & Security › Screen & System Audio Recording › +**,
pick `Scribe.app`, switch it on, then **relaunch**. A grant never applies to
the process that was running when it was made.

Do not "fix" -3801 by changing capture code until `doctor.sh` and the TCC log
show a real decision. Six rounds were lost on CursorGlow to patching on
hypotheses; this is the same trap wearing a different error code.

### An LSUIElement app can open a window you cannot get back to

This is what "the guide editor is not showing up correctly" turned out to mean,
and no amount of staring at the layout would have found it. Scribe is
`LSUIElement`: no Dock icon, and **⌘-Tab skips accessory apps entirely**. The
editor opened fine, slipped behind a browser window, and there was then no way
to reach it — no Dock tile, nothing in the switcher, and the menu-bar item just
re-ran `makeKeyAndOrderFront` on a window that was already "open", which does
nothing visible.

`EditorWindowController.show()` now calls `NSApp.setActivationPolicy(.regular)`
and `windowWillClose` puts it back to `.accessory`, so Scribe has a Dock icon
and a ⌘-Tab entry for exactly as long as that window is open. It also inserts
`.moveToActiveSpace` into the collection behaviour — without that, the window
stays on whichever Space it was opened on and "nothing happens" when you are
looking at another one.

### Going `.regular` means you suddenly need a main menu

The moment the activation policy flips, macOS shows whatever `NSApp.mainMenu`
holds. With none, you get a bare "Scribe" with no Quit, no Close, and — the one
that actually bites — **no Edit menu, so ⌘C / ⌘V / ⌘A are dead in every text
field**, including the step text you are meant to be rewriting.
`AppDelegate.buildMainMenu()` exists solely for those few minutes.

### "Erase Current Guide…" erased nothing, and hid the New Guide button

`Guide.startNew()` — called `reset()` for most of this project's life — points
the guide at a fresh folder and leaves the previous one's screenshots exactly
where they are. It is a **New Guide**, not an erase. It was surfaced as "Erase
Current Guide…" behind a warning sheet that said the steps "will be cleared",
which described something the code has never done.

The cost was not cosmetic: the user went looking for a New Guide button, did
not find one, and asked for it — because the only button that did it was
wearing a label that said it would destroy their work. A destructive name on a
non-destructive action is worse than no button, since nobody presses it.

It is now **New Guide** in three places (menu bar with ⌃⌥⌘N, the editor bar,
and the library) with no confirmation sheet, because there is nothing to
confirm. Actually deleting a guide is the library's **Delete…**, which moves
the folder to the Trash.

### Starting a new guide leaves an empty folder that poisons "most recent"

`startNew()` points at a fresh folder and `save()` would immediately write a
valid, empty `guide.json` into it. That folder is then the newest one on disk,
so a naive "reopen the last guide" faithfully reopens the emptiness it just
created. `Guide.mostRecentFolder()` filters on `hasSteps`, not on the file
existing — and `save()` refuses to write at all until there is a step.

### Editor layout traps, all of which shipped broken once

- **Nothing was ever selected on open**, so the preview pane was a large blank
  rectangle every single time the window appeared. `refresh()` now always
  selects row 0 when there is anything to select.
- **`NSTextField` in a table cell needs `preferredMaxLayoutWidth`.** Without
  it, it lays out on one endless line and truncates instead of wrapping.
- **`NSSplitView` ignores its arranged subviews' width constraints** for the
  initial divider position. It has to be set with `setPosition(_:ofDividerAt:)`
  after the window has a real width — hence `placeDividerIfNeeded()`.
- **Alternating row colours over 96 pt rows** read as random blocks, not
  stripes. Hairline separators instead — and turned off entirely when the table
  is empty, or they read as a list of blank rows.
- **The title field grabbed first responder**, so the window opened with the
  guide name selected as if you were about to retype it.
  `show()` ends with `makeFirstResponder(table)`.

### Window titles leak the author's identity, and truncation makes it worse

A real Chrome title on this machine:

```
Inbox - <account>@<district>.k12.va.us - <District> Mail
  - High memory usage - 2.2 GB - Google Chrome - <Name> (<district>.k12.va.us)
```

The first attempt stripped `" - <appName>"` and truncated at 51 characters.
That worked on one guide and failed badly on another: in Gmail titles the
account sits **before** the app name, so it survived, and the truncation cut it
mid-domain — half an address in every exported step, which is worse than
showing all of it or none.

`GuideStep.contextLine` now splits on `" - "` and judges each segment:
everything from the app name onward is dropped (app name, profile, memory
badge), then each remaining segment is scrubbed of address-shaped tokens. A
parenthesised domain takes its whole segment with it, because `Name (domain)`
is a profile label — but a bare domain does not, so `<District>.k12.va.us Mail`
correctly keeps the `Mail`.

Two traps that fixtures caught and eyeballing did not:

- **A dotted token ending in letters is not necessarily a domain.**
  `Handout.pdf` was being stripped. Two-part tokens now need a real TLD,
  three-plus parts are domain-shaped on their own, and known file extensions
  never count. Window titles are filenames constantly.
- **Truncation has to fall on a boundary.** Whole trailing segments go first,
  then a word break — never a fixed character count.

The line is also *content-aware* about the element name: it is appended only
when it is not an internal identifier (`menuOptions`, `btn-primary`) and not
already visible in the step text. With no note the auto text already reads
`Click "Save" in Preview`, and repeating `Save` underneath is noise.

`--selftest-offline` pins all of this to invented fixtures — no real address
appears in the source. `--dump-context` runs the rule over every guide on disk
and reports only the cleaned output plus a count of anything still
address-shaped, so verifying does not mean re-printing what is being removed.

### Other cursor tools get captured

Scribe excludes only *its own* application from the `SCContentFilter`. The
sibling app CursorGlow, running with `highlightEnabled = 1`, therefore draws a
green ring around the pointer in every Scribe screenshot — next to Scribe's own
red box, which reads as two competing markers. Not a bug in either app; quit
CursorGlow while recording, or add its bundle id to the exclusion list.

### The screenshot must come from before the click

A screenshot taken when the click is *observed* is already too late — menus
have closed, buttons have gone dark, the sheet is up. So a stream runs for the
whole recording at 20 fps and each click takes the newest frame, which is ≤50 ms
old and captured before the click landed. This is the core design constraint;
anything that replaces the stream with per-click screenshots breaks the app's
whole reason to exist.

### One stream per display, not one that follows the pointer

CursorGlow moves a single stream to whichever display the pointer is on.
Scribe cannot: restarting a stream takes long enough that a click just after
moving to the projector finds no frame at all, and a teacher with a projector
is the person this is for. `Capture` keeps a `Box` per `CGDirectDisplayID`.

### Exclude our own *application*, not our own windows

`SCContentFilter(display:excludingApplications:exceptingWindows:)` with our own
`SCRunningApplication` keeps the prompt box out of the next screenshot forever.
The window-ID variant would need re-collecting every time a panel is created,
and the filter is fixed at stream-creation time — the prompt box from step N is
still on screen when step N+1's frame is captured.

### Everything geometric is normalised against the CAPTURED REGION

`GuideStep.click` and `.target` are 0…1, top-left origin, relative to **the
region that was captured** — which since capture scopes landed is often one
window, not the whole screen. Normalising against the display instead is the
easy mistake and puts every highlight at a plausible-looking wrong offset.

The pipeline in `handleClick` is: click point and AX rects arrive in global
coordinates → `Geo.localPoint` / `Geo.localRect` put them in screen-local
points, top-left origin → `captureRegion` decides the region → `Img.crop`
takes that region out of the display frame → `Geo.normalize(…, in: region)`
expresses both against the crop. Change one of those and the others have to
move with it.

Pixel values would survive none of this: not the downscale to `Img.maxEdge`,
not Retina vs non-Retina, not a second display at a different size, and not
cropping.

Three coordinate systems meet in `Geo` — NSEvent (bottom-left, y up),
Accessibility (top-left, y down), CGContext (bottom-left) — and the AX flip
pivots around `Geo.primaryTop`, the *primary* display's top edge, not the
current screen's height. `--selftest-offline` step 3 exercises the whole crop
path against a synthetic display and fails loudly if the click stops landing
inside its own target box.

### Capture scope crops the image; it does not filter the stream

`CaptureScope` is applied by cropping the whole-display frame at click time
(`captureRegion` + `Img.crop`), not by narrowing the `SCContentFilter`. That is
deliberate: the stream must keep running across every app and window because
the pre-click frame has to already exist when the click arrives — rebuilding a
filter per click would reintroduce exactly the latency the stream exists to
avoid. Cropping a CGImage is nearly free; it shares the original's backing
store.

`.app` scope is the one that also *drops* clicks: anything outside the chosen
app returns nil from `captureRegion` and never becomes a step. Everything else
falls back to the whole screen when the window frame cannot be resolved — a
guide with too much in the picture beats a guide with a missing step.

### `DateFormatter` treats every unquoted letter as a field

`f.dateFormat = "MMMM d guide"` renders as **"September 2 24612862026"** — g, u,
i, d and e are all format specifiers. The suggested guide name uses
`setLocalizedDateFormatFromTemplate("MMMMd")` instead, which takes only field
letters, cannot swallow a literal, and gets the locale's day/month order right
for free. Any literal text in a date pattern has to be `'quoted'`.

Worth noticing that this one was invisible in the code and obvious the moment
the panel was photographed. Anything with a rendered surface gets looked at.

### Rendering HTML to a picture, to actually look at it

The terminal cannot screenshot, and the in-app browser refuses `file://`. So
a throwaway `html2png.swift` (not in the repo — write it again when needed)
loads an HTML file in a WKWebView, calls
`createPDF`, and rasterises page one. `createPDF`'s "everything on one enormous
page" behaviour is a bug for the guide PDF export and exactly the right thing
here: it gives one tall image of the whole email. That is how the Gmail
typography problems below were found — none of them were visible in the markup.

### The app icon is generated, not a checked-in binary

`assets/make-icon.swift` draws `assets/icon-1024.png`; `build.sh` turns that one
PNG into `Scribe.icns` with every size macOS wants and sets `CFBundleIconFile`.
Two modes:

```bash
swift assets/make-icon.swift mark      # annotated-screenshot mark (shipped)
swift assets/make-icon.swift badger    # school logo on a light tile
bash build.sh                          # picks up whichever was generated last
```

Scribe is `LSUIElement`, so there is usually no Dock icon at all — but the
editor flips the activation policy to `.regular`, so the icon is on screen for
as long as that window is open, and in the Finder always.

Two things learned drawing it:

- **The supplied logo has a solid white background, not transparency.** That is
  invisible everywhere else, because a web page, an email and a PDF page are all
  white — and a glaring white rectangle the moment it lands on a coloured tile.
- **Knocking the white out does not rescue it on a dark tile.** The badger's own
  face and jersey highlights are the same white as the background, so the
  knockout eats the artwork. The badger tile is light for that reason; the mark
  icon is the dark one.

Changing the icon does not disturb TCC: the bundle identifier and the signing
certificate are what the grant is pinned to, and neither moves. `codesign
--verify --strict` after a rebuild is the check.

### Export themes brand the document, never the annotations

`ExportTheme` colours the title, the step badges, the rules and an optional
logo, across all three exporters. The **annotation** accent stays red: that box
is a wayfinding mark on somebody else's screenshot and has to survive whatever
colours the underlying app uses. A purple box on a purple site is invisible, and
a guide nobody can follow is worse than one that is off-brand.

Every theme gets a three-colour stripe under the header, which is what carries
the branding for a theme with no artwork. In HTML it is a flex bar; in email it
is three `<td>`s with `background-color`, because Gmail keeps solid table cells
far more reliably than borders or flex.

Three traps, all found by rendering rather than reading:

- **The fixed PDF layout reserves a header band on every page**, and it was a
  hardcoded 62 pt. The moment a theme added a logo the header grew past it and
  the first step drew on top of the title. `Export.headerHeight` measures the
  block — logo, title, meta, stripe — and `drawFixed` divides what is left.
  Anything that changes header content has to go through that function.
- **The logo goes into email as PNG, not JPEG.** Screenshots are JPEG because
  they are opaque and enormous. A logo is small and has a transparent
  background, and JPEG has no alpha — encoding it that way puts the mascot in a
  black box in the middle of the message.
- **The stripe adds a fourth line-height (5 px) to the email.** That is
  structural, not typographic; the type scale is still three sizes
  (12/15/20) and three text line-heights (18/22/26).

Adding a theme is one `static let` in `ExportTheme` plus, if it has artwork, a
PNG in `assets/` — `build.sh` copies `assets/*.png` into `Contents/Resources`
and `ExportTheme.logo` looks it up by name. A missing file degrades to a
logo-less header rather than failing the export, so a bad copy is silent; check
Resources if a logo disappears.

### Gmail typography: longhand, and px line-heights

Two rules, both learned from the rendered output:

- **Never the `font:` shorthand.** Gmail rewrites shorthand unevenly — some
  elements keep their size and weight, others silently fall back. That
  inconsistency *is* what "the font sizes look wonky" means. Every rule in
  `emailHTML` is a longhand property.
- **Line heights in px, and the badge shares the text's line box.** The number
  circle is 22 px with `line-height:22px`, and the step text beside it is
  `line-height:22px`. They then align with no `vertical-align` and no padding
  fudge. Unitless line-heights and `vertical-align` both get normalised away by
  Gmail, and the badge drifts off the text.

The whole email uses three font sizes (12/15/20) and three text line heights
(18/22/26); the theme stripe adds a structural `line-height:5px` that is not
type. If a fourth *text* size or height appears, something has drifted.

### Gmail throws away everything `html(_:)` relies on

`Export.emailHTML` shares no code with `Export.html` and must not. Gmail's
composer strips `<style>`, `<head>`, classes, `@media`, flexbox and grid, then
rewrites what is left. So the email renderer is inline `style` attributes on
every element, `<table>` for layout, and `<img width=…>` with the real
attribute — Gmail honours that and ignores much of the CSS around it.

Images are JPEG, not PNG, and downscaled to `emailImageWidth`. The same guide
is 3.8 MB as a standalone page and 68 KB as email; nobody wants the first one
in their inbox.

There is no way to hand Gmail HTML source — pasting is the only route in — so
`copyForEmail` puts the rendered flavour on `NSPasteboard` as `.html` with a
plain-text fallback beneath it. The structural check that matters lives in the
testing section below; the actual paste into Gmail has never been verified from
here and needs a human.

### The render order is load-bearing

`FrameRenderer` (reached through `GuideStep.annotated` for stills) runs:
redact → spotlight dim → highlight (still) *or* pointer + click ripple (GIF
frame) → markup → **crop** → magnifier inset. Covers go on first so nothing
drawn later can be hidden underneath one; the dim before the highlight so the
red box is not dimmed; hand-drawn markup after the automatic mark so a user's
arrow is never buried; crop last so no stored geometry ever needs remapping.
`showHighlight` skips the middle pass — it exists because once you can draw
your own box, the Accessibility guess landing on the wrong control leaves two
markers disagreeing and no way to remove the misleading one.

### Covers and markup are two arrays with one draw order

They render differently (covers replace pixels, markup strokes over them) so
they cannot be one array, but Undo has to pop whichever the user actually added
last. Hence `seq` on both, stamped from `GuideStep.nextSeq`. Click-to-remove
uses the same ordering to decide what is "on top".
`--selftest-offline` adds one of each, undoes twice, and fails if the wrong one
goes first — a bug there is invisible until somebody loses work to it.

### The highlighter's blend mode follows the background

A real highlighter multiplies, which is right over a light UI: the text
underneath stays crisp. Over a dark UI, yellow × near-black is a grey smudge
that reads as broken. So `Annotator.draw` samples the mean luminance under the
stroke (`Img.averageLuminance`, a crop scaled to one pixel) and uses multiply
over light, plain alpha at 0.55 over dark. Do not "simplify" this back to one
blend mode without looking at both cases.

### The name prompt only fires for an empty guide

Starting a recording asks for a name, but only when `guide.isEmpty`. Coming
back to a guide that already has steps is a *resume*, and being asked to rename
it on every pause would be maddening. `Settings.askForGuideName` turns the
prompt off entirely, with a menu toggle so there is a way back — a preference
with no visible switch is a bug.

The panel is the same `.nonactivatingPanel` pattern as the step prompt, and for
the same reason: it must take keyboard focus without activating Scribe over the
app being demonstrated. Escape cancels the recording outright rather than
starting an unnamed one — the hint says so, because a prompt that silently
starts recording when dismissed is worse than no prompt.

### Redaction lives in `FrameRenderer`, and must stay there

`Annotator.redact` is the first pass of `FrameRenderer.compose`, which
`annotated(number:)`, every GIF frame, every export, every thumbnail and the
editor canvas funnel through, so there is no code path that can render a step
and forget to cover it. Move redaction into the exporters and you get four places
that each have to remember — and the one that forgets ships somebody's name.

The mosaic is a downscale-and-redraw with `interpolationQuality = .none`, not a
CoreImage filter: the block size is then an honest guarantee (1/90 of the
longest edge, minimum 14 px, which destroys UI-sized text) rather than a blur
radius that might be unwound.

**`.solid` is the default, deliberately.** Pixelation is a presentation choice —
it says "a name was here", which a tutorial often wants — but shape, colour and
layout survive it and pixelated text of known format has been recovered before.
The feature exists to hide sensitive information, so the safe style is the one
that comes up first in the picker.

### Covers have their own colour, separate from the drawing colour

`Redaction.color` fills a `.solid` bar (a mosaic ignores it) and is saved per
cover; guides from before it existed have no key and load as black. The one
swatch row serves both: `MarkupCanvas.coverColor` (default black) while the
Cover tool is active, `.color` (default red) for everything else, and
`updateSwatches()` rings whichever the active tool uses. One shared colour
would turn the next bar red after drawing an arrow. The swatches grey out for
Cover + Pixelate, where there is nothing to pick. Until this existed every bar
was a hardcoded near-black and the swatches silently did nothing for covers.

### Redacted exports do not mean redacted files

Until "Make Permanent" runs, the PNGs in the session folder still hold the
original pixels — `Guide.flattenRedactions` is what rewrites them. Exports were
always clean; the folder was not. Anyone syncing that folder, handing over the
machine, or sharing a session directory needs the flatten. It is irreversible
and the editor confirms with a sheet.

`--selftest-offline` proves it at the pixel level rather than by inspection: it
samples the stored PNG inside a solid cover before and after flattening and
fails unless the value actually changed to the bar colour.

### Expanding the canvas needs the split delegate to yield

`setPosition(0, ofDividerAt: 0)` does nothing while
`splitView(_:constrainMinCoordinate:…)` still returns 420. The delegate returns
`isExpanded ? 0 : 420`, so the toggle has to flip the flag *before* setting the
position. Expanding also hides the heading and adds ‹ › step buttons — without
those, collapsing the step list traps you on one step, since the list you would
otherwise click is exactly what got collapsed.

### `MarkupCanvas` converts through the image rect, never `bounds`

The preview scales the screenshot to fit and centres it, so there are letterbox
bars on one axis almost always. Every coordinate conversion goes through
`imageRect`; using `bounds` puts a cover at a plausible-looking wrong offset,
which is the same class of bug as normalising against the screen instead of the
captured region. It also draws the image itself rather than subclassing
NSImageView — a layer-backed NSImageView does not reliably call `draw(_:)`, and
the rubber band and outlines have to be drawn over the picture.

### `defer` flushes the PDF too late

`Export.pdf` closed its `CGPDFContext` in a `defer` and called `completion(nil)`
at the end of the body — which runs *first*. Every caller therefore acted on an
unflushed file: the self-test measured five different layouts and got five
byte-identical sizes, and "Show in Finder" would have revealed a partial
document. `closePDF()` now runs explicitly, before the completion handler.
Anything that hands a freshly written file to somebody else has this shape;
check the ordering rather than trusting `defer` to be tidy.

### Four per page is a 2 × 2 grid, and more columns means BIGGER

The intuition is backwards here, so the arithmetic is in
`Export.columns(forPerPage:)`. On US Letter with no logo there are about
508 × 612 pt below the header:

```
4 stacked   slot 508 × 140 → ~104 pt left after the caption,
            so a 16:10 screenshot lands at about 166 × 104
2 × 2 grid  cell 245 × 297 → the image is width-constrained instead,
            about 245 × 153
```

The grid roughly doubles the picture. Two and three per page stay single-column
for the same reason in reverse: stacked, they keep the full width, and that beats
any side-by-side arrangement of the same count.

A grid also needs its rows to line up. `Export.textBlockHeight` measures the
badge-and-caption block exactly as `drawStep` lays it out, `drawFixed` takes the
tallest in each row, and every cell in that row is handed the same
`reservedTextHeight` — so a three-line caption beside a one-line caption still
starts both pictures at the same height. Without it the pictures stagger, which
is what makes a printed sheet look thrown together. Change `drawStep`'s text
layout and `textBlockHeight` has to change with it.

### Centred layout is for the fixed densities only

Once several steps share a page the screenshot is height-constrained, so it
comes out narrower than the column — at four per page that leaves a wide band
of white down the right-hand side. `drawStep(centred:)` centres the number,
text, context and image, and the header follows, so the slot reads as one
deliberate block. The flowing layout stays left-aligned: there the image fills
the column, there is no spare width, and centred body text is harder to read
down a long page.

### PDF page density

`Export.PageDensity` is `.fit` (flowing — each step takes the room its
screenshot wants, breaking to a new page rather than splitting) or `.fixed(n)`
(every page gets exactly n equal slots). Both go through the same `drawStep`,
which fills whatever rect it is handed, so a step looks identical either way and
only the pagination differs.

The fixed layout reserves the header band on *every* page — the big title on
page one, a running head after that. Reserving it only on page one would make
page one's screenshots visibly smaller than the rest. `.fixed(n)` falls back to
flowing when the slot height would drop under 60 pt rather than emitting
unreadable slivers.

The selector is an `accessoryView` on the save panel, not a preference window:
it is a property of this export and you know which one you want while naming the
file. The choice is still persisted, because whoever wants one step per page for
printing usually wants it every time.

### `NSTableView.gridStyleMask` draws past the last row

It runs separators down the whole scroll view, including empty space, so a
short list in a tall window reads as a list of blank rows. Both tables use
`SeparatorRowView`, which draws its own bottom hairline and therefore stops
where the data does.

### Session folders are created lazily

`Guide.newFolder()` returns a path and writes nothing; `ensureFolder()` runs on
the first `append`. Creating it eagerly meant every launch and every erase left
an empty session on disk, which then showed up in the library as a row of
nothing and made "the most recent guide" mean the wrong thing.

### The deepest AX element is usually the wrong one

A click on a button's label lands on an unnamed `AXStaticText` whose parent is
the `AXButton` you actually pressed. `AXInspector.bestLabel` walks up to five
levels for a usable name and boxes *that* element, not the leaf.
`AXUIElementSetMessagingTimeout(…, 0.25)` is set because a beachballing app
under the pointer otherwise blocks the click handler and stutters the whole
recording.

### Reject AX frames that are too big to mean anything

The Accessibility API happily returns the whole window, or the whole screen,
when a click lands on plain background. `Annotator.isUsable` drops anything
over 45% of the screen area, anything sub-pixel, and anything that does not
contain the click. Those fall back to the ring.

### Neither WebKit route produces a usable PDF

Both were tried on this file:

- `WKWebView.createPDF` returns the entire guide as **one page**, however long.
- `WKWebView.printOperation(with:)` **ran away** — 80 MB and still climbing for
  a two-step guide, never returning. It has to be `kill -9`'d.

`Export.pdf` draws into a `CGPDFContext` directly. About a hundred lines, and
it is the only version with control over where a page breaks. Do not
reintroduce WebKit for this.

### Step numbers are burned into the thumbnails

Anything that reorders or deletes has to call `invalidateThumbnail()` on every
affected step — `Guide.renumberThumbnails(from:)` does it. Skipping that leaves
a step visibly labelled with its old number.

### Screenshots go to disk immediately

A full Retina frame is ~30 MB uncompressed; a 40-step guide of those is a
gigabyte resident. Steps hold a URL and a small thumbnail; the annotated
full-size image is rendered on demand. `Img.maxEdge` (1800 px) is the knob.

### No modal dialogs, ever

Inherited from CursorGlow and it still applies: `NSAlert.runModal()` from an
`LSUIElement` app can open **behind** other windows while the app blocks, which
reads as a freeze. Every save panel is a sheet, and the two genuinely
destructive actions — **Make Permanent…** and the library's **Delete…** — use
`beginSheetModal(for:)`. **New Guide** has no sheet at all, because it destroys
nothing. `AXIsProcessTrustedWithOptions(prompt:
true)` is banned — it re-prompts on every call.

### Signing decides whether permissions survive a rebuild

Same as CursorGlow, same reasoning. `build.sh` prefers a `Scribe Dev`
certificate and falls back to the already-trusted `CursorGlow Dev` one rather
than ad-hoc — one self-signed root is enough for both apps. If the build prints
the `!!` ad-hoc warning, stop and fix it; everything downstream will mislead
you. Verify with `codesign -dvvv Scribe.app`, and expect
`Authority=CursorGlow Dev`.

### You cannot self-test the click path

Synthetic `CGEventPost` events are invisible to `NSEvent`'s global monitor,
exactly as they are to CursorGlow's key tap. `--selftest-offline` covers
annotation, geometry, persistence, all three exports, and building the editor
window. The click monitor and the prompt box need a real human click.

### Mouse global monitors need no permission

`NSEvent.addGlobalMonitorForEvents` for mouse-down works with nothing granted
(unlike keyboard monitors). So clicks are always captured; only the *names* of
what was clicked need Accessibility.

### GIF steps: one region, one coordinate space

A GIF step is an ordinary step (still, click, target, text) plus footage in
`gif-NNN/` beside `shot-NNN.png`: `clip.json` (`ClipData` — frames, a 30 Hz
pointer track, clicks; immutable) and `frame-0001.jpg…`. What the user edits
(trim, pointer on/off) is `GifClip` on the step in `guide.json`.

The region is decided at **Fn-down** from what is under the pointer, through
the same `captureRegion` a still uses, and every frame *and* the still are the
same crop at the same pixel size. That is what lets a step flip between GIF and
screenshot, and lets covers, drawings, crop and spotlight apply to every frame
unchanged. The still comes from the first click's pre-click frame, exactly as
a still step's does. Deciding the region at the first click instead, or storing
full-display frames and cropping later, breaks one or the other.

Shots and clips share one file-number sequence (`Guide.reserveFileNumber`),
derived from the highest `shot-NNN` / `gif-NNN` on disk — never `steps.count`,
which after a delete and reopen handed out a live step's number and
overwrote its picture.

### Fn is polled, never observed

A global `flagsChanged` monitor is a keyboard monitor and needs Input
Monitoring. `FnMonitor` polls `NSEvent.modifierFlags` + the CGEventSource flag
state at 30 Hz on a `.common`-mode timer (a default-mode timer stops while a
menu is open — exactly when a menu demo is being held). 150 ms to count as
down, 80 ms as up. Confirmed on this Mac in a real recording (2026-09-25).

Arrows, Home/End, Page Up/Down, forward delete and F-keys carry the
`.function` flag too, so a hold does not *start* while one of those is down
(`FnMonitor.flaggedKeyHeld`). The Globe key's own action (emoji picker by
default) still fires on release; a one-time notice says to set
"Press 🌐 key to" to Do Nothing, or use ⌃⌥⌘F (press on / press off).

Frames: ≤10 fps, **one in flight** on a serial queue — a frame arriving while
the writer is busy is dropped, not queued, because queued frames pin IOSurfaces
from the stream's pool (hence `queueDepth` 5). `finish()` writes the newest
frame at release so a dropped frame cannot cut off what the last click did.
A no-click hold under 0.7 s is discarded as a brush of the key. 15 s cap.
The HUD is Scribe's own window, so the app-level capture exclusion keeps it
out of the footage.

### "Record Clicks" gates steps on a held key

`Settings.clickGate` (`ClickGate`): every click, or only clicks with Right
Option / Right Command / Right Shift held, or with Caps Lock on. Left and right
are told apart by IOKit's device-dependent bits in the low 16 bits of the raw
modifier flags (`NX_DEVICERALTKEYMASK` 0x40 etc.); the event's own flags are
OR'd with `CGEventSource.flagsState` in case one lags. The held key is stripped
from the step's verb unless its left-hand twin is also down. Control is never
offered (Control-click is a right-click) and Fn is GIF steps — Fn clicks bypass
the gate. The app being recorded still receives the modifier; that trade-off is
why the key is the user's choice. One HUD flash per recording on the first
ignored click, so a forgotten key is noticed without nagging.

### The GIF encoder, and what it does not buy

`GifEncoder` is a custom GIF89a writer: one global median-cut palette with the
accent red, white, cursor colours and the step's own drawing colours forced in
exactly, no dithering, delta frames with transparency, identical frames merged,
centisecond delays with carried rounding, and a stable-index pass so JPEG noise
does not shimmer flat areas. It is only ~10% smaller than ImageIO — on current
macOS ImageIO already writes a global palette and delta frames. What the
custom one buys is exact colours, bounded memory (frames stream through) and
bailing out early when over an email budget. Forced colours must be rendered
through the same DeviceRGB→sRGB path as the frames, or they are off by the
conversion.

### Rendering is off-main, from value snapshots

`GuideStep` is `@MainActor`; `RenderSpec` is a Sendable snapshot of everything
a render needs. Exports encode GIFs from specs off the main thread
(`Export.prepareGIFs`, `prepareFilmstrips`) and build the document on main.
Text in `Annotator` is drawn with Core Text, not `NSAttributedString.draw`,
so renders are thread-safe — the self-test compares a background render to a
main-thread one byte for byte. `FrameRenderer.frame(maxEdge:)` caps the
**output** (after crop), not the source.

### Exports carry GIFs as far as each format allows

HTML: `<picture>` with the still for `prefers-reduced-motion`. Email: GIF at
1× (600 px, 8 fps), 1.5 MB per GIF and 10 MB per message, falling back to the
JPEG still plus "(animation in the web version)". Markdown: `step-NNN.gif`.
PDF: a filmstrip of key frames (just after each click, plus trim start/end,
≤4) as a row with "›" or a 2×2 grid, whichever gives bigger frames —
`Export.mediaAspect` measures what will actually be drawn, and pagination uses
it. Whether Gmail keeps a pasted `data:image/gif` animated is **unverified**.

### Crop and spotlight are stored against the uncropped image

`GuideStep.crop` and `.spotlight` are 0…1 against the stored image, like every
other piece of geometry; the canvas maps view ⇄ cropped ⇄ stored
(`stored = crop.origin + shown × crop.size`). The one exception is
`Spotlight.inset`, which is relative to the cropped output. The editor
hit-tests the magnifier with `FrameRenderer.magnifierFrame` — the same function
the renderer places it with; two copies of that arithmetic drifted apart once.
"Use as Still", "Replace Image" and crop are non-destructive: new files beside
the old ones, and `originalImageName` keeps the way back. Make Permanent
rewrites every frame JPEG as well as the stills.

### Studio editor traps

- **NSWindow answers `undo:` itself**, so Edit ▸ Undo never reached the
  controller. `EditorWindow` keeps typing undo while text is being edited and
  otherwise hands ⌘Z to the controller's undo stack, which orders drawings
  against step deletions (Backspace in the list deletes; ⌘Z restores).
- **Button key equivalents fire before the first responder**, even inside a
  text view — Space, Return and Esc go through a local key monitor that skips
  text editing.
- **NSSplitView's constrain delegate methods switch it to the old resize
  path**, which shrinks every pane in proportion. `shouldAdjustSizeOfSubview`
  returns true for the centre pane only. Expand *hides* the side panes.
- **Views do not clip to bounds on macOS 14+** — fill `bounds`, not `dirtyRect`.
- **`Guide.changed(kind, index)`** posts what changed; text edits reload one
  row and never overwrite the inspector's text view while it is first
  responder. Notifications without userInfo mean "structure".
- **`NSApp.sendAction(to: nil)` goes to the key window**, which a
  terminal-launched self-test often is not; tests walk
  `window.firstResponder` instead.

## Permissions summary

| Feature | Needs |
|---|---|
| Hotkeys, menu, editor, exports | nothing |
| Capturing a click as a step | nothing (the click itself) |
| The screenshot | **Screen Recording**, plus one relaunch after granting |
| `Click "Save" in Preview` instead of `Click in Preview`, and a box instead of a ring | **Accessibility** |

## Debugging method that works

1. `cat scribe.log` — trust state, preflight, capture dimensions, every
   self-test stage, and SCK errors with full text.
2. `bash doctor.sh` — signing identity, duplicate copies, crash reports, TCC
   log, latest session folder.
3. Only then change code.

## Known issues / next steps

- **Capture and the prompt box are both confirmed working** as of the first
  real recordings (2026-09-01): `capture stream started … 3456x2234`,
  `prompt box key window: true`, two guides recorded and exported. The
  `.nonactivatingPanel` does take keyboard focus as intended.
- **Step deletion is undoable only while the editor stays open** (⌘Z); the
  files stay in the session folder either way.
- **GIF steps need a human for:** the 15 s cap, ⌃⌥⌘F, Fn inside a password
  field (Secure Input), a clip on a second display, and pasting a GIF email
  into Gmail. A single Fn-held clip has been recorded for real and works.
- **A plain click inside the 80 ms Fn-release debounce** ends the clip and
  becomes a normal step; the GIF step then gets no prompt of its own.
- **The Gmail paste is unverified.** `emailHTML` is checked structurally (no
  `<style>`, no classes, tables, JPEG data URIs, `width` attributes) and the
  clipboard round-trips, but nobody has pasted it into a real compose window
  from here. Whether Gmail inlines the data URIs as attachments or drops them
  is the open question.
- **Markup is not selectable or movable.** You can add and remove, not drag an
  existing arrow to a new place. Removing and redrawing is the whole editing
  model.
- **Redaction is by rectangle only.** There is no "cover this element" using
  the Accessibility tree — only the clicked element's frame is stored, not
  every element's, so an element picker would need a fresh AX walk against a
  window that has since changed. Rectangles are what the editor can honestly
  offer against a saved screenshot.
- **Nothing is redacted automatically.** Password fields, account chips and
  sidebars all have to be covered by hand. `applyRedactionsEverywhere` is the
  mitigation for the repetitive case.
- **Capture scope has not been exercised against a real recording.** The crop
  maths is covered by `--selftest-offline` step 3; the AX window frames it
  depends on are not.
- **Keyboard steps are not recorded.** Real Scribe captures typing as a step
  ("Type your email address"). Clicks only, by scope decision.
- **US Letter only** for PDF export, and a step that will not fit in the
  remaining space breaks to a new page rather than shrinking — correct, but it
  leaves visible whitespace.
- **Distribution is unresolved.** A self-signed certificate is enough for this
  machine and nobody else's.

## Testing

No automated tests; verification is the two self-tests plus a manual pass:

1. `bash build.sh` prints the stable-identity line.
2. `open Scribe.app --args --selftest-offline` ends in `SELFTEST-OFFLINE PASSED`
   with two annotated PNGs, an HTML, a Markdown folder, and a 2-page PDF in the
   session folder.
3. `open Scribe.app --args --selftest` ends in `SELFTEST PASSED` — this is the
   one that proves Screen Recording.
4. `⌃⌥⌘R`, click three things in another app, `⌃⌥⌘R` again: the editor opens
   with three steps, each screenshot showing the state *before* its click, each
   highlight on the right control.
   Then click another app to bury the editor and press `⌃⌥⌘E` — it must come
   back to the front. A Dock icon must appear while it is open and vanish when
   it closes.
5. The prompt box appears next to each click and accepts typing; `return` saves,
   `esc` skips, and clicking on without touching it never stalls the recording.
6. `⌃⌥⌘G` lists every guide with the live one badged CURRENT. Opening one
   loads it into the editor; opening one *while recording* must be refused.
7. Capture Area ▸ Window You Click In, record two clicks in a browser: the
   screenshots must be the browser window, not the desktop. Then pin it to one
   app and click elsewhere — those clicks must not become steps.
8. "Copy for Gmail" then ⌘V into a compose window: numbered steps, images, no
   raw markup. Check the structural invariants first if it looks wrong:

   ```bash
   python3 -c "h=open('/path/to/guide (email).html').read(); print(h.count('<style'), h.count('class='), h.count('<table'))"
   ```

   All three should read `0 0 3`-ish — any `<style>` or `class=` means the
   renderer regressed toward `Export.html`.
9. Export a PDF at each **Steps per page** setting. For a 3-step guide that is
   3, 2, 1, 1 pages for 1/2/3/4-per-page, and the running head reads
   "<title> · page N" from page two on. `--selftest-offline` writes all four
   next to `selftest.pdf`; count pages without Spotlight, which does not index
   them promptly:

   ```bash
   python3 -c "import re,sys;d=open(sys.argv[1],'rb').read();print(len(re.findall(rb'/Type\s*/Page[^s]',d)))" selftest-1-per-page.pdf
   ```

   To *look* at a page other than the first — `sips` and `qlmanage` only ever
   render page one — there is a throwaway CoreGraphics renderer pattern:
   `CGPDFDocument.page(at:)` into a bitmap context, run with `swift file.swift`.
10. Drag on the preview: a cover appears, the caption counts it, and the row
    thumbnail updates. Click it to take it away. **All Steps** copies it to
    every other step. Export and confirm the cover is in the output.
    **Make Permanent…** then rewrites the stored PNGs — check with:

    ```bash
    open "$HOME/Library/Application Support/Scribe/<session>/shot-001.png"
    ```

11. Pick each tool and drag on the preview: arrow, line, box, circle, pen,
    marker, text (which opens an inline field; ↩ places it, esc cancels).
    Click any of them to remove it. Undo must remove the most recent thing
    regardless of which kind it was. **Expand** gives the picture the window;
    ‹ › move between steps while it is expanded.
    `--selftest-offline` renders one of every tool into `annotated-02.png` and
    turns the auto highlight off on step 3 — look at both.
12. `⌃⌥⌘R` on an empty guide asks for a name; return starts recording with it,
    escape starts nothing. `⌃⌥⌘R` on a guide that already has steps must *not*
    ask. Turning off "Ask for a Name When Recording" must stick and be
    switchable back on.
13. **Copy for Gmail** into a real compose window. Then check the rendering
    without Gmail:

    ```bash
    swift scratchpad/html2png.swift "guide (email).html" out.png 700
    ```

    Three font sizes, three line heights, the number badge sitting on the first
    line of its step text, and a full-width divider between steps.
14. **New Guide** — from the menu (⌃⌥⌘N), the editor bar, and the library —
    empties the editor and leaves the previous guide in the library with its
    steps intact. It must be refused mid-recording, and be a no-op with a note
    when the guide is already empty.
15. **Export Theme ▸** each theme, then export a PDF at 2-per-page and Copy for
    Gmail. Logo and stripe in the header, badges in the accent colour, and the
    red highlight on the screenshots *unchanged*. `--shot-themes` writes all
    three at once.
16. `--selftest-media`, `--selftest-gif` and `--shot-studio` (with
    `SCRIBE_DATA_ROOT` set) each end in `… PASSED`; look at `studio-*.png`.
17. Record, hold Fn, click twice, release: one GIF step (orange status item
    and HUD while held), one prompt after release, the still showing the
    screen *before* the first click. Hold ↓ for two seconds while recording:
    no GIF starts. ⌃⌥⌘F starts and stops a clip without Fn.
18. In the editor, on a GIF step: Space plays, the trim bar trims, Use as Still
    / Revert Still, Screenshot ⇄ GIF, Crop… then Apply, Spotlight Dim and
    Magnify (drag the inset), Replace Image from the clipboard. Backspace in
    the list deletes a step and ⌘Z brings it back.
19. Export all four formats from a guide with a GIF step: the web page
    animates, Markdown has `step-NNN.gif`, the PDF shows a filmstrip, and
    Copy for Gmail pasted into a real compose window — record whether the
    GIF animated.
20. **Record Clicks ▸ Only While Holding Right ⌥ Option**, record: plain
    clicks make no step (one "Not recorded" flash), Right-Option clicks do, and
    their text reads "Click …", not "Option-click …". Left Option alone does
    not count.
21. `scribe.log` has no `FAILED` lines.
