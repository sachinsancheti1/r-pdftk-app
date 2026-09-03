# pdftk_core.R - the actual merge/extract/rotate/compress/encrypt/metadata
# logic, usable two ways:
#   1. sourced by server.R (the deployed Shiny app calls these functions
#      directly - no duplicated logic between the app and this file)
#   2. run directly via `Rscript pdftk_core.R <command> ...` when a file is
#      too large/sensitive to upload, or a failure needs local debugging
#      the deployed container doesn't give you (no R console, no
#      traceback beyond what showNotification surfaces).
# Same install needed either way: R + the qpdf and pdftools packages, plus
# pdftk on PATH for encrypt/decrypt/metadata (see README).

suppressMessages({
  library(qpdf)
  library(pdftools)
})

run_pdftk <- function(args) {
  out <- system2("pdftk", args, stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop("pdftk failed: ", paste(out, collapse = "\n"))
  }
  invisible(out)
}

pdf_page_count <- function(path) {
  tryCatch(qpdf::pdf_length(path), error = function(e) NA_integer_)
}

# "1-3,5,8-10" -> c(1,2,3,5,8,9,10), validated against total_pages. Returns
# an error message (character) instead of stopping, so Shiny callers can
# show it via validate(need(...)) while CLI callers can just print+quit.
parse_page_range <- function(range_str, total_pages) {
  range_str <- trimws(range_str)
  if (range_str == "") return(seq_len(total_pages))
  parts <- trimws(strsplit(range_str, ",")[[1]])
  pages <- integer(0)
  for (p in parts) {
    if (grepl("^\\d+-\\d+$", p)) {
      bounds <- as.integer(strsplit(p, "-")[[1]])
      if (bounds[1] > bounds[2]) return(sprintf("Invalid range '%s': start > end", p))
      pages <- c(pages, seq(bounds[1], bounds[2]))
    } else if (grepl("^\\d+$", p)) {
      pages <- c(pages, as.integer(p))
    } else {
      return(sprintf("Couldn't understand '%s' - use page numbers and ranges like 1-3,5,8-10", p))
    }
  }
  pages <- sort(unique(pages))
  if (any(pages < 1 | pages > total_pages)) {
    return(sprintf("Page numbers must be between 1 and %d (this document has %d pages)", total_pages, total_pages))
  }
  pages
}

# ---- Operations (one function per app tab) ----

op_merge <- function(files, output) {
  stopifnot(length(files) >= 2)
  qpdf::pdf_combine(files, output = output)
  invisible(output)
}

op_pages <- function(file, pages_str, mode = c("keep", "delete"), output) {
  mode <- match.arg(mode)
  n <- pdf_page_count(file)
  if (!is.finite(n)) stop("Couldn't read this PDF - is it a valid, unencrypted file?")
  parsed <- parse_page_range(pages_str, n)
  if (is.character(parsed)) stop(parsed)
  keep <- if (mode == "keep") parsed else setdiff(seq_len(n), parsed)
  if (length(keep) == 0) stop("That leaves no pages in the output - adjust the page selection.")
  qpdf::pdf_subset(file, pages = keep, output = output)
  invisible(output)
}

op_rotate <- function(file, pages_str, angle, output) {
  n <- pdf_page_count(file)
  if (!is.finite(n)) stop("Couldn't read this PDF - is it a valid, unencrypted file?")
  parsed <- parse_page_range(pages_str, n)
  if (is.character(parsed)) stop(parsed)
  qpdf::pdf_rotate_pages(file, pages = parsed, angle = as.numeric(angle), relative = TRUE, output = output)
  invisible(output)
}

op_compress <- function(file, output, linearize = FALSE) {
  qpdf::pdf_compress(file, output = output, linearize = linearize)
  invisible(output)
}

op_crypt <- function(file, mode = c("encrypt", "decrypt"), password, output) {
  mode <- match.arg(mode)
  if (nchar(password) == 0) stop("Enter a password.")
  args <- if (mode == "encrypt") {
    c(file, "output", output, "user_pw", password)
  } else {
    c(file, "input_pw", password, "output", output)
  }
  tryCatch(run_pdftk(args), error = function(e) {
    stop("That didn't work - for decryption, double check the password is correct.")
  })
  invisible(output)
}

