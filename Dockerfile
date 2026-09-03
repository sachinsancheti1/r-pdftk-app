FROM rocker/r-ver:4.4.1

# nginx/proxy deps (Basic Auth gateway, matching the other apps) +
# pdftk-java (the actual "pdftk" binary on modern Ubuntu - the classic C++
# pdftk was dropped from Debian/Ubuntu; pdftk-java is a command-line
# compatible Java port, needs a headless JRE) + libjpeg/poppler dev headers
# for the qpdf and pdftools R packages respectively.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev zlib1g-dev \
    nginx apache2-utils gettext-base \
    pdftk-java default-jre-headless \
    libjpeg-dev libpoppler-cpp-dev \
    && rm -rf /var/lib/apt/lists/*

RUN rm -f /etc/nginx/sites-enabled/default

# officer needs rlang >= 1.1.7 at load time (a NAMESPACE-level check, not
# just a DESCRIPTION Depends bound); the base image's preinstalled rlang
# predates that, and install.packages() below doesn't force an upgrade of
# an already-satisfied-looking dependency. Confirmed by a real build
# failure (officer installed as a binary, then failed requireNamespace()
# with "namespace 'rlang' 1.1.6 is being loaded, but >= 1.1.7 is
# required") before this explicit upgrade step was added.
RUN Rscript -e "install.packages('rlang', repos='https://packagemanager.posit.co/cran/__linux__/jammy/latest')"

# Posit Package Manager's Linux binary mirror (jammy = Ubuntu 22.04, which
# rocker/r-ver:4.4.1 is based on) installs pre-built binaries instead of
# compiling from source - including officer's font-rendering deps
# (systemfonts/textshaping/ragg), which Posit's binaries ship statically
# linked, avoiding a separate apt-get for freetype/fontconfig/harfbuzz.
# install.packages() doesn't make R exit non-zero just because some
# packages in the list failed, so verify explicitly and fail the build
# loudly (by name) if anything didn't actually land.
RUN Rscript -e "install.packages(c('shiny','qpdf','pdftools','zip','httr2','base64enc','openxlsx','officer'), repos='https://packagemanager.posit.co/cran/__linux__/jammy/latest')"
RUN Rscript -e "pkgs <- c('shiny','qpdf','pdftools','zip','httr2','base64enc','openxlsx','officer'); ok <- TRUE; for (p in pkgs) { r <- tryCatch({ library(p, character.only=TRUE); TRUE }, error = function(e) { cat('FAILED to load', p, '-', conditionMessage(e), '\n'); FALSE }); if (!r) ok <- FALSE }; if (!ok) quit(status=1)"

WORKDIR /app
COPY ui.R /app/ui.R
COPY server.R /app/server.R
COPY pdftk_core.R /app/pdftk_core.R
COPY ai_pdf_core.R /app/ai_pdf_core.R

RUN mkdir -p /etc/nginx/templates
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV PORT=3838
EXPOSE 3838
CMD ["/start.sh"]
