# Documents: read and edit Word, Excel, PowerPoint and PDF files (python-docx, openpyxl, pypdf, pandoc, poppler, qpdf)
#
# The light part of the `office` profile, for work on contracts, reports and
# spreadsheets without LibreOffice:
#   pandoc report.md -o report.docx
#   pdftotext contract.pdf - ; qpdf --split-pages scan.pdf page-%d.pdf
# Combine with `libreoffice` (conversion to PDF, formula recalculation) and
# `ocr` (scans) as needed: PROFILE="docs libreoffice ocr".
ARG BASE_IMAGE=claude-ide-box/base:latest
FROM ${BASE_IMAGE}
USER root
# Root steps must not leave files in the home directory (see setup).
ENV HOME=/root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      pandoc poppler-utils qpdf ghostscript \
      python3-docx python3-openpyxl python3-pypdf fonts-dejavu fonts-liberation \
 && rm -rf /var/lib/apt/lists/* \
 && pandoc --version | head -n 1 \
 && python3 -c 'import docx, openpyxl, pypdf'
ENV HOME=/home/claude
USER claude
