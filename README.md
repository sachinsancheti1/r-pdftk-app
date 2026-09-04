# r-pdftk-app

Shiny app: merge, extract/delete pages, rotate, compress, encrypt/decrypt, edit metadata, and render pages to JPEG on PDFs — all processed on this server, nothing sent to a third-party PDF site (the AI tab is the one deliberate exception - see below). Started from a generic product spec (`pdftk application.md`, since superseded by this README) describing a much larger cross-platform/public-product scope (Electron desktop, mobile apps, localization, WCAG compliance, community support); this build is deliberately scoped to a private tool for personal/internal use instead, matching `r-contour-analysis`/`r-paint-selection`/`RmdFormatsHub`.

## Architecture: hybrid `qpdf` + `pdftk`, not just "shell out to pdftk"

Despite the app's name, most operations do **not** shell out to the `pdftk` CLI. Researched what's actually available in R before defaulting to a subprocess call:

- **`qpdf`** (CRAN, binds directly to `libqpdf` via Rcpp — no subprocess, no JVM) handles **Merge, Extract/Delete pages, and Rotate** (`pdf_combine`/`pdf_subset`/`pdf_rotate_pages`), and is the **"Lossless only" Compress option** (`pdf_compress`). Confirmed against the package's complete function reference (`pdf_length`, `pdf_split`, `pdf_subset`, `pdf_combine`, `pdf_compress`, `pdf_overlay_stamp`, `pdf_rotate_pages` — nothing else exists) that it has **no encryption and no metadata support at all**.
- **`pdftools`** (already a near-universal R PDF dependency) provides page counts (`pdf_length` — actually via `qpdf::pdf_length`, `pdftools` used for `pdf_info()`) and metadata **reading** (`pdf_info(path)$keys$Title` etc.) — no subprocess needed for this either.
- **`pdftk` (CLI, shelled via `system2()`)** is used only for **Encrypt/Decrypt** and **metadata writing** — the two things neither `qpdf` nor `pdftools` can do. Checked whether `xmpdf` (an R package that looked like it might fill this gap natively) was a better option first — its own `SystemRequirements` say it just shells out to `exiftool`/`ghostscript`/`pdftk` under the hood anyway, so it wouldn't have actually removed the dependency, just added another wrapper package on top of it.
- **`gs` (Ghostscript CLI, shelled via `system2()`)** is the **default Compress path** (all levels except "Lossless only"). `qpdf::pdf_compress()` is structure-only - it dedupes objects and recompresses streams, but never touches embedded images, which is where nearly all of a real-world PDF's size actually lives. Confirmed on a real 99MB image-heavy catalogue (`sample/`, gitignored - real content, not committed): `qpdf::pdf_compress()` produced a byte-identical file, 0% smaller. Ghostscript's `pdfwrite` device actually downsamples/recompresses images to a quality preset - the same file at `/ebook` (the app's default): 98.9MB → 12.3MB, 87% smaller, no visible quality loss at normal viewing size (rendered and compared page-by-page); `/screen` shrinks further but visibly softens text - offered, but not the default.

On Ubuntu/Debian, classic `pdftk` was dropped from the repos — `pdftk-java` (a command-line-compatible Java port) is what's actually installed, needing `default-jre-headless`. The `pdftk` command name and argument syntax are unchanged, so the R code calling `system2("pdftk", ...)` didn't need to know or care about this.

**A real `system2()` quoting bug found while testing Ghostscript, and fixed for `pdftk` too.** `system2(bin, args, ...)` does **not** reliably quote an `args` element containing a space on its own — confirmed live: an unquoted file path with a space (the sample catalogue's own real filename, "EVENPLUS CATALOGUE VOL-1.pdf") split into multiple argv tokens and Ghostscript errored on the fragment. Shiny's own upload `datapath` is always a spaceless temp filename, so this never showed up through the deployed UI - but the CLI-fallback path this file exists for (a PDF too large/sensitive to upload) routinely gets real filenames, which routinely have spaces. Fixed by wrapping every `args` element in `shQuote()` before both `run_pdftk()` and the new `run_ghostscript()` call `system2()` - the same pattern already used in the sibling `r-site-planning-toolkit`/`r-terrain-road` apps for their own Python subprocess calls, for the identical reason.

All 12 core operations (merge, parse-page-range edge cases, extract, delete-via-inverse-selection, rotate, compress, encrypt, decrypt with a correct password, decrypt correctly *rejecting* a wrong password, metadata write-then-read round-trip) were verified locally against a real generated test PDF before deployment — not just assumed from reading the docs.

**A real, app-wide bug found and fixed: every one of this app's 9 `downloadHandler`s was silently swallowing its own errors.** `shiny::validate()`/`need()` only ever surfaces to the user when its call stack bottoms out in a `render*()` output - inside a `downloadHandler()`'s `content` function (every download here), the exact same call still throws its `shiny.silent.error` condition, but there's no output context to catch and display it. The browser still attempts a download and gets back nothing usable, with zero visible sign anything went wrong. Reported directly: uploading only one file to Merge downloaded "some odd file" instead of a warning - reproduced exactly (a download event fires, then silently fails to save, no notification shown), traced to `run_op()`'s own `validate(need(FALSE, conditionMessage(e)))` (used by *every* downloadHandler in this app, not just Merge) plus two more direct `validate(need(...))` call sites (Merge's own file-count check, the AI tab's format-selection check). Fixed with `notify_stop()` (`showNotification()` + `req(FALSE)`) - the same pattern already proven in the sibling `r-site-planning-toolkit`/`r-terrain-road` apps for the identical bug class - confirmed live for both a direct `notify_stop()` call and the `run_op()`-wrapped path: a real, readable error notification now shows, and the browser-side download is actually cancelled rather than "succeeding" with nothing in it.

**PDF to Images** renders selected pages to JPEG via `pdftools::pdf_convert()` — the same poppler binding already used for page counts/metadata, so no new system dependency. A single selected page downloads directly as a `.jpg`; multiple pages zip together. Verified locally: non-contiguous page selection (`1,3`) renders exactly those two pages, not a contiguous range.

## AI: PDF to Excel/Word

The one tab that leaves this server: sends the PDF to Claude (Anthropic's API) as a `document` content block and forces a tool call (`tool_choice`) against a fixed JSON schema (`title`/`sheets`/`sections`) so the response is always structured, parseable data — never prose to scrape. One extraction covers both output formats (Excel via `openxlsx`, Word via `officer`), rather than two separate calls that could disagree with each other.

No local OCR pre-pass: Claude's PDF support already converts each page to an image *and* extracts any embedded text layer, reading both together — that's strictly more capable than a Tesseract pass would add (Tesseract has no notion of table structure; Claude's response already reconstructs rows/columns from visual layout). Verified against a real generated test PDF with a deliberately overlapping table cell (one value's text collided with the next column) — Claude extracted every row and column correctly regardless.

Real bug caught while building this: `"\["` is not a valid R string escape (a genuine parse-time trap, not just a regex quirk) — the first version of the Excel sheet-name sanitizer used it inside a regex character class and errored the moment a sheet name contained a forbidden character (`[ ] : * ? /`). Fixed by replacing each forbidden character individually with `fixed = TRUE` instead of one combined regex.

**Limits**: 20MB and 100 pages per PDF (conservative margins under Anthropic's actual 32MB-request / 100-page-under-1M-context limits — base64 inflates raw bytes by about a third, and the cap here leaves headroom rather than cutting it at the theoretical edge). Larger files: split first with the Extract/Delete Pages tab.

**Setup**: needs `ANTHROPIC_API_KEY` set in this service's environment (`railway variables set --service r-pdftk-app --stdin ANTHROPIC_API_KEY` fed from a file, or via the Railway dashboard) — the tab degrades to a clear in-app error, not a crash, when it's unset. Each conversion is a paid API call (~5 seconds for a small document in testing).

## Styling

Visual language (not code/components) borrowed from the Vitrag (`vitrag-6`) design system: navy `#384764` + teal `#00a99e` palette, sharp/square corners throughout (`border-radius: 0`, no rounded corners anywhere), uppercase tracking-wide bold labels/buttons, Source Sans Pro. Applied as a plain CSS override block (`vitrag_theme()` in `ui.R`) layered on top of Shiny's default Bootstrap 3, not a full theming package swap. The disconnect banner deliberately keeps its own red-alert styling rather than reskinning to the brand palette — the point of that banner is to look distinctly like a system-level warning, not blend into the normal UI chrome.

## Local fallback CLI

All eight tabs' logic lives in two sourced-not-duplicated files, each also directly runnable as its own CLI for a PDF too large/sensitive to upload, or to debug a failure with a real R console instead of whatever `showNotification` surfaces:

`pdftk_core.R` (merge/pages/rotate/compress/encrypt/decrypt/metadata/images):
```
Rscript pdftk_core.R merge out.pdf in1.pdf in2.pdf [more.pdf ...]
Rscript pdftk_core.R pages <keep|delete> in.pdf "1-3,5" out.pdf
Rscript pdftk_core.R rotate in.pdf "1-3,5" 90 out.pdf
Rscript pdftk_core.R compress in.pdf out.pdf [--level screen|ebook|printer|prepress|lossless] [--linearize]
Rscript pdftk_core.R encrypt in.pdf <password> out.pdf
Rscript pdftk_core.R decrypt in.pdf <password> out.pdf
Rscript pdftk_core.R metadata-read in.pdf
Rscript pdftk_core.R metadata-write in.pdf out.pdf [--title T] [--author A] [--subject S] [--keywords K]
Rscript pdftk_core.R images in.pdf out.zip [--pages 1-3,5] [--dpi 150]
```

`ai_pdf_core.R` (AI PDF → Excel/Word; sources `pdftk_core.R` itself for the page-count check, so it's self-sufficient run standalone):
```
Rscript ai_pdf_core.R convert in.pdf out.zip --formats excel,word [--hint "..."]
```

All subcommands verified locally against real generated test PDFs (including the wrong-password decrypt failure path and one real live Claude API call), and the app re-verified end-to-end via Playwright across all 8 tabs, before deploying.

Both files' CLI-invocation guard checks that the file itself was the literal `Rscript` target (via `commandArgs`'s `--file=`) rather than `!interactive()` — the deployed app also runs non-interactively when it sources these files, so an `!interactive()`-based guard would fire `quit()` from inside the live server the moment it started.

## Run

`shiny::runApp()` from this directory. Needs `pdftk` and `gs`/`gswin64c` (Ghostscript) on `PATH` in addition to the R packages below, and `ANTHROPIC_API_KEY` set for the AI tab (optional - that tab alone degrades without it). Ghostscript's binary name differs by OS (`gs` on Linux/Mac, `gswin64c` on Windows) - `PDFTK_GS` overrides the OS-based default explicitly if needed. Upload cap is 200MB (`shiny.maxRequestSize` in `server.R`, matched by `client_max_body_size 200M` in `nginx.conf.template` — nginx's own default of 1MB sits in front of Shiny and silently 413s anything larger unless both are raised together).

## Dependencies

`shiny, qpdf, pdftools, zip, httr2, base64enc, openxlsx, officer` (R packages) + `pdftk` (system binary, `pdftk-java` on Debian/Ubuntu, needs a JRE) + `ghostscript` (system binary, for real Compress).

## Deployment

Docker + Railway + Basic Auth, same pattern as the other three apps — `nginx.conf.template`/`start.sh`/Dockerfile all follow the established template. Ships with the disconnect banner from the first deploy (added retroactively to the other three apps after the fact; this one starts with it).
