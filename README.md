# r-pdftk-app

Shiny app: merge, extract/delete pages, rotate, compress, encrypt/decrypt, and edit metadata on PDFs — all processed on this server, nothing sent to a third-party PDF site. Started from a generic product spec (`pdftk application.md`, since superseded by this README) describing a much larger cross-platform/public-product scope (Electron desktop, mobile apps, localization, WCAG compliance, community support); this build is deliberately scoped to a private tool for personal/internal use instead, matching `r-contour-analysis`/`r-paint-selection`/`RmdFormatsHub`.

## Architecture: hybrid `qpdf` + `pdftk`, not just "shell out to pdftk"

Despite the app's name, most operations do **not** shell out to the `pdftk` CLI. Researched what's actually available in R before defaulting to a subprocess call:

- **`qpdf`** (CRAN, binds directly to `libqpdf` via Rcpp — no subprocess, no JVM) handles **Merge, Extract/Delete pages, Rotate, and Compress** (`pdf_combine`/`pdf_subset`/`pdf_rotate_pages`/`pdf_compress`). Confirmed against the package's complete function reference (`pdf_length`, `pdf_split`, `pdf_subset`, `pdf_combine`, `pdf_compress`, `pdf_overlay_stamp`, `pdf_rotate_pages` — nothing else exists) that it has **no encryption and no metadata support at all**.
- **`pdftools`** (already a near-universal R PDF dependency) provides page counts (`pdf_length` — actually via `qpdf::pdf_length`, `pdftools` used for `pdf_info()`) and metadata **reading** (`pdf_info(path)$keys$Title` etc.) — no subprocess needed for this either.
- **`pdftk` (CLI, shelled via `system2()`)** is used only for **Encrypt/Decrypt** and **metadata writing** — the two things neither `qpdf` nor `pdftools` can do. Checked whether `xmpdf` (an R package that looked like it might fill this gap natively) was a better option first — its own `SystemRequirements` say it just shells out to `exiftool`/`ghostscript`/`pdftk` under the hood anyway, so it wouldn't have actually removed the dependency, just added another wrapper package on top of it.

On Ubuntu/Debian, classic `pdftk` was dropped from the repos — `pdftk-java` (a command-line-compatible Java port) is what's actually installed, needing `default-jre-headless`. The `pdftk` command name and argument syntax are unchanged, so the R code calling `system2("pdftk", ...)` didn't need to know or care about this.

All 12 core operations (merge, parse-page-range edge cases, extract, delete-via-inverse-selection, rotate, compress, encrypt, decrypt with a correct password, decrypt correctly *rejecting* a wrong password, metadata write-then-read round-trip) were verified locally against a real generated test PDF before deployment — not just assumed from reading the docs.

## Styling

Visual language (not code/components) borrowed from the Vitrag (`vitrag-6`) design system: navy `#384764` + teal `#00a99e` palette, sharp/square corners throughout (`border-radius: 0`, no rounded corners anywhere), uppercase tracking-wide bold labels/buttons, Source Sans Pro. Applied as a plain CSS override block (`vitrag_theme()` in `ui.R`) layered on top of Shiny's default Bootstrap 3, not a full theming package swap. The disconnect banner deliberately keeps its own red-alert styling rather than reskinning to the brand palette — the point of that banner is to look distinctly like a system-level warning, not blend into the normal UI chrome.

## Run

`shiny::runApp()` from this directory. Needs `pdftk` on `PATH` in addition to the R packages below.

## Dependencies

`shiny, qpdf, pdftools` (R packages) + `pdftk` (system binary, `pdftk-java` on Debian/Ubuntu, needs a JRE).

## Deployment

Docker + Railway + Basic Auth, same pattern as the other three apps — `nginx.conf.template`/`start.sh`/Dockerfile all follow the established template. Ships with the disconnect banner from the first deploy (added retroactively to the other three apps after the fact; this one starts with it).
