# server.R
library(shiny)
library(qpdf)
library(pdftools)

# Default Shiny upload cap is 5MB; real-world PDFs (scanned drawings,
# multi-page documents) routinely exceed that. Matches nginx's
# client_max_body_size (200M) in nginx.conf.template - nginx's own default
# (1MB) sits in front of this and would 413 anything larger before Shiny
# ever saw it, so both had to move together.
options(shiny.maxRequestSize = 200 * 1024^2)

# The actual merge/extract/rotate/compress/encrypt/metadata/images logic
# lives in pdftk_core.R, not duplicated here - it's also directly runnable
# as a CLI (`Rscript pdftk_core.R ...`) for a file too large/sensitive to
# upload, or to debug a failure locally with a real R console instead of
# just whatever showNotification surfaces. See README.
source("pdftk_core.R")

# AI-assisted PDF -> Excel/Word (Claude's native PDF support) lives in
# ai_pdf_core.R, same sourced+CLI-runnable pattern. Needs ANTHROPIC_API_KEY
# set in the environment - degrades with a clear in-app error, not a
# crash, when it's missing.
source("ai_pdf_core.R")

shinyServer(function(input, output, session) {

  # shiny::validate()/need() only ever surfaces to the user when its call
  # stack bottoms out in a render*() output - inside a downloadHandler()'s
  # content function (every download in this app), the exact same call
  # still throws (the same silent "shiny.silent.error" condition), but
  # there's no output context to catch and display it, so the handler just
  # stops with no visible sign anything happened - the browser still
  # attempts a download and gets back nothing usable. Confirmed live: this
  # is exactly the bug reported for Merge with only one file selected -
  # download fires, gets silently cancelled, zero notification shown. This
  # was the ORIGINAL form of `run_op()` (and two other call sites in this
  # file) before this fix - every real error in every one of this app's 9
  # downloadHandlers had the same silent-failure bug, not just Merge.
  # notify_stop() is the correct replacement anywhere outside a render*()
  # body: show the message for real, then req(FALSE) to halt (req()'s own
  # silent stop is fine here since the explicit showNotification() already
  # fired) - confirmed this actually prevents the browser from attempting
  # a download at all, not just suppressing the notification.
  notify_stop <- function(cond, msg) {
    if (!isTRUE(cond)) {
      showNotification(msg, type = "error", duration = NULL)
      req(FALSE)
    }
  }

  # pdftk_core.R's op_* functions just stop() on error - wrapped here so
  # the message actually reaches the user (Shiny's default error
  # sanitization can otherwise reduce it to a generic "An error occurred"
  # in some deployment contexts).
  run_op <- function(expr) {
    tryCatch(expr, error = function(e) notify_stop(FALSE, conditionMessage(e)))
  }

  # ---- Merge ----
  output$merge_file_list <- renderUI({
    req(input$merge_files)
    tags$ol(lapply(input$merge_files$name, tags$li))
  })

  output$merge_download <- downloadHandler(
    filename = function() "merged.pdf",
    content = function(file) {
      notify_stop(!is.null(input$merge_files) && nrow(input$merge_files) >= 2, "Select at least two PDF files to merge.")
      run_op(op_merge(input$merge_files$datapath, output = file))
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
      run_op(op_pages(input$pages_file$datapath, input$pages_range, mode = input$pages_mode, output = file))
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
      run_op(op_rotate(input$rotate_file$datapath, input$rotate_range, input$rotate_deg, output = file))
    }
  )

  # ---- Compress ----
  output$compress_download <- downloadHandler(
    filename = function() "compressed.pdf",
    content = function(file) {
      req(input$compress_file)
      run_op(op_compress(input$compress_file$datapath, output = file, level = input$compress_level, linearize = input$compress_linearize))
    }
  )

  # ---- Encrypt / Decrypt ----
  output$crypt_download <- downloadHandler(
    filename = function() if (input$crypt_mode == "encrypt") "encrypted.pdf" else "decrypted.pdf",
    content = function(file) {
      req(input$crypt_file)
      run_op(op_crypt(input$crypt_file$datapath, mode = input$crypt_mode, password = input$crypt_pw, output = file))
    }
  )

  # ---- Metadata ----
  observeEvent(input$meta_file, {
    req(input$meta_file)
    keys <- op_metadata_read(input$meta_file$datapath)
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
      run_op(op_metadata_write(
        input$meta_file$datapath,
        title = input$meta_title, author = input$meta_author,
        subject = input$meta_subject, keywords = input$meta_keywords,
        output = file
      ))
    }
  )

  # ---- PDF to Images ----
  images_total <- reactive({
    req(input$images_file)
    pdf_page_count(input$images_file$datapath)
  })

  output$images_info <- renderUI({
    req(input$images_file)
    n <- images_total()
    tags$p(tags$small(sprintf("%d page(s) in this document.", n)))
  })

  # Best-effort resolved page list, used only to decide the download
  # filename (single .jpg vs .zip) - an invalid range just falls through
  # to the .zip branch, whose real error comes from op_pdf_to_images_zip()
  # re-parsing the range for real and throwing the precise message.
  images_resolved_pages <- reactive({
    req(input$images_file)
    n <- images_total()
    if (!is.finite(n)) return(integer(0))
    range_str <- trimws(input$images_range)
    parsed <- if (range_str == "") seq_len(n) else parse_page_range(range_str, n)
    if (is.character(parsed)) integer(0) else parsed
  })

  output$images_download <- downloadHandler(
    filename = function() if (length(images_resolved_pages()) == 1) "page.jpg" else "pages.zip",
    content = function(file) {
      req(input$images_file)
      if (length(images_resolved_pages()) == 1) {
        run_op({
          img_dir <- tempfile()
          dir.create(img_dir, recursive = TRUE)
          on.exit(unlink(img_dir, recursive = TRUE, force = TRUE))
          out <- op_pdf_to_images(input$images_file$datapath, input$images_range, input$images_dpi, img_dir)
          file.copy(out[1], file, overwrite = TRUE)
        })
      } else {
        run_op(op_pdf_to_images_zip(input$images_file$datapath, input$images_range, input$images_dpi, file))
      }
    }
  )

  # ---- AI: PDF to Excel/Word ----
  output$ai_download <- downloadHandler(
    filename = function() {
      fmts <- input$ai_formats
      if (length(fmts) == 1) paste0("converted.", if (fmts == "excel") "xlsx" else "docx") else "converted.zip"
    },
    content = function(file) {
      req(input$ai_file)
      notify_stop(length(input$ai_formats) > 0, "Select at least one output format.")
      withProgress(message = "Asking Claude to read the PDF...", value = 0.3, {
        run_op(op_ai_convert_zip(input$ai_file$datapath, input$ai_formats, file, hint = input$ai_hint))
      })
    }
  )
})
