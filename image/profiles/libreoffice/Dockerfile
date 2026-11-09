# LibreOffice (headless): convert to PDF, recalculate formulas, open .doc/.xls and OpenDocument files
#
#   soffice --headless --convert-to pdf contract.docx
#   soffice --headless --convert-to xlsx --outdir out/ budget.xls
ARG BASE_IMAGE=claude-ide-box/base:latest
FROM ${BASE_IMAGE}
USER root
# Root steps must not leave files in the home directory (see setup).
ENV HOME=/root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
      fonts-dejavu fonts-liberation \
 && rm -rf /var/lib/apt/lists/* \
 && soffice --version
ENV HOME=/home/claude
USER claude
