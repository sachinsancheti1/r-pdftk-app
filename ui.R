# ui.R
library(shiny)

# Shows a clear, unmissable "please refresh" banner when the Shiny session
# disconnects (server restart, crash, idle timeout, etc.). Shiny's own
# default disconnect behavior is just a subtle page-dimming effect - easy to
# miss unless you already know what a Shiny disconnect looks like. No
# auto-reconnect attempt: a Railway-hosted session is not reliably
# resumable, so the honest answer is always "refresh," not "wait."
# Kept identical across every app - copy verbatim, don't diverge.
disconnect_overlay <- function() {
  tagList(
    tags$head(tags$style(HTML("
      #shiny-disconnect-overlay {
        display: none;
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        background: rgba(20, 20, 20, 0.75);
        z-index: 2147483647;
        align-items: center;
        justify-content: center;
      }
      #shiny-disconnect-overlay .box {
        background: #fff;
        border-radius: 8px;
        padding: 28px 32px;
        max-width: 380px;
        text-align: center;
        box-shadow: 0 4px 24px rgba(0,0,0,0.3);
        font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif;
      }
      #shiny-disconnect-overlay .title {
        font-size: 18px;
        font-weight: 600;
        color: #b02a2a;
        margin-bottom: 8px;
      }
      #shiny-disconnect-overlay .msg {
        font-size: 14px;
        color: #333;
        margin-bottom: 18px;
        line-height: 1.4;
      }
      #shiny-disconnect-overlay button {
        background: #2c7be5;
        color: #fff;
        border: none;
        border-radius: 5px;
        padding: 10px 22px;
        font-size: 14px;
        cursor: pointer;
      }
      #shiny-disconnect-overlay button:hover { background: #1a63c4; }
    ")),
    tags$script(HTML("
      $(document).on('shiny:disconnected', function() {
        document.getElementById('shiny-disconnect-overlay').style.display = 'flex';
      });
    "))),
    tags$div(id = "shiny-disconnect-overlay",
      tags$div(class = "box",
        tags$div(class = "title", "Connection lost"),
        tags$div(class = "msg",
          "This session has disconnected from the server. Your work in this ",
          "session can't be recovered — please refresh the page to start a new one."),
        tags$button("Refresh page", onclick = "location.reload()")
      )
    )
  )
}

