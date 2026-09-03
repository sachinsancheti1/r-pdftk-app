# ai_pdf_core.R - AI-assisted PDF -> Excel/Word conversion via the Claude
# API's native PDF support (a single request sends the whole PDF as a
# "document" content block; Claude reads both the page images and any
# embedded text layer - no local OCR step needed, and would add nothing:
# Claude's PDF understanding already includes table/layout structure that
# a flat OCR text dump doesn't have). Usable two ways, same pattern as
# pdftk_core.R / rmd_core.R:
#   1. sourced by server.R (the Shiny app calls these functions directly)
#   2. run directly via `Rscript ai_pdf_core.R convert <in.pdf> ...` for a
#      PDF too sensitive/large to upload, or to debug a bad extraction
#      with a real R console instead of just what showNotification shows.
# Needs ANTHROPIC_API_KEY set in the environment - degrades with a clear
# error (not a crash) when it's missing. See README.

suppressMessages({
  library(httr2)
  library(base64enc)
  library(openxlsx)
  library(officer)
})

`%||%` <- function(a, b) if (is.null(a)) b else a

# Needs pdf_page_count() from pdftk_core.R. server.R already sources both
# files, so this is a harmless re-source there; standalone as a CLI, it's
# what makes this file self-sufficient regardless of the caller's cwd.
local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  this_dir <- if (length(file_arg) > 0) dirname(sub("^--file=", "", file_arg[1])) else "."
  sibling <- file.path(this_dir, "pdftk_core.R")
  if (!exists("pdf_page_count", mode = "function") && file.exists(sibling)) {
    source(sibling, local = FALSE)
  }
})

# Anthropic's documented limits (as of when this was written): 32MB max
# request size, 600 pages max (100 when the context window is under 1M
# tokens, which is the default/standard case this app uses). Base64
# encoding inflates raw bytes by ~4/3, and the request also carries the
# tool schema + prompt text, so the raw-file cap here is set well below
# 32MB * 3/4 = 24MB for headroom rather than cutting it exactly at the
# theoretical limit.
MAX_PDF_BYTES <- 20 * 1024^2
MAX_PDF_PAGES <- 100
CLAUDE_MODEL <- "claude-sonnet-5"
CLAUDE_MAX_TOKENS <- 16000

FORMAT_LABELS <- c(excel = "Excel workbook", word = "Word document")

# A single tool schema shared by both output formats: one API call
# extracts everything needed for either, so requesting "both" doesn't
# mean two independent (and possibly inconsistent) reads of the document.
extract_tool_schema <- function() {
  list(
    name = "extract_document",
    description = paste(
      "Extract this PDF's content in a structured form suitable for",
      "rebuilding as an Excel workbook and/or a Word document."
    ),
    input_schema = list(
      type = "object",
      properties = list(
        title = list(type = "string", description = "A short title for the document."),
        sheets = list(
          type = "array",
          description = paste(
            "Tabular data for Excel - one entry per distinct table or",
            "dataset in the document. Every row must have the same number",
            "of cells as `headers`. Omit entirely if the document has no",
            "real tabular data."
          ),
          items = list(
            type = "object",
            properties = list(
              name = list(type = "string", description = "Sheet name, max 31 characters."),
              headers = list(type = "array", items = list(type = "string")),
              rows = list(
                type = "array",
                items = list(type = "array", items = list(type = "string"))
              )
            ),
            required = list("name", "headers", "rows")
          )
        ),
        sections = list(
          type = "array",
          description = paste(
            "The full document outline for Word, in reading order:",
            "headings, paragraphs, bullet lists, and tables interleaved",
            "as they actually appear."
          ),
          items = list(
            type = "object",
            properties = list(
              type = list(
                type = "string",
                enum = list("heading1", "heading2", "heading3", "paragraph", "bullet_list", "table")
              ),
              text = list(type = "string", description = "For heading1/heading2/heading3/paragraph."),
              items = list(type = "array", items = list(type = "string"), description = "For bullet_list."),
              headers = list(type = "array", items = list(type = "string"), description = "For table."),
              rows = list(
                type = "array",
                items = list(type = "array", items = list(type = "string")),
                description = "For table - each row must match `headers` length."
              )
            ),
            required = list("type")
          )
        )
      ),
      required = list("title", "sheets", "sections")
    )
  )
}

