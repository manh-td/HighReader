# Godot test scripts

Headless checks that run against an analysis JSON pulled from a device
(`Documents/HighReader/cache/<file>_v<N>.json`). Run from the repo root:

```
D:\Godot\Godot_v4.5.1-stable_win64_console.exe --headless --path PaperReader --script tools/godot_tests/<script>.gd -- <path\to\analysis.json> [pages...]
```

| Script | What it checks |
|---|---|
| `sentences_sample.gd` | Sentence count, contents entries, sample sentences, end-of-sentence unit cases |
| `split_sentences.gd` | Sentences split into parts across columns/pages |
| `mode_switch_drift.gd` | Sentence <-> Line switching keeps the reading position (expect 0 drift for "anchor") |
| `side_columns.gd` | Side-column detection and how many lines "Skip side columns" removes |
| `gutter_page.gd` | Column-gap coverage diagnostics for given page indexes (0-based) |
| `gutter_all_pages.gd` | Re-runs the column-gap rules on every page (a GDScript copy of `findGutters`) |

The gutter scripts mirror the Kotlin rules in `PaperAnalyzer.findGutters`; keep them in sync when changing it.
