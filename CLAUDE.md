# HighReader

Android app (Godot 4.5.1 + a Kotlin plugin) for reading PDFs, mainly papers and books,
one sentence or line at a time. The PDF is analyzed on the device. The reader highlights the
current step and dims the rest of the page. Tap the right side to go forward and the left
side to go back.

## Layout

```
PaperReader/                 Godot project (app name "HighReader", package com.highreader.app)
  project.godot              800x1280 base, stretch canvas_items/expand, auto-rotate (orientation=6)
  export_presets.cfg         "Android" preset, Gradle build, arm64 only
  addons/pdf_reader/         Editor export plugin; bin/pdfreader-release.aar is the built Kotlin plugin
  scripts/
    pdf_bridge.gd            Autoload "Pdf": wrapper around the Android singleton "PdfReader"
    main.gd                  Library screen, import/analysis flow, theme, Android Back handling
    reader_view.gd           Reader: modes, framing/zoom, drawing, input, top/bottom bars
    steps_builder.gd         Turns analyzed lines into steps (sentences, lines, floats, contents)
    settings_panel.gd        Settings overlay (zoom fit, colors, style, dim, back-tap area, skip side columns)
    contents_panel.gd        Contents drawer (swipe right-to-left to open)
    touch_scroll.gd          Drag-to-scroll for lists without accidental taps
pdf_plugin/                  Gradle Android library (Kotlin), Godot plugin v2
  src/main/java/com/paperreader/pdf/
    PdfReaderPlugin.kt       Singleton API: pick/import, render pages, background analysis, cache
    PaperAnalyzer.kt         Layout analysis (the "backend")
tools/
  make_test_pdf.ps1          Generates a synthetic two-column test paper
  godot_tests/               Headless GDScript checks against analysis JSON (see its README)
```

## Build and run (this machine)

Paths: Godot `D:\Godot\Godot_v4.5.1-stable_win64_console.exe`, Android SDK `D:\android_sdk`,
JDK 17 `C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot`, adb `D:\android_sdk\platform-tools\adb.exe`.

1. Build the plugin and copy the AAR into the Godot project:
   `pdf_plugin\gradlew.bat -p pdf_plugin copyAarToGodot` (JAVA_HOME = JDK 17; `local.properties`
   with `sdk.dir=D\:\\android_sdk`, which is git-ignored, so create it on a new machine).
2. First export on a fresh checkout also installs the Android build template:
   `Godot --headless --path PaperReader --install-android-build-template --export-debug "Android" "../build/HighReader.apk"`
   After that, use `--export-debug` without the install flag.
3. `adb install -r build\HighReader.apk`, then `adb shell am start -n com.highreader.app/com.godot.game.GodotApp`.

Known quirks:
- The headless Godot export sometimes never exits after the APK is written (a Gradle daemon
  keeps it waiting). Watch the APK's timestamp and stop the Godot and java processes once it's written.
- Restarting the adb server can make a device "unauthorized" again until the prompt is accepted.
- To get a PDF into the app without the file picker, copy it into the app's private inbox:
  `adb shell "cat /data/local/tmp/x.pdf | run-as com.highreader.app sh -c 'cat > files/inbox/x.pdf'"`.
  The next library refresh moves it into the library.
- Logs: `adb logcat -s godot:* PdfReader:*`.
- Two devices used for testing: Lenovo tablet TB322FC (1904x3040) and Samsung Galaxy A55 (1080x2340).
  Use `adb -s <serial>` when both are connected.

## Data and storage

- Files live in `Documents/HighReader/` on the device: `papers/` (imported PDFs),
  `cache/<file>_<size>_v<VERSION>.json` (analysis), `progress.cfg`, `settings.cfg`.
  If shared storage isn't writable it falls back to the app's private storage.
- **Bump `PaperAnalyzer.VERSION` whenever analysis output changes**, so devices re-analyze.
  Older cache versions of the same file are deleted when a new one is written.
- Analysis JSON: `pages` [[w,h] in pt], `floats` [{p,x0,y0,x1,y1,k,t}], `lines` [{p, x0,y0,x1,y1
  (0..1 of page), c (0 = full width, 1.. = column), k (body|heading|caption|table|small|footnote),
  s (font size), f (float index or -1), t, ws (words), wx (word x0/x1 pairs)}], in reading order.
- Reading position is a key: reading-order line index * 10000 + word index. `progress.cfg` stores the line index.

## Analysis pipeline (PaperAnalyzer.kt)

Per page: PdfBox words (exact size from the text matrix `yScale`; `fontSizeInPt` is rounded),
then column gaps (`findGutters`), then drop caps set aside, then words grouped into lines
(never across a gap with a wide space or a font-size change), then table rows merged (3+
similar-size cells on one baseline), then reading order. Then for the whole document: drop
running headers and page numbers, tag kinds, detect floats from captions.

- Column gaps: a vertical strip with coverage at most 12% of peak and at least 2.5 pt wide,
  with lines ending left and starting right of it. Columns must be at least 12% of the page
  wide (measured from the outer text edges). No gap found means falling back to the page
  middle (two-column check).
- Reading order: full-width lines split the page into bands; inside a band, columns are read left to right.
- Floats: start from captions ("Figure 3:", "Table 2:"), extend to the nearest prose line
  (6+ words, mostly letters, body size, wide). Small notes directly below are included.
- Test any change on both kinds of document: the research paper (two equal columns,
  tables, references) and the book *The Art of Seduction* (a wide main column plus a narrow
  side column of quotes on alternating sides, drop caps, a 3-column index). Compare line output before and after.

## Reader (reader_view.gd)

- Modes: `sentence` (default), `line`, `floats` (figures/tables), `free` (no highlight, pan and pinch).
- Sentences end at `. ; ? !` (abbreviations, initials and a lowercase next word don't count), at
  a font-size change, or at a kind change. Consecutive heading lines merge. A sentence that
  crosses a column or page is split into parts (`sid`/`part`/`parts`).
- Text modes skip captions, tables, notes and figure text; "Skip side columns" also drops columns
  narrower than 60% of the widest column on the page.
- Zoom fit `text` (default): the highlight's full width fills the screen, and pinch and drag are
  locked. `column`/`page` allow pinch and drag. Floats always fit their region.
- `_anchor` holds the reading position and only changes on real movement, so mode switches never drift.

## Conventions

- GDScript: use explicit types where inference fails (`var x: float = max(...)`); Godot errors
  with "Cannot infer the type". Check scripts with `Godot --headless --path PaperReader --quit-after 20`.
- UI is built in code, not in .tscn files (only `scenes/main.tscn` exists).
- The Kotlin package is still `com.paperreader.pdf` and the singleton is `PdfReader`; the app package is `com.highreader.app`.
