# Nemonic macOS driver — developer guide

Technical reference for maintaining `pdftonemonic` and the surrounding CUPS tooling. Last updated: 2026-04-04.

## Architecture summary

The PPD declares a single CUPS filter for PDF jobs:

```text
*cupsFilter: "application/pdf 50 /Library/Printers/Nemonic/pdftonemonic"
```

Upstream of that, macOS may run `cgtexttopdf` (or app-specific code) so the **spool file is already PDF** when it reaches this binary. The filter reads PDF bytes, rasterizes with Core Graphics, auto-crops, rotates for the sticky-note path, dithers, and writes ESC/POS (`GS v 0` plus wrappers) to **stdout** for the USB backend.

## CUPS argv and PDF input (`loadJobPDF`)

CUPS invokes filters as:

`filter job user title copies options [filename]`

In Swift, `CommandLine.arguments[0]` is the executable path; **`arguments[6]`** is the spool file path when present. Jobs can also pass **`"-"`** or rely on **stdin**.

**Order of reads** (see `loadJobPDF` in `pdftonemonic.swift`):

1. If **stdin is not a TTY** (pipe from CUPS), read stdin to end. If non-empty, use that as the PDF.
2. Otherwise read **`arguments[6]`** if it is a non-empty path and not `"-"`.

**Manual testing from Terminal:** if you pass a file path as argv[6], **close stdin** so the filter does not block waiting for you:

```bash
./pdftonemonic 1 user title 1 "" /path/to/job.pdf < /dev/null > out.bin
```

The harness scripts (`test.sh`, `preflight_pdf.sh`, `run_print_gates.sh`, `diagnose_print.sh`) all follow the same CUPS argv shape and use `< /dev/null` where appropriate.

## Why render to DeviceRGB first, then gray

Some PDFs produced by **Quartz / BBEdit / “ColorModel=Gray”** print tickets rasterize as **empty** when drawn straight into a **DeviceGray** context with `drawPDFPage`. Drawing into **DeviceRGB** (premultiplied first, little-endian BGRA) and then flattening to grayscale preserves blends and opacity that otherwise become all white.

The first-pass bitmap is still used for **ink bounds** (crop) and downstream scaling; the final thermal pass remains grayscale + fixed threshold dither.

## Auto-crop and `CGImage.cropping(to:)`

Ink bounds are found by scanning the **gray** buffer after the RGB→gray flatten step.

**Coordinate system:** For a memory-backed `CGContext` created like the driver’s (default bitmap layout), **row `0` in the buffer is the bottom row of the image**. **`CGImage.cropping(to:)`** uses Quartz’s **bottom-left** origin: the rectangle’s **`y`** is the distance **up** from the bottom of the image to the **bottom** edge of the crop.

So if the scan finds content in rows **`minY`…`maxY`** (inclusive) in **buffer row index** (0 at bottom), the crop rect is:

```text
CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
```

**after** applying horizontal padding and clamping to page bounds.

**What went wrong historically:** Inverting `Y` “for top-left” when cropping **shifted** the rectangle to the wrong vertical band. On **US Letter–sized** PDFs, body text often sits in the **lower** portion of the page; a bogus crop grabbed the **white top margin**, yield zero effective ink and **blank output**. Small sticker-sized PDFs could still “work” if the wrong band accidentally overlapped content.

Do **not** assume “invert Y” fixes crops without re-validating against Letter + BBEdit PDFs.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `NEMONIC_PREVIEW_ONLY` | If `1` / `true` / `yes`, **no** ESC/POS is written to stdout (CUPS may still feed paper). |
| `NEMONIC_THRESHOLD` | Dither threshold (1–255). **0** would mark nothing black; invalid values clamp with stderr. |
| `NEMONIC_DEBUG_DIR` | If set, writes stage PNGs (`rendered-rgb`, `rendered`, `cropped`, `final-raster`, `dithered`) per page. |
| `NEMONIC_CROP_PADDING` | Pixels of padding around the tight ink box (default 16). |
| `NEMONIC_RIGHT_MARGIN` | Dots reserved on the sticky edge (default 12). |
| `NEMONIC_SCALE_ADJUST` | Multiplier on fitted scale (default 1.0). |
| `NEMONIC_INTERPOLATION` | When set, controls interpolation when flattening RGB→gray and drawing the cropped image; unset uses high quality for the scaled draw. |

On startup the filter prints **`filterBuildTag`** to **stderr** so `/private/var/log/cups/error_log` proves **which** binary CUPS ran (confirms `sudo ./install.sh` picked up your build).

## Tooling (no paper)

| Script | Role |
|--------|------|
| `run_print_gates.sh` | Compile → file + `/dev/null` → stdin `-"` pipeline → ink count → optional installed binary byte check. |
| `test.sh` | Canonical PDF + preview PNG + human checklist. |
| `preflight_pdf.sh [file]` | Your real PDF; fails on low byte count or low ink. |
| `diagnose_print.sh` | Installed vs fresh `swiftc` binary, shasum, raster byte count. |

Always run gates or preflight **before** debugging with physical prints.

## Debugging a “blank” job

1. **Confirm installed filter** matches the repo: `bash diagnose_print.sh` and check stderr for **`filterBuildTag`** on a real `lp` job in `error_log`.
2. **`unset NEMONIC_PREVIEW_ONLY`** everywhere (shell, `launchd` env for `cupsd` if ever injected).
3. Capture **`/private/var/log/cups/error_log`** lines for the job (argv, `CONTENT_TYPE`, filter stderr).
4. Reproduce offline: `bash preflight_pdf.sh --open` the **same** PDF path the app prints.
5. If still unclear, set **`NEMONIC_DEBUG_DIR=/tmp/nemdeb`** (filter must run in a context that passes env through — for manual runs export it; CUPS only passes whitelisted env — for local runs from shell this is enough) and inspect stage PNGs.

## Plain text from the shell vs BBEdit

* **BBEdit / most apps:** Submit **`application/pdf`** (often with **`ColorModel=Gray`** in the job options). The regression we fixed was **not** “missing PDF” but **raster/crop** behavior on those PDFs.
* **Raw text via `lpr`:** May go through **`cgtexttopdf`**, which can lay out text oddly for sticky media. Fun scripts use a Swift path to avoid that. See `LEARNINGS.md` §2 for historical notes.

## References in-repo

* `LEARNINGS.md` — hardware, protocol, historical experiments.
* `README.md` — user-facing install and preflight.
* `pdftonemonic.swift` — source of truth for the pipeline.
