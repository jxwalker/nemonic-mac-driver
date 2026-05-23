# Controlled shell-vs-Word print test plan

Purpose: establish a reproducible baseline for the Nemonic driver, then compare shell-generated and Word-generated jobs while changing one variable at a time.

This plan uses the physical orientation terms:

- North: physical leading edge as the note exits first.
- South: physical trailing edge as the note exits last.
- East: physical right edge of the paper; this is the sticky edge for notes.
- West: physical left edge of the paper; this is the non-sticky edge.

Target behavior:

- Sticky notes: normal readable post-it orientation with the sticky edge on the east side of the raw strip. Text should run north-south on the raw strip so that, when handled as a post-it, it reads normally.
- Receipts: normal thermal-printer portrait orientation across the 80 mm print head, narrow margins, content flowing north to south, then auto-cut.

## Ground rules

- Change exactly one variable per test: app, queue, mode, page size, or PDF source.
- Keep every artifact: source document, PDF, filter stderr, ESC/POS binary, visualized PNG, physical photo.
- Do not judge from paper alone. Compare the PDF input, the generated final raster, and the physical output.
- Use asymmetric text in every test so mirror, upside-down, and 90-degree failures are obvious.
- Write the exact queue name and page size on the physical output immediately after printing.

## Baseline labels

Use this exact test content in shell PDFs and Word documents:

```text
NORTH TOP

West edge <  Abc 123 XYZ  > East sticky edge

SOUTH BOTTOM
```

Add a visible marker:

```text
NW  NE
SW  SE
```

Expected failure signatures:

- Mirrored: `Abc 123 XYZ` reads backward left-to-right.
- Upside down: `SOUTH BOTTOM` appears where `NORTH TOP` should be.
- Wrong 90-degree rotation: text flows east-west instead of north-south for sticky, or sideways for receipt.
- Giant font: only a small cropped part of the document fills the width.
- Tiny font: the whole page is preserved but not fitted to the 80 mm paper.
- Wrong mode: sticky output looks like a receipt or receipt output is rotated like a sticky note.

## Hypotheses to rule out

### H1: Word is sending a different PDF geometry than shell tests

Prediction: the captured Word PDF has a different media box, rotation, or imageable area from the shell PDF. The filter logs will show different `pageBox width` / `height`, and the rendered debug PNG will already differ before final rotation.

Rule-out test: capture or export Word's exact PDF and run the filter offline against that file.

### H2: Word is using the wrong queue or losing `NemonicMode`

Prediction: CUPS stderr shows `NemonicMode=Sticky` for a receipt test, `NemonicMode=Receipt` for a sticky test, or the queue name does not match the intended queue.

Rule-out test: compare filter stderr for `Nemonic_Sticky` and `Nemonic_Receipt` jobs from both shell and Word.

### H3: The driver is applying one transform too many in receipt mode

Prediction: the PDF and cropped PNG look correct, but `final-raster` or paper is upside-down/mirrored. This points to final drawing, row order, byte order, or a post-render correction.

Rule-out test: inspect `rendered`, `cropped`, `final-raster`, `dithered`, and visualized ESC/POS PNG for the same job.

### H4: The driver is tightly cropping Word body text, causing giant output

Prediction: Word's source page is reasonable, but the cropped PNG contains only the text bounding box, and the final raster scales that text to nearly 576 dots wide.

Rule-out test: compare `cropped` dimensions for receipt mode. Receipt mode should preserve full page width and trim only vertical whitespace.

### H5: The PPD default media size is unsuitable for Word

Prediction: Word starts from an unexpected page size, orientation, or margin model even when the correct queue is selected.

Rule-out test: in Word, explicitly choose the printer queue first, then set the matching media size. Compare against the same document exported to PDF.

### H6: The physical printer bit order or hardware orientation is misunderstood

Prediction: every input path produces the same consistent mirror or edge swap, including the shell baseline. If shell baseline is correct and Word is wrong, this is not the cause.

Rule-out test: print a raw asymmetric shell baseline and compare west/east/north/south markers.

## Artifact directories

Create one directory per run:

```bash
mkdir -p captures/test-runs/YYYYMMDD-HHMM-{shell-sticky,shell-receipt,word-sticky,word-receipt}
```

Each directory should contain:

