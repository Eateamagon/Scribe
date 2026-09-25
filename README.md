# Scribe

Record a workflow by doing it. Get a numbered, screenshotted how-to guide out
the other end.

A local recreation of what [scribehow.com](https://scribehow.com) does, for
macOS, as a single-file Swift menu-bar app. Not the commercial product, and
nothing to do with AI "scribe" note-takers.

## What it does

While recording, every click you make becomes a step:

1. A screenshot is captured **from just before the click**, so the reader sees
   the screen they will be looking at when it is their turn.
2. The thing you clicked gets a red box around it — or a ring, if macOS would
   not tell us the control's frame — plus a numbered badge.
3. A small floating box appears next to the click so you can type what that
   step was for. Typing is optional: ignore it and keep clicking, and the step
   keeps an automatic sentence like `Click "Save" in Preview` that you can
   rewrite later.

When you stop, the guide editor opens: reorder steps, delete the mis-clicks,
rewrite the text, then export to a web page, a PDF, or a Markdown folder.

## Quick start

```bash
bash build.sh
```

```bash
open Scribe.app
```

Scribe lives in the menu bar — there is no Dock icon and no main window.

Starting a recording asks what to call the guide. Type a name and press return
to begin; escape backs out without recording. It only asks for a *new* guide —
picking a half-finished one back up just carries on. If you would rather it
never asked, switch off **Ask for a Name When Recording** in the menu.

| Shortcut | Does |
|---|---|
| `⌃⌥⌘R` | start / stop recording |
| `⌃⌥⌘E` | open the guide editor, or bring it back to the front |
| `⌃⌥⌘G` | open the guide library — every guide you have recorded |

Both are Carbon hotkeys, which need no permissions, so you can always stop a
recording even if everything else has been refused.

While recording, the menu bar shows a red dot and the step count.

The menu also has:

| Item | Does |
|---|---|
| **Ask for a Name When Recording** | Whether starting a new recording prompts for a title. On by default. |
| **Capture Area ▸** | What ends up in each screenshot. See below. |
| **New Guide** (`⌃⌥⌘N`) | Starts an empty guide. The current one is saved and stays in the library — nothing is thrown away, so it does not ask. Also a button in the editor and in the library window. |
| **Reopen Last Guide** | Loads the most recent recording back into the editor — what gets your guide back after quitting. |
| **All Guides…** | The library window: every guide on disk, newest first, with the live one badged. |

Scribe normally has no Dock icon. It grows one while the editor is open, so the
window has somewhere to come back from, and drops it again when you close the
window.

## The app icon

Generated, not hand-drawn, so it can be changed by editing numbers:

```bash
swift assets/make-icon.swift mark
```

```bash
swift assets/make-icon.swift badger
```

`mark` is an annotated screenshot — a card with a red highlight box and a step
number, which is what Scribe makes. `badger` puts the school logo on a light
tile. Run either, then `bash build.sh` to pick it up.

Scribe normally has no Dock icon at all; you will see this one in the Finder,
and in the Dock for as long as the editor window is open.

## School branding

**Export Theme** in the menu puts your school's colours — and logo, where there
is one — on every export: the web page, the PDF, and the Gmail copy.

| Theme | Looks like |
|---|---|
| **Scribe (default)** | The plain red-accented look. |
| **Kate Collins (Badgers)** | Purple and black, with the badger logo above the title. |
| **Waynesboro Public Schools** | Blue, orange and green. Colours only — no logo file yet. |

Every theme draws a three-colour stripe under the title, which is what carries
the branding when a theme has no artwork.

**The red highlight on the screenshots does not change.** That box marks where
to click on somebody else's screen, and it has to stay visible whatever colours
that screen uses — a purple box on a purple website is invisible, and a guide
nobody can follow is worse than one that is slightly off-brand.

Adding another school is a few lines plus a PNG in `assets/`.

## Choosing what gets captured

**Capture Area** in the menu decides how much of the screen each step shows.
A full-desktop shot of a browser tutorial is mostly wallpaper, dock and menu
bar, and the reader has to hunt for the part that matters.

| Option | What you get |
|---|---|
| **Window You Click In** *(default)* | Each screenshot cropped to whichever window the click landed in. Best for most guides. |
| **Whole Screen** | The entire display, dock and menu bar included. |
| *…then a list of running apps* | Only that app. Clicks anywhere else are **ignored entirely** and never become steps, and shots are cropped to its window. For a guide about one tool. |

The app list is built fresh each time you open the menu, from whatever is
actually running, so it stays short. Cropping needs Accessibility; without it,
or for an app that does not report its windows, a step falls back to the whole
screen rather than being dropped.

## The guide library

`⌃⌥⌘G`, or **All Guides…** in the menu. Every guide you have recorded, newest
first, each with its first screenshot, step count and date. The one currently
loaded is badged **CURRENT**.

**New Guide** starts an empty one without touching what is already there.

Select one and **Open in Editor** makes it the live guide — refused while a
recording is running, so a recording in progress cannot have the guide swapped
out from under it. **Show in Finder** opens its folder. **Delete…** moves the
folder to the Trash, so it is recoverable.

A guide only appears here once it has at least one step; an empty guide writes
nothing to disk.

## Drawing on a screenshot

Select a step, pick a tool under the preview, and **drag on the picture**.
**Click anything you drew to remove it** — one gesture, whatever tool is
selected.

| Tool | Draws |
|---|---|
| **Cover** | Hides something. See *Hiding sensitive information* below. |
| **Arrow / Line** | Point at the thing you are describing. |
| **Box / Circle** | An outline where you want one. |
| **Pen** | Freehand. |
| **Marker** | A translucent highlighter wash that leaves the text readable. |
| **Text** | Click, type a label, press ↩ to place it. |

Pick a colour from the swatches. **Undo** removes the last thing you added —
cover or drawing, whichever it actually was. **Clear** removes everything on
the step.

**Expand** hands the whole window to the picture, which is what you want for
anything fiddly; the ‹ › buttons move between steps while it is expanded, and
**Show Steps** puts the list back.

**Auto highlight** turns off Scribe's own red box or ring for that step. Use it
when the automatic guess landed on the wrong control and you have drawn your
own — otherwise you get two markers disagreeing with each other.

Drawings are stored with the guide, so they survive quitting and reopening, and
they are applied everywhere a step gets drawn — the preview, the row
thumbnails, and all four exports.

## Hiding sensitive information

The **Cover** tool hides anything you do not want in the guide — a student
name, an email address, a grade.

| Control | Does |
|---|---|
| **Solid bar** *(default)* | A flat bar. Nothing survives it. Black unless you pick another swatch while Cover is selected. |
| **Pixelate** | A coarse mosaic. Says "a name was here" without showing it. |
| **Covers → All** | Copy this step's covers onto every other step — for a sidebar or header that appears in all of them. Drawings are not copied. |
| **Make Permanent…** | Write the covers into the saved screenshots. See below. |

There is no way to export a guide and have a cover quietly not be in it.

**Pick Solid bar for anything that actually matters.** Pixelation is a
presentation choice, not a security one: shape, colour and layout survive it,
and pixelated text has been recovered before. It is fine for hiding clutter.

### Covers vs. the files on disk

A cover is drawn when a step is rendered. Until you use **Make Permanent…**,
the screenshots saved in the session folder still contain the original pixels —
your exports are clean, but the folder is not.

That matters if you sync that folder, hand the machine on, or share a session
directory. **Make Permanent…** rewrites those files with the covers burned in.
It cannot be undone, and it asks first.

## Permissions

Scribe asks for two, and does something useful with one, none, or both.

| Grant | Without it |
|---|---|
| **Screen Recording** | No screenshots — nothing works. This one is required. |
| **Accessibility** | Steps still capture, but say `Click in Finder` instead of `Click "New Folder" in Finder`, and you get a ring instead of a box. |

Grant them in **System Settings › Privacy & Security**, under *Screen &
System Audio Recording* and *Accessibility*. The menu shows `✓` / `✗` for each.

macOS records a refusal permanently: if you ever click "Don't Allow", no code
change gets past it and the switch may even look ON while access is denied.
Clear it and grant again:

```bash
tccutil reset ScreenCapture com.ethantruslow.scribe
```

If `tccutil` says *no such bundle identifier*, register the app first:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/ClaudeCode/Scribe/Scribe.app
```

## Stable signing

`build.sh` signs with a self-signed certificate — `Scribe Dev` if you have
one, otherwise the `CursorGlow Dev` certificate already trusted on this
machine. Either is fine; what matters is that it is **not** ad-hoc.

Ad-hoc signing (`codesign --sign -`) derives the app's identity from a hash of
the binary, so every rebuild is a different app as far as macOS is concerned,
and your permission grants silently stop applying. If `build.sh` prints the
`!!` ad-hoc warning, fix it before doing anything else:

```bash
bash make-cert.sh
```

## Where recordings live

`~/Library/Application Support/Scribe/<timestamp>/`

One folder per guide: the raw screenshots as `shot-NNN.png`, plus `guide.json`
rewritten after every step. Nothing is deleted when you start a new guide, so a
crash or a misclicked "New Guide" costs you nothing.

## Exports

| Format | Shape |
|---|---|
| **Copy for Gmail** | Puts the whole guide on the clipboard, formatted. Open a compose window and press ⌘V. |
| **Web page** | One `.html` file with the images base64'd inside it. Nothing to lose track of when you send it. Prints cleanly from a browser. |
| **PDF** | US Letter, drawn directly, one step never split across a page break. Choose **steps per page** when you save. |
| **Markdown** | A folder: `guide.md` plus `images/`. Markdown cannot carry its own pictures. |
| **Email HTML file** | The Gmail-safe version as a file, for when you would rather open it, select all and copy by hand. |

### Steps per page in a PDF

The save panel has a **Steps per page** menu:

| Setting | What you get |
|---|---|
| **As many as fit** *(default)* | Each step takes the room its screenshot wants, breaking to a new page rather than being split. Best for reading on screen. |
| **1 / 2 / 3 per page** | Every step gets an identical full-width slot, stacked down the page and centred. |
| **4 per page (2 × 2)** | A grid — two across, two down. The pictures come out about twice the size they would stacked, and each row lines up even when one caption is longer than its neighbour. The compact reference sheet. |

Pages after the first carry a small running head with the guide title and page
number, so loose printed pages still say what they belong to. If a fixed count
would squeeze the steps too small to read, the export quietly falls back to the
flowing layout. Your choice is remembered for next time.

### Sending a guide by email

**Copy for Gmail**, then ⌘V into a Gmail compose window. Pasting is the only
way in — Gmail has no "paste HTML source" — so the button puts the *rendered*
guide on the clipboard rather than markup.

Under each step you get the window name and, when it adds anything, the name of
the thing you clicked. Browser titles are a dumping ground — Chrome appends your
signed-in address, your profile name, and a memory badge — and none of that
belongs in something you send to a colleague, so it is stripped out. A guide you
share does not carry your email address.

Gmail throws away stylesheets, classes and modern layout, so this export is a
different animal from the standalone web page: every rule is written inline,
the layout is plain tables, and the screenshots are JPEG rather than PNG. That
last one matters more than it sounds — the same five-step guide is about 3.8 MB
as a web page and about 70 KB as email.

It looks plainer than the web page on purpose. Plain is what arrives intact —
three font sizes, one column, and the step numbers sitting on the same line as
their text.

## Checking it works

```bash
bash doctor.sh
```

```bash
cat scribe.log
```

Two self-tests, both of which log every stage and quit:

```bash
open Scribe.app --args --selftest-offline
```

Runs the whole pipeline against a synthetic frame — annotation, geometry,
persistence, all three exports, and the editor window. Needs no permissions.

```bash
open Scribe.app --args --selftest
```

The same, but starting from a real captured frame. Needs Screen Recording, and
is the only way to check capture without recording something by hand.

Neither can test the click monitor or the prompt box: synthetic mouse events
are invisible to a global monitor, so those need a real click.

To look at the editor without opening it yourself — the terminal cannot take
screenshots without its own Screen Recording grant, but the app can:

```bash
open Scribe.app --args --shot-editor
```

Writes `editor-shot.png` beside the app and dumps every view's frame to the log.

## Known limits

- **Other cursor tools end up in the screenshots.** Scribe leaves its own
  windows out of the capture, but not anyone else's. CursorGlow with its
  highlight on draws a green ring around the pointer in every Scribe
  screenshot, next to Scribe's own red box — two markers saying different
  things. Quit CursorGlow while recording, or say the word and Scribe can
  exclude it too.
- **The prompt box takes keyboard focus** while you type in it. It is a
  non-activating panel, so the app you are demonstrating keeps its window
  order, but the caret does move. Ignore the box entirely if that gets in the
  way and write the steps afterward in the editor.
- **No undo.** Deleting a step and erasing a guide both take effect
  immediately. Nothing is truly lost — the screenshots stay on disk, the
  library lists every guide, and its Delete moves folders to the Trash.
- **The Gmail paste has not been tested against a real compose window.** The
  export is checked against Gmail's documented restrictions and the clipboard
  round-trips correctly, but whether Gmail keeps the embedded images when you
  paste is the one thing that needs a human. If they vanish, use **Export ▸
  Email HTML file** and copy from a browser instead.
- **Capture cropping needs Accessibility** to know where a window is. Without
  it every step falls back to the whole screen.
- **Covers are rectangles you draw, not elements you pick.** Scribe cannot
  offer "cover this button" after the fact — it only recorded the frame of the
  thing you clicked, not of everything else on screen.
- **Drawings cannot be moved or resized once placed.** Click to remove and draw
  it again.
- **Nothing is covered automatically.** Password fields and account chips are
  not detected; you have to spot them. **All Steps** at least means you only
  have to spot each one once.
- **US Letter only** for PDF export.
- **Distribution is unresolved.** A self-signed certificate is enough for this
  machine and nobody else's. Handing the app to a colleague means a paid
  Developer ID plus notarization, or they hit Gatekeeper and re-grant both
  permissions themselves.