# Sends the PDF to Claude and returns the parsed extraction (a list with
# $title/$sheets/$sections). Does not decide what to build from it - that's
# op_ai_to_excel()/op_ai_to_word(), so both formats reuse one extraction
# instead of two separate (and possibly divergent) API calls.
call_claude_extract <- function(pdf_path, hint = "") {
  api_key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (nchar(api_key) == 0) {
    stop("AI conversion isn't configured on this server yet - ANTHROPIC_API_KEY isn't set.")
  }

  size <- file.info(pdf_path)$size
  if (is.na(size)) stop("Couldn't read this PDF file.")
  if (size > MAX_PDF_BYTES) {
    stop(sprintf(
      "This PDF is %.1fMB, over the %.0fMB limit for AI conversion (the Claude API caps whole requests at 32MB, and base64-encoding a PDF inflates it by about a third). Try the Extract/Delete Pages tab to split it first.",
      size / 1024^2, MAX_PDF_BYTES / 1024^2
    ))
  }
  n_pages <- pdf_page_count(pdf_path)
  if (!is.finite(n_pages)) {
    stop("Couldn't read this PDF - is it a valid, unencrypted file?")
  }
  if (n_pages > MAX_PDF_PAGES) {
    stop(sprintf(
      "This PDF has %d pages, over the %d-page limit for AI conversion in one request. Try the Extract/Delete Pages tab to split it first.",
      n_pages, MAX_PDF_PAGES
    ))
  }

  pdf_b64 <- base64enc::base64encode(pdf_path)

  prompt <- paste(
    "Extract this document's content by calling the extract_document tool.",
    "Preserve every table's rows and columns exactly - don't summarize or",
    "drop rows. Keep numbers as they appear in the source (don't reformat",
    "or recalculate them).",
    if (nchar(trimws(hint)) > 0) paste("Additional context from the user:", trimws(hint)) else ""
  )

  req <- request("https://api.anthropic.com/v1/messages") |>
    req_headers(
      "x-api-key" = api_key,
      "anthropic-version" = "2023-06-01",
      "content-type" = "application/json"
    ) |>
    req_body_json(list(
      model = CLAUDE_MODEL,
      max_tokens = CLAUDE_MAX_TOKENS,
      tools = list(extract_tool_schema()),
      tool_choice = list(type = "tool", name = "extract_document"),
      messages = list(list(
        role = "user",
        content = list(
          list(type = "document", source = list(
            type = "base64", media_type = "application/pdf", data = pdf_b64
          )),
          list(type = "text", text = prompt)
        )
      ))
    )) |>
    req_error(is_error = function(resp) FALSE) |>
    req_timeout(180)

  resp <- tryCatch(req_perform(req), error = function(e) {
    stop("Couldn't reach the Claude API: ", conditionMessage(e))
  })

  status <- resp_status(resp)
  body <- tryCatch(resp_body_json(resp), error = function(e) NULL)

  if (status != 200) {
    msg <- if (!is.null(body$error$message)) body$error$message else paste("HTTP", status)
    stop("Claude API error: ", msg)
  }

  # A response cut off by the max_tokens budget mid-way through the tool
  # call's JSON would otherwise surface as a generic, misleading "found no
  # tabular data" error from op_ai_to_excel/op_ai_to_word once the missing
  # keys are (correctly, but unhelpfully) treated as empty - this document
  # isn't actually short on content, the response just didn't finish.
  if (identical(body$stop_reason, "max_tokens")) {
    stop(paste(
      "This document has more content than fits in one AI response and",
      "got cut off partway through. Try the Extract/Delete Pages tab to",
      "split it into smaller pieces first."
    ))
  }

  tool_blocks <- Filter(function(b) identical(b$type, "tool_use"), body$content)
  if (length(tool_blocks) == 0) {
    stop("Claude didn't return structured data for this document - try again, or a smaller/simpler PDF.")
  }
  tool_blocks[[1]]$input
}