- `source.txt` or `source.docx`
- `input.pdf`
- `filter.log`
- `out.bin`
- `visualized.png`
- `debug/page-01-rendered-rgb.png`
- `debug/page-01-rendered.png`
- `debug/page-01-cropped.png`
- `debug/page-01-final-raster.png`
- `debug/page-01-dithered.png`
- `photo.jpg`
- `notes.md`

## Phase 0: record environment baseline

Record once before printing:

```bash
date
lpstat -p | grep -i nemonic
lpstat -v | grep -i nemonic
lpoptions -p Nemonic_Sticky
lpoptions -p Nemonic_Receipt
/Library/Printers/Nemonic/pdftonemonic 1 baseline title 1 "" /dev/null </dev/null >/tmp/nemonic-empty.bin 2>/tmp/nemonic-empty.log || true
cat /tmp/nemonic-empty.log
```

Also record:

- Installed filter build tag from CUPS `error_log`.
- Current repo commit or working tree note.
- Printer physical loading: sticky edge is east.
- Word version.
- macOS version.

## Phase 1: shell offline baseline, no paper

Goal: prove the filter output is sane before spending paper.

For sticky:

```bash
RUN=captures/test-runs/$(date +%Y%m%d-%H%M)-shell-sticky
mkdir -p "$RUN/debug"
swift make_test_pdf.swift "$RUN/input.pdf"
NEMONIC_MODE=Sticky NEMONIC_DEBUG_DIR="$RUN/debug" ./pdftonemonic 1 user shell-sticky 1 "NemonicMode=Sticky PageSize=80x80mm.Fullbleed" "$RUN/input.pdf" </dev/null >"$RUN/out.bin" 2>"$RUN/filter.log"
swift visualize.swift "$RUN/out.bin" "$RUN/visualized.png" >"$RUN/visualize.log" 2>&1
```

For receipt:

```bash
RUN=captures/test-runs/$(date +%Y%m%d-%H%M)-shell-receipt
mkdir -p "$RUN/debug"
swift make_dane_farm_receipt.swift
cp /tmp/dane_farm_receipt.pdf "$RUN/input.pdf"
NEMONIC_MODE=Receipt NEMONIC_DEBUG_DIR="$RUN/debug" ./pdftonemonic 1 user shell-receipt 1 "NemonicMode=Receipt PageSize=80x136mm.Fullbleed" "$RUN/input.pdf" </dev/null >"$RUN/out.bin" 2>"$RUN/filter.log"
swift visualize.swift "$RUN/out.bin" "$RUN/visualized.png" >"$RUN/visualize.log" 2>&1
```

Pass criteria:

- `filter.log` shows the expected mode.
- `visualize.log` reports non-trivial ink.
- `visualized.png` is not mirrored.
- Sticky visual has the expected 90-degree note behavior.
- Receipt visual is upright and not giant-cropped.

## Phase 2: shell physical baseline

Goal: prove CUPS, installed filter, backend, and physical printer match the offline baseline.

Print sticky:

```bash
lp -d Nemonic_Sticky -o NemonicMode=Sticky -o PageSize=80x80mm.Fullbleed captures/test-runs/<shell-sticky-run>/input.pdf
```

Print receipt:

```bash
lp -d Nemonic_Receipt -o NemonicMode=Receipt -o PageSize=80x136mm.Fullbleed captures/test-runs/<shell-receipt-run>/input.pdf
```

Immediately record:

- Physical orientation: where `NORTH TOP`, `SOUTH BOTTOM`, west, east appear.
- Whether text is mirrored.
- Whether font scale is plausible.
- CUPS `error_log` lines for the job.

If shell physical fails, stop. Word is not the primary problem yet.

## Phase 3: Word controlled export, no paper

Goal: isolate Word's PDF generation without CUPS.

In Word:

- Create a new document from the baseline labels.
- Select `Nemonic_Sticky`, then select `80x80mm.Fullbleed`.
- Export or Print to PDF as `captures/test-runs/.../input.pdf`.
- Repeat with `Nemonic_Receipt` and `80x136mm.Fullbleed`.

Run the exported PDFs through the local filter:

