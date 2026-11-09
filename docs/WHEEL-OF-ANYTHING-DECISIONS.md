# Wheel of anything — decisions

Decisions made while building the smart wheel (part 1) and custom petals (part 2), with the reason for each.
The work ran unattended, so where a choice was open the safest option was taken and written down here.

## Feasibility experiment (2026-11-09, macOS 27.0.1, Safari, Chrome, TextEdit)

`DragMonitor` finds drags by polling the system drag pasteboard (`NSPasteboard(name: .drag)`): its change
count moves when any app starts a drag, and the monitor reads it while the mouse button is down. A throwaway
monitor (same polling as `DragMonitor`, 60 Hz) dumped every type on that pasteboard while a throwaway driver
made real drags with synthesized mouse events in real apps (a local HTML page, so nothing touched the network):

| Drag | Seen mid-drag | Types on the drag pasteboard | Read time |
|---|---|---|---|
| Selected text, TextEdit | yes | `public.utf8-plain-text` | 2 ms |
| Selected text, Safari | yes | `public.utf8-plain-text`, `public.rtf`, `public.html`, `com.apple.webarchive` | 2 ms |
| Selected text, Chrome | yes | `public.utf8-plain-text`, `public.html` | 8 ms |
| Link, Safari | yes | `public.url` (the href), `public.utf8-plain-text`, `public.url-name` | 3 ms |
| Link, Chrome | yes | `public.url`, `public.utf8-plain-text`, `public.html` | 0 ms |
| Image, Safari | yes | `public.png` (33,942 bytes — the original file, byte for byte), `public.tiff`, a file promise (`promised-file-content-type = public.png`), `public.url` (the image's address) | 20 ms |
| Image, Chrome | yes | `public.png` (original bytes), a file promise, `public.url` (image address) | 7 ms |

Every drag was seen while the button was still down, the same way file drags are, so the wheel can open
under the pointer during the drag exactly as it does today. All four content types are **reliably
detectable**; none needed the Services/Shortcuts-only fallback.

What this decided:

- **Order of detection: files → image bytes → link → text.** A browser image drag also carries the image's
  address as `public.url`, so pictures must win over links. Text that is a single `http(s)` address is treated
  as a link.
- **Image bytes are read at drop time, not while sniffing.** Safari also offers a 925 KB TIFF; reading bytes on
  every drag would cost time for drags that never open the smart wheel. Sniffing only checks the type list.
  The original encoded bytes (PNG/JPEG/HEIC/GIF) are preferred over the TIFF conversion.
- **Promise-only pictures are not supported** (e.g. the Photos app, which sends a file promise without bytes).
  Both browsers tested put real bytes on the pasteboard, so promises were left out rather than built untested.
  README says so.
- Experiment artifact, not a limitation: after cancelling an image drag with Escape, the next drag from the same
  Safari page reported the image again until the page was reloaded (WebKit reuses its cancelled drag). Normal
  drags (dropped, not cancelled) are unaffected; it only affected the test driver.

## Modifier key

- Smart wheel default: **⌥ Option**. The existing wheels use ⇧, ⌘ and ⌃; ⌥ was free. macOS gives ⌥ a meaning
  during a Finder drag (copy instead of move), just as ⌘ (move) already has one for the Tools wheel, and the
  wheel only ever accepts drops as copies, so nothing moves or is deleted. No system shortcut is a bare ⌥ tap.
- If an upgraded install already uses exactly ⌥ for another wheel, the smart wheel starts with no key (shown as
  "None" in Settings) instead of silently colliding; Settings' existing conflict check covers new choices.

## Petals

- **Reuse instead of duplicate:** Extract Text and Read QR Code on images are the existing tools; Copy Path on
  files is the existing file action; Strip Metadata runs the existing metadata tool with "remove all".
- **Web archive / PDF of a link: left out.** Saving a page means downloading it, and the brief forbids network
  calls. The link petals instead save a `.webloc` (a link file, made locally), copy a clean link, and make a QR
  code.
- **Private window:** there is no system API for "open in a private window". The petal appears only when the
  default browser is one that takes a private-window launch argument (Chrome, Brave, Edge, Vivaldi, Opera,
  Firefox). Safari has no such argument (only an Automation script, which needs a permission prompt), so with
  Safari as default browser the petal is hidden.
- **Translate** needs macOS 26's `TranslationSession(installedSource:target:)`, which only works with languages
  already downloaded to the Mac, so translation stays on device. WheelConvert checks in the background which
  languages are installed for the person's language and shows the petal only for text in one of those.
- **Summarise** uses `SystemLanguageModel` (the on-device model, macOS 26) and only when it reports
  `.available`. The Private Cloud Compute model in the same framework is never used. Text over 8,000
  characters doesn't get the petal (the on-device model's context is ~4,000 tokens) rather than silently
  summarising only part of it.