op_metadata_read <- function(file) {
  tryCatch(pdftools::pdf_info(file)$keys, error = function(e) list())
}

op_metadata_write <- function(file, title = "", author = "", subject = "", keywords = "", output) {
  fields <- list(Title = title, Author = author, Subject = subject, Keywords = keywords)
  lines <- unlist(lapply(names(fields), function(k) {
    c("InfoBegin", paste0("InfoKey: ", k), paste0("InfoValue: ", fields[[k]]))
  }))
  meta_txt <- tempfile(fileext = ".txt")
  writeLines(lines, meta_txt, useBytes = TRUE)
  on.exit(unlink(meta_txt))
  run_pdftk(c(file, "update_info_utf8", meta_txt, "output", output))
  invisible(output)
}

# ---- CLI ----

.pdftk_core_cli <- function(argv) {
  usage <- function() {
    cat(
      "Usage: Rscript pdftk_core.R <command> [args...]\n\n",
      "Commands:\n",
      "  merge <out.pdf> <in1.pdf> <in2.pdf> [more.pdf ...]\n",
      "  pages <keep|delete> <in.pdf> <pages e.g. 1-3,5> <out.pdf>\n",
      "  rotate <in.pdf> <pages e.g. 1-3,5 (blank = all)> <angle 90|180|-90> <out.pdf>\n",
      "  compress <in.pdf> <out.pdf> [--linearize]\n",
      "  encrypt <in.pdf> <password> <out.pdf>\n",
      "  decrypt <in.pdf> <password> <out.pdf>\n",
      "  metadata-read <in.pdf>\n",
      "  metadata-write <in.pdf> <out.pdf> [--title T] [--author A] [--subject S] [--keywords K]\n",
      sep = ""
    )
  }
  if (length(argv) == 0) { usage(); quit(status = 1) }
  cmd <- argv[1]; rest <- argv[-1]

  result <- tryCatch({
    switch(cmd,
      "merge" = op_merge(rest[-1], output = rest[1]),
      "pages" = op_pages(rest[2], rest[3], mode = rest[1], output = rest[4]),
      "rotate" = op_rotate(rest[1], rest[2], rest[3], output = rest[4]),
      "compress" = op_compress(rest[1], output = rest[2], linearize = "--linearize" %in% rest),
      "encrypt" = op_crypt(rest[1], mode = "encrypt", password = rest[2], output = rest[3]),
      "decrypt" = op_crypt(rest[1], mode = "decrypt", password = rest[2], output = rest[3]),
      "metadata-read" = { print(op_metadata_read(rest[1])); invisible(NULL) },
      "metadata-write" = {
        get_flag <- function(name, default = "") {
          i <- match(paste0("--", name), rest)
          if (is.na(i) || i == length(rest)) default else rest[i + 1]
        }
        op_metadata_write(rest[1], title = get_flag("title"), author = get_flag("author"),
                           subject = get_flag("subject"), keywords = get_flag("keywords"), output = rest[2])
      },
      { usage(); quit(status = 1) }
    )
  }, error = function(e) {
    cat("ERROR:", conditionMessage(e), "\n")
    quit(status = 1)
  })

  if (!is.null(result) && is.character(result)) cat("Wrote:", result, "\n")
  invisible(NULL)
}

# Only actually run the CLI dispatcher when THIS file was the direct
# target of `Rscript pdftk_core.R ...` - checking merely `!interactive()`
# would also be true when the deployed Shiny app (itself started
# non-interactively) sources this file, which would incorrectly trigger
# quit(status=1) from inside a running server and kill the whole process.
.pdftk_core_invoked_file <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) == 0) NULL else sub("^--file=", "", file_arg[1])
})
if (!is.null(.pdftk_core_invoked_file) && basename(.pdftk_core_invoked_file) == "pdftk_core.R") {
  .pdftk_core_cli(commandArgs(trailingOnly = TRUE))
}