# ---- Building output files from an extraction ----

# Defensive: the model's output is schema-shaped but not guaranteed
# semantically clean (e.g. a row shorter/longer than its headers). Pad or
# truncate rather than let openxlsx/officer error out on a fixable mismatch.
normalize_row <- function(row, n) {
  row <- unlist(lapply(row, function(x) if (is.null(x)) "" else as.character(x)))
  length(row) <- n
  row[is.na(row)] <- ""
  row
}

rows_to_df <- function(headers, rows) {
  headers <- unlist(headers)
  if (length(rows) == 0) {
    df <- as.data.frame(matrix(character(0), ncol = length(headers)), stringsAsFactors = FALSE)
  } else {
    mat <- do.call(rbind, lapply(rows, normalize_row, n = length(headers)))
    df <- as.data.frame(mat, stringsAsFactors = FALSE)
  }
  colnames(df) <- headers
  df
}

# Excel forbids [ ] : * ? / \ in sheet names. Replaced one at a time with
# fixed = TRUE rather than a single regex character class - "\[" is not a
# valid R string escape at all, and multiple backslash-escaping layers
# (R string literal, then regex) are easy to get subtly wrong.
sanitize_sheet_name <- function(name) {
  for (ch in c("[", "]", ":", "*", "?", "/", "\\")) name <- gsub(ch, " ", name, fixed = TRUE)
  name
}

op_ai_to_excel <- function(extraction, output) {
  sheets <- extraction$sheets
  if (length(sheets) == 0) stop("Claude found no tabular data to put in a spreadsheet.")

  wb <- createWorkbook()
  used_names <- character(0)
  for (s in sheets) {
    if (length(s$headers) == 0) next
    nm <- substr(sanitize_sheet_name(s$name %||% "Sheet"), 1, 31)
    if (nchar(trimws(nm)) == 0) nm <- "Sheet"
    base_nm <- nm
    i <- 1
    while (nm %in% used_names) { i <- i + 1; nm <- substr(paste0(base_nm, " ", i), 1, 31) }
    used_names <- c(used_names, nm)

    addWorksheet(wb, nm)
    writeData(wb, nm, rows_to_df(s$headers, s$rows))
  }
  if (length(used_names) == 0) stop("Claude found no usable tabular data to put in a spreadsheet.")
  saveWorkbook(wb, output, overwrite = TRUE)
  invisible(output)
}

op_ai_to_word <- function(extraction, output) {
  sections <- extraction$sections
  if (length(sections) == 0) stop("Claude found no document content to write out.")

  heading_style <- c(heading1 = "heading 1", heading2 = "heading 2", heading3 = "heading 3")
  doc <- read_docx()
  if (!is.null(extraction$title) && nchar(extraction$title) > 0) {
    doc <- body_add_par(doc, extraction$title, style = "heading 1")
  }
  wrote_anything <- FALSE
  for (sec in sections) {
    type <- sec$type %||% ""
    if (type %in% names(heading_style)) {
      doc <- body_add_par(doc, sec$text %||% "", style = heading_style[[type]])
      wrote_anything <- TRUE
    } else if (type == "paragraph") {
      if (nchar(sec$text %||% "") > 0) {
        doc <- body_add_par(doc, sec$text, style = "Normal")
        wrote_anything <- TRUE
      }
    } else if (type == "bullet_list") {
      for (it in sec$items %||% list()) {
        doc <- body_add_par(doc, paste("•", it), style = "Normal")
        wrote_anything <- TRUE
      }
    } else if (type == "table") {
      if (length(sec$headers) > 0) {
        doc <- body_add_table(doc, rows_to_df(sec$headers, sec$rows), style = "table_template")
        wrote_anything <- TRUE
      }
    }
  }
  if (!wrote_anything) stop("Claude found no document content to write out.")
  print(doc, target = output)
  invisible(output)
}

