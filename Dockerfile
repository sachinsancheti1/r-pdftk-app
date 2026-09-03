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

# Posit Package Manager's Linux binary mirror (jammy = Ubuntu 22.04, which
# rocker/r-ver:4.4.1 is based on) installs pre-built binaries instead of
# compiling from source. install.packages() doesn't make R exit non-zero
# just because some packages in the list failed, so verify explicitly and
# fail the build loudly (by name) if anything didn't actually land.
RUN Rscript -e "install.packages(c('shiny','qpdf','pdftools'), repos='https://packagemanager.posit.co/cran/__linux__/jammy/latest')"
RUN Rscript -e "pkgs <- c('shiny','qpdf','pdftools'); missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly=TRUE)]; if (length(missing) > 0) { cat('FAILED to install R package(s):', paste(missing, collapse=', '), '\n'); quit(status=1) }"

WORKDIR /app
COPY ui.R /app/ui.R
COPY server.R /app/server.R

RUN mkdir -p /etc/nginx/templates
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV PORT=3838
EXPOSE 3838
CMD ["/start.sh"]
