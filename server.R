# server.R
library(shiny)
library(qpdf)
library(pdftools)

# Merge, extract/delete pages, rotate, and compress all go through the
# `qpdf` R package - it binds directly to libqpdf (no subprocess, no JVM),
# unlike shelling out to a pdftk/qpdf CLI. Confirmed via its full CRAN
# manual before choosing this: pdf_combine/pdf_subset/pdf_rotate_pages/
# pdf_compress cover exactly these four operations, but qpdf has NO
# encryption support and no metadata read/write of any kind (checked the
# complete function index - only pdf_length/pdf_split/pdf_subset/
# pdf_combine/pdf_compress/pdf_overlay_stamp/pdf_rotate_pages exist).
# `xmpdf` looked like it might fill that gap natively, but its own
# SystemRequirements say it just shells out to exiftool/ghostscript/pdftk
# under the hood anyway - so for encrypt/decrypt and metadata writing,
# there's no real R-native option and this app shells out to pdftk
# directly instead of adding another wrapper package on top of the same
# dependency.
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
# an error message (character) instead of stopping, so callers can show it
# via validate(need(...)) rather than a raw R error.
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

shinyServer(function(input, output, session) {

  # ---- Merge ----
  output$merge_file_list <- renderUI({
    req(input$merge_files)
    tags$ol(lapply(input$merge_files$name, tags$li))
  })

  output$merge_download <- downloadHandler(
    filename = function() "merged.pdf",
    content = function(file) {
      validate(need(nrow(input$merge_files) >= 2, "Select at least two PDF files to merge."))
      qpdf::pdf_combine(input$merge_files$datapath, output = file)
    }
  )

  # ---- Extract / Delete Pages ----
  pages_total <- reactive({
    req(input$pages_file)
    pdf_page_count(input$pages_file$datapath)
  })

  output$pages_info <- renderUI({
    req(input$pages_file)
    n <- pages_total()
    tags$p(tags$small(sprintf("%d page(s) in this document.", n)))
  })

  output$pages_download <- downloadHandler(
    filename = function() paste0(if (input$pages_mode == "keep") "extracted" else "remaining", ".pdf"),
    content = function(file) {
      req(input$pages_file)
      n <- pages_total()
      validate(need(is.finite(n), "Couldn't read this PDF - is it a valid, unencrypted file?"))
      parsed <- parse_page_range(input$pages_range, n)
      validate(need(is.numeric(parsed), if (is.character(parsed)) parsed else "Enter which pages to use."))
      keep <- if (input$pages_mode == "keep") parsed else setdiff(seq_len(n), parsed)
      validate(need(length(keep) > 0, "That leaves no pages in the output - adjust your page selection."))
      qpdf::pdf_subset(input$pages_file$datapath, pages = keep, output = file)
    }
  )

  # ---- Rotate ----
  rotate_total <- reactive({
    req(input$rotate_file)
    pdf_page_count(input$rotate_file$datapath)
  })

  output$rotate_info <- renderUI({
    req(input$rotate_file)
    n <- rotate_total()
    tags$p(tags$small(sprintf("%d page(s) in this document.", n)))
  })

  output$rotate_download <- downloadHandler(
    filename = function() "rotated.pdf",
    content = function(file) {
      req(input$rotate_file)
      n <- rotate_total()
      validate(need(is.finite(n), "Couldn't read this PDF - is it a valid, unencrypted file?"))
      parsed <- parse_page_range(input$rotate_range, n)
      validate(need(is.numeric(parsed), if (is.character(parsed)) parsed else "Enter which pages to rotate."))
      qpdf::pdf_rotate_pages(
        input$rotate_file$datapath,
        pages = parsed,
        angle = as.numeric(input$rotate_deg),
        relative = TRUE,
        output = file
      )
    }
  )

  # ---- Compress ----
  output$compress_download <- downloadHandler(
    filename = function() "compressed.pdf",
    content = function(file) {
      req(input$compress_file)
      qpdf::pdf_compress(input$compress_file$datapath, output = file, linearize = input$compress_linearize)
    }
  )

  # ---- Encrypt / Decrypt ----
  output$crypt_download <- downloadHandler(
    filename = function() if (input$crypt_mode == "encrypt") "encrypted.pdf" else "decrypted.pdf",
    content = function(file) {
      req(input$crypt_file)
      validate(need(nchar(input$crypt_pw) > 0, "Enter a password."))
      args <- if (input$crypt_mode == "encrypt") {
        c(input$crypt_file$datapath, "output", file, "user_pw", input$crypt_pw)
      } else {
        c(input$crypt_file$datapath, "input_pw", input$crypt_pw, "output", file)
      }
      tryCatch(run_pdftk(args), error = function(e) {
        validate(need(FALSE, "That didn't work - for decryption, double check the password is correct."))
      })
    }
  )

  # ---- Metadata ----
  observeEvent(input$meta_file, {
    req(input$meta_file)
    keys <- tryCatch(pdftools::pdf_info(input$meta_file$datapath)$keys, error = function(e) list())
    get_field <- function(key) if (!is.null(keys[[key]])) keys[[key]] else ""
    updateTextInput(session, "meta_title", value = get_field("Title"))
    updateTextInput(session, "meta_author", value = get_field("Author"))
    updateTextInput(session, "meta_subject", value = get_field("Subject"))
    updateTextInput(session, "meta_keywords", value = get_field("Keywords"))
  })

  output$meta_download <- downloadHandler(
    filename = function() "updated_metadata.pdf",
    content = function(file) {
      req(input$meta_file)
      fields <- list(Title = input$meta_title, Author = input$meta_author,
                      Subject = input$meta_subject, Keywords = input$meta_keywords)
      lines <- unlist(lapply(names(fields), function(k) {
        c("InfoBegin", paste0("InfoKey: ", k), paste0("InfoValue: ", fields[[k]]))
      }))
      meta_txt <- tempfile(fileext = ".txt")
      writeLines(lines, meta_txt, useBytes = TRUE)
      on.exit(unlink(meta_txt))
      args <- c(input$meta_file$datapath, "update_info_utf8", meta_txt, "output", file)
      run_pdftk(args)
    }
  )
})