- **Remove Background** needs macOS 14 (`VNGenerateForegroundInstanceMaskRequest`); hidden on 13.
- **Hash:** separate SHA-256 and MD5 petals; each copies the digest (one file) or `shasum`-style lines (several).
  **Verify** asks for the expected checksum in a small dialog, pre-filled from the clipboard only if the
  clipboard holds something checksum-shaped; the algorithm follows from the length (MD5, SHA-1, SHA-256,
  SHA-512). Reading the clipboard only happens after the person drops on Verify.
- **QR code** capacity: QR version 40 at error correction M holds 2,331 bytes; longer text doesn't get the petal.
- **Results of content without a file** (text, links, browser pictures) are saved where Settings → Save results
  says, and "next to the original" means Downloads, since there is no original folder.
- **Petal limit:** the smart wheel shows at most 12 petals (image files: 6 picture petals + 6 file petals),
  trimmed with `prefix` like presets on the Convert wheel; the ring grows the way it already does past 8.

## Part 2 — custom petals

- **Where they appear:** on the smart wheel (the fourth wheel), after the built-in petals, for content they accept.
  At most 6 custom petals per wheel (as with presets on the Convert wheel); they take room from the built-in petals
  so the wheel never exceeds 12.
- **Kinds:** run a Shortcut (`/usr/bin/shortcuts run`), run a zsh script, open with an app, open a URL.
- **No import/export of petal packs.** The brief allows leaving it out, and leaving it out removes the main way
  someone else's command could arrive. Petals exist only because the person typed them in Settings → Custom.
- **Approval:** before a petal's first run, and again after any change to what it runs (script, Shortcut name, app,
  URL template, time limit), a dialog shows the exact action and what is passed in. Return cancels; running needs a
  deliberate click on Run. The approved text is stored with the petal.
- **How items reach a script:** `zsh -c <the person's script> WheelConvert <path>…` — files are positional
  arguments (`"$1"`, `"$@"`), always absolute paths (so never mistaken for options); text and links go to standard
  input. Nothing from the item is ever put into the script text, so quotes, `$()`, backticks, `;`, newlines and
  leading dashes in names stay data. Tested with all of these.
- **Environment:** only `HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE` are passed through, plus
  `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. zsh still reads the person's own `~/.zshenv`
  (their normal environment); WheelConvert's own variables (e.g. `DYLD_*` or anything a launcher set) are not passed.
- **Limits:** a per-petal time limit (default 120 s, 5–3600 s in Settings; the job is cancelled and the process
  killed — SIGTERM, then SIGKILL after 2 s); standard output kept up to 10 MB (the rest is read and dropped so the
  script never blocks); Shortcut results over 10 MB are refused. Writing to a script that exits without reading its
  input can't crash the app (`F_SETNOSIGPIPE` on the pipe).
- **Results:** what a script prints, or what a Shortcut returns, is saved like any other result (never-overwrite
  naming, Settings → Save results, progress panel with Cancel, recent results). The type is sniffed (PDF, image
  types, else text, else `.data`). Empty output saves nothing.
- **URL petals:** `{path}`, `{text}` and `{url}` are percent-encoded (only `A–Z a–z 0–9 - . _ ~` stay as they are), so an
  item can't add parameters, fragments or change the scheme. `file:`, `javascript:` and `data:` templates are refused.
  Any other scheme the person types is allowed — including `https:`, which would send the item to that site; that is
  the person's explicit choice in Settings, unlike the built-in petals, which never use the network.
- **Entitlements:** none added. Hardened runtime allows starting `/bin/zsh` and `/usr/bin/shortcuts` as child processes;
  no Apple Events are sent.
- **Developer mode** `--custom <petal.json> <input>` runs a petal from a file named on the command line, without the
  approval dialog (there is no UI in that mode). It exists for the test suites; the app never reads petal files.
- **Settings write on launch (fixed):** loading the petal list (and the smart wheel key) in `AppSettings.init` was
  first written with a default value, which made `didSet` write the value back on every launch; both are now assigned
  once in `init`, so a fresh install stores nothing until the person changes something.