# One extraction, then whichever output file(s) were requested. Returns
# the file path(s) written (in the order of `formats`).
op_ai_convert <- function(pdf_path, formats, out_dir, hint = "") {
  if (length(formats) == 0) stop("Select at least one output format.")
  unknown <- setdiff(formats, names(FORMAT_LABELS))
  if (length(unknown) > 0) {
    stop("Unknown format(s): ", paste(unknown, collapse = ", "), " - use excel and/or word.")
  }
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  extraction <- call_claude_extract(pdf_path, hint)
  base <- tools::file_path_sans_ext(basename(pdf_path))

  out_files <- character(0)
  if ("excel" %in% formats) {
    f <- file.path(out_dir, paste0(base, ".xlsx"))
    op_ai_to_excel(extraction, f)
    out_files <- c(out_files, f)
  }
  if ("word" %in% formats) {
    f <- file.path(out_dir, paste0(base, ".docx"))
    op_ai_to_word(extraction, f)
    out_files <- c(out_files, f)
  }
  out_files
}

# op_ai_convert() + zip when more than one format was produced; a single
# format is returned as-is (caller decides whether to wrap it anyway).
op_ai_convert_zip <- function(pdf_path, formats, zip_path, hint = "") {
  work_dir <- tempfile()
  dir.create(work_dir, recursive = TRUE)
  on.exit(unlink(work_dir, recursive = TRUE, force = TRUE))
  out_files <- op_ai_convert(pdf_path, formats, work_dir, hint)
  if (length(out_files) == 1) {
    file.copy(out_files, zip_path, overwrite = TRUE)
  } else {
    zip::zipr(zip_path, files = out_files, root = work_dir)
  }
  invisible(zip_path)
}

# ---- CLI ----

.ai_pdf_core_cli <- function(argv) {
  usage <- function() {
    cat(
      "Usage: Rscript ai_pdf_core.R convert <in.pdf> <out> --formats excel,word [--hint \"...\"]\n\n",
      "--formats is required (comma-separated: excel, word).\n",
      "If both formats are requested, <out> should end in .zip; for a single\n",
      "format <out> can just be the .xlsx/.docx path directly.\n",
      "Requires ANTHROPIC_API_KEY set in the environment.\n",
      sep = ""
    )
  }
  if (length(argv) == 0 || argv[1] != "convert") { usage(); quit(status = 1) }
  rest <- argv[-1]
  if (length(rest) < 2) { usage(); quit(status = 1) }
  input_pdf <- rest[1]; output_path <- rest[2]
  flags <- rest[-(1:2)]

  get_flag <- function(name, default = NULL) {
    i <- match(paste0("--", name), flags)
    if (is.na(i) || i == length(flags)) default else flags[i + 1]
  }

  formats_arg <- get_flag("formats")
  if (is.null(formats_arg)) {
    cat("ERROR: --formats is required\n\n")
    usage()
    quit(status = 1)
  }
  formats <- trimws(strsplit(formats_arg, ",")[[1]])

  result <- tryCatch({
    op_ai_convert_zip(input_pdf, formats, output_path, hint = get_flag("hint", ""))
  }, error = function(e) {
    cat("ERROR:", conditionMessage(e), "\n")
    quit(status = 1)
  })

  cat("Wrote:", result, "\n")
  invisible(NULL)
}

# Same guard as pdftk_core.R/rmd_core.R: only run the CLI dispatcher when
# THIS file was the direct `Rscript` target, not just because the process
# happens to be non-interactive (the deployed Shiny app is too, and would
# otherwise have this file's quit() calls kill the live server).
.ai_pdf_core_invoked_file <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) == 0) NULL else sub("^--file=", "", file_arg[1])
})
if (!is.null(.ai_pdf_core_invoked_file) && basename(.ai_pdf_core_invoked_file) == "ai_pdf_core.R") {
  .ai_pdf_core_cli(commandArgs(trailingOnly = TRUE))
}
