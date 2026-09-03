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

# The actual merge/extract/rotate/compress/encrypt/metadata logic lives in
# pdftk_core.R, not duplicated here - it's also directly runnable as a CLI
# (`Rscript pdftk_core.R ...`) for a file too large/sensitive to upload, or
# to debug a failure locally with a real R console instead of just
# whatever showNotification surfaces. See README.
source("pdftk_core.R")

shinyServer(function(input, output, session) {

  # pdftk_core.R's op_* functions just stop() on error - wrapped here so
  # the message actually reaches the user (Shiny's default error
  # sanitization can otherwise reduce it to a generic "An error occurred"
  # in some deployment contexts) via the same validate(need(...)) pattern
  # every other error in this app already uses.
  run_op <- function(expr) {
    tryCatch(expr, error = function(e) validate(need(FALSE, conditionMessage(e))))
  }

  # ---- Merge ----
  output$merge_file_list <- renderUI({
    req(input$merge_files)
    tags$ol(lapply(input$merge_files$name, tags$li))
  })

  output$merge_download <- downloadHandler(
    filename = function() "merged.pdf",
    content = function(file) {
      validate(need(nrow(input$merge_files) >= 2, "Select at least two PDF files to merge."))
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
      run_op(op_compress(input$compress_file$datapath, output = file, linearize = input$compress_linearize))
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
})