# Visual styling pulled from the Vitrag (vitrag-6) design system - navy +
# teal palette, sharp/square corners (radius 0 throughout, not rounded),
# uppercase tracking-wide labels/buttons, Source Sans Pro. Layered on top of
# Shiny's default Bootstrap 3 via a plain CSS override block rather than a
# Shiny theming package, since only the visual language (not the
# React/Tailwind component structure) is being reused here.
vitrag_theme <- function() {
  tagList(
    tags$head(
      tags$link(rel = "stylesheet", href = "https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@400;600;700&display=swap"),
      tags$style(HTML("
        :root {
          --vblue: #384764;
          --vgreen: #00a99e;
          /* vitrag-6's source gives no hex for this one (only
             oklch(0.42 0.09 180)) - precisely computed via the culori
             library rather than eyeballed; an earlier guess (#00786f)
             was visibly off. */
          --vgreen-dark: #005c4f;
          --vorange: #ff7824;
          --vsection: #f2f5f9;
          /* vitrag's --border: oklch(0.91 0 0) and --muted-foreground:
             oklch(0.42 0.04 257), both precisely computed rather than
             guessed (form-control border was a hand-picked #c7ccd6
             before, unrelated to any real vitrag token). */
          --vborder: #e1e1e1;
          --vmuted: #3f4e63;
        }
        body {
          font-family: 'Source Sans 3', 'Source Sans Pro', system-ui, sans-serif;
          color: var(--vblue);
          background: #ffffff;
          font-size: 15px;
        }
        /* Bootstrap's default <small>/.help-block shrink to ~85% of a
           14px base (~12px) reads as genuinely too small once the base
           itself is 15px - fixed to a real, comfortable size instead of
           a relative shrink. */
        small, .help-block {
          font-size: 13px;
          color: var(--vmuted);
        }
        h1, h2, h3, h4, h5, legend {
          font-family: 'Source Sans 3', 'Source Sans Pro', system-ui, sans-serif;
          color: var(--vblue);
          font-weight: 600;
        }
        .container-fluid > h1:first-child {
          padding: 18px 0 8px;
          border-bottom: 3px solid var(--vgreen);
          margin-bottom: 4px;
        }
        a { color: var(--vblue); }
        a:hover { color: var(--vgreen-dark); }

        /* Tabs: bold uppercase labels, teal underline on the active tab -
           matches vitrag's .nav-link underline-indicator pattern. */
        .nav-tabs { border-bottom: 2px solid var(--vsection); }
        .nav-tabs > li > a {
          font-family: 'Source Sans 3', sans-serif;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.03em;
          font-size: 15px;
          padding: 12px 18px;
          color: var(--vblue);
          border-radius: 0;
          border: none;
          background: transparent;
        }
        .nav-tabs > li.active > a,
        .nav-tabs > li.active > a:hover,
        .nav-tabs > li.active > a:focus {
          color: var(--vblue);
          background: transparent;
          border: none;
          border-bottom: 3px solid var(--vgreen);
        }
        .nav-tabs > li > a:hover {
          background: var(--vsection);
          border: none;
          border-bottom: 3px solid var(--vgreen);
        }

        /* Sidebar: light section background, sharp corners, no shadow. */
        .well {
          background: var(--vsection);
          border: none;
          border-radius: 0;
          box-shadow: none;
        }

        /* Form fields: sharp corners, uppercase tracking-wide labels, teal focus ring. */
        label {
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.03em;
          font-size: 14px;
          color: var(--vblue);
        }
        .form-control {
          border-radius: 0;
          border: 1px solid var(--vborder);
          font-size: 15px;
          height: auto;
          padding: 8px 12px;
        }
        .form-control:focus {
          border-color: var(--vgreen);
          box-shadow: 0 0 0 1px var(--vgreen);
        }

        /* Buttons: sharp corners, bold uppercase, navy fill / teal hover -
           matches vitrag's .btn-vitrag. */
        .btn, .btn-default, .btn-primary {
          border-radius: 0;
          border: 2px solid var(--vblue);
          background: var(--vblue);
          color: #ffffff;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.03em;
          font-size: 15px;
          padding: 10px 24px;
          transition: all 0.15s ease;
        }
        .btn:hover, .btn-default:hover, .btn-primary:hover {
          background: var(--vgreen-dark);
          border-color: var(--vgreen-dark);
          color: #ffffff;
        }
        /* Positive/add actions get the teal instead of navy - still
           sharp-cornered/uppercase/bold like every other button. */
        .btn-success {
          border-radius: 0;
          border: 2px solid var(--vgreen-dark);
          background: var(--vgreen-dark);
          color: #ffffff;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.03em;
          font-size: 15px;
          padding: 10px 24px;
          transition: all 0.15s ease;
        }
        .btn-success:hover {
          background: var(--vblue);
          border-color: var(--vblue);
          color: #ffffff;
        }

        /* Radio/checkbox accent color. */
        input[type='radio'], input[type='checkbox'] { accent-color: var(--vgreen); }
      "))
    )
  )
}

shinyUI(fluidPage(
  disconnect_overlay(),
  vitrag_theme(),
  titlePanel("PDF Toolkit: Merge, Extract, Rotate, Encrypt, Metadata"),
  tags$p(tags$small(
    "All processing happens locally on this server (nothing is sent to a third-party PDF site). ",
    "Uploaded files are written to a temp folder for the duration of the operation and not kept afterward."
  )),

  tabsetPanel(
    tabPanel("Merge",
      br(),
      sidebarLayout(
        sidebarPanel(
          fileInput("merge_files", "PDF files (select in the order you want them merged)",
                     multiple = TRUE, accept = ".pdf"),
          tags$p(tags$small("Files are merged in the order shown below — reorder by re-selecting if needed.")),
          uiOutput("merge_file_list"),
          downloadButton("merge_download", "Merge & Download")
        ),
        mainPanel(
          tags$p("Combine multiple PDFs into a single document.")
        )
      )
    ),

    tabPanel("Extract / Delete Pages",
      br(),
      sidebarLayout(
        sidebarPanel(
          fileInput("pages_file", "PDF file", accept = ".pdf"),
          uiOutput("pages_info"),
          radioButtons("pages_mode", "Action",
                       choices = c("Keep only these pages" = "keep", "Delete these pages" = "delete")),
          textInput("pages_range", "Pages (e.g. 1-3,5,8-10)", value = ""),
          downloadButton("pages_download", "Apply & Download")
        ),
        mainPanel(
          tags$p("Extract a subset of pages into a new PDF, or remove specific pages and keep the rest.")
        )
      )
    ),

    tabPanel("Rotate",
      br(),
      sidebarLayout(
        sidebarPanel(
          fileInput("rotate_file", "PDF file", accept = ".pdf"),
          uiOutput("rotate_info"),
          textInput("rotate_range", "Pages to rotate (e.g. 1-3,5 or leave blank for all)", value = ""),
          selectInput("rotate_deg", "Rotate", choices = c("90° clockwise" = "90", "180°" = "180", "90° counter-clockwise" = "-90")),
          downloadButton("rotate_download", "Rotate & Download")
        ),
        mainPanel(
          tags$p("Rotate specific pages (or the whole document) clockwise or counter-clockwise, relative to their current orientation.")
        )
      )
    ),

    tabPanel("Compress",
      br(),
      sidebarLayout(
        sidebarPanel(
          fileInput("compress_file", "PDF file", accept = ".pdf"),
          checkboxInput("compress_linearize", "Also linearize (optimize for fast web viewing)", value = FALSE),
          downloadButton("compress_download", "Compress & Download")
        ),
        mainPanel(
          tags$p("Reduce file size without changing page content."),
          tags$p(tags$small("Results vary a lot by source file — a PDF already produced by a modern tool may not shrink much further."))
        )
      )
    ),

    tabPanel("Encrypt / Decrypt",
      br(),
      sidebarLayout(
        sidebarPanel(
          fileInput("crypt_file", "PDF file", accept = ".pdf"),
          radioButtons("crypt_mode", "Action", choices = c("Encrypt (add a password)" = "encrypt", "Decrypt (remove a password)" = "decrypt")),
          passwordInput("crypt_pw", "Password"),
          downloadButton("crypt_download", "Apply & Download")
        ),
        mainPanel(
          tags$p("Add or remove an open-password on a PDF. For encryption, the password is required to open the file afterward."),
          tags$p(tags$small("For decryption, this must be the file's current password."))
        )
      )
    ),

    tabPanel("Metadata",
      br(),
      sidebarLayout(
        sidebarPanel(
          fileInput("meta_file", "PDF file", accept = ".pdf"),
          textInput("meta_title", "Title", value = ""),
          textInput("meta_author", "Author", value = ""),
          textInput("meta_subject", "Subject", value = ""),
          textInput("meta_keywords", "Keywords", value = ""),
          downloadButton("meta_download", "Update & Download")
        ),
        mainPanel(
          tags$p("View and edit a PDF's Title/Author/Subject/Keywords metadata fields."),
          tags$p(tags$small("Uploading a file pre-fills the fields below with its current metadata, if any."))
        )
      )
    )
  )
))