```bash
RUN=captures/test-runs/$(date +%Y%m%d-%H%M)-word-sticky-export
mkdir -p "$RUN/debug"
cp /path/to/word-sticky-export.pdf "$RUN/input.pdf"
NEMONIC_MODE=Sticky NEMONIC_DEBUG_DIR="$RUN/debug" ./pdftonemonic 1 user word-sticky-export 1 "NemonicMode=Sticky PageSize=80x80mm.Fullbleed" "$RUN/input.pdf" </dev/null >"$RUN/out.bin" 2>"$RUN/filter.log"
swift visualize.swift "$RUN/out.bin" "$RUN/visualized.png" >"$RUN/visualize.log" 2>&1
```

Repeat with `NEMONIC_MODE=Receipt`.

Decision:

- If exported Word PDF fails offline, the issue is Word PDF geometry plus driver handling.
- If exported Word PDF passes offline but direct Word printing fails, the issue is CUPS options, queue selection, or app print pipeline.

## Phase 4: direct Word print through CUPS

Goal: compare the exact Word print path against the exported-PDF path.

For each queue:

- Open the same Word document.
- Select the target queue first.
- Confirm page size.
- Print one page.
- Capture the latest CUPS spool PDF and control file if available.
- Save CUPS `error_log` lines for that job.
- Photograph the output with north/east/south/west written beside it.

Use:

```bash
bash captures/capture_latest.sh
```

If spool capture is blocked by permissions or retention, increase CUPS debug logging or temporarily use the local capture backend in a separate queue.

## Phase 5: comparison table

Fill this in after each run:

| Test | Source | Queue | Mode in log | Page size | Offline PNG | Paper | Verdict |
|------|--------|-------|-------------|-----------|-------------|-------|---------|
| S1 | shell PDF | Sticky | | | | | |
| S2 | shell PDF | Receipt | | | | | |
| W1 | Word export PDF | Sticky | | | | n/a | |
| W2 | Word export PDF | Receipt | | | | n/a | |
| W3 | Word direct print | Sticky | | | | | |
| W4 | Word direct print | Receipt | | | | | |

## Decision tree

- Shell offline fails: fix driver rendering or transform logic before CUPS/Word testing.
- Shell offline passes but shell physical fails: inspect installed filter, backend, byte order, and physical orientation.
- Shell physical passes but Word export offline fails: fix driver handling of Word PDF geometry.
- Word export offline passes but Word direct print fails: inspect CUPS options, queue defaults, PPD, and spool PDF.
- Only receipt has giant text: receipt crop/scale policy is wrong.
- Only sticky has 90-degree/wrong-edge behavior: sticky rotation direction or sticky margin policy is wrong.
- Both modes mirrored: bit packing or final raster X-axis is wrong.
- Both modes upside-down: row order or leading/trailing edge assumption is wrong.

## Minimum evidence needed before changing code again

Before the next code change, collect at least these four artifacts:

- Shell sticky `visualized.png` and physical photo.
- Shell receipt `visualized.png` and physical photo.
- Word sticky direct-print spool PDF or exported PDF plus physical photo.
- Word receipt direct-print spool PDF or exported PDF plus physical photo.

The next patch should name exactly which hypothesis it addresses.

## 2026-05-22 execution notes

Phase 1 shell offline baseline:

- Run: `captures/test-runs/20260522-171523-phase0-shell-offline`
- Finding: receipt visualized ESC/POS output was upside-down/mirrored before Word or physical printing. This ruled out Word as the primary cause for the receipt orientation failure.
- Driver patch: removed geometry-based sticky/receipt inference and restored deterministic receipt behavior.

Receipt transform probe:

- Run: `captures/test-runs/20260522-172940-numbered-receipt-transform-probe`
- Numbered results from physical paper:
- `TEST 1 / None`: perfect.
- `TEST 2 / FlipY`: upside down and mirrored.
- `TEST 3 / FlipX`: right way up but mirrored.
- `TEST 4 / Rotate180`: correct mirroring but upside down.

Current shell physical baseline:

- Sticky shell print: perfect.
- Receipt shell print: perfect.
- Installed build tag: `pdftonemonic build 2026-05-22-receipt-default-none`.
- Final receipt job: `Nemonic_Receipt-347`.

Conclusion:

- H3 was confirmed for the receipt path during the intermediate row-order build, but the physical transform probe proved the final correct receipt transform is `None`.
- H4 is currently ruled out for shell receipt because font size is good.
- H6 is ruled out as a global hardware misunderstanding because sticky is perfect and receipt is perfect with `None`.
- Remaining Word-specific hypotheses are H1, H2, and H5.
