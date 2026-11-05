# Documents: pandoc, LibreOffice (headless), PDF tools, OCR (Polish, English), python-docx/openpyxl/pypdf
#
# For work on contracts, reports, spreadsheets and scans rather than code:
#   pandoc report.md -o report.docx
#   soffice --headless --convert-to pdf contract.docx
#   pdftotext scan.pdf - ; tesseract page.png - -l pol
ARG BASE_IMAGE=claude-ide-box/base:latest
FROM ${BASE_IMAGE}
USER root
# Root steps must not leave files in the home directory (see setup).
ENV HOME=/root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      pandoc libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
      poppler-utils qpdf ghostscript tesseract-ocr tesseract-ocr-pol tesseract-ocr-eng \
      python3-docx python3-openpyxl python3-pypdf fonts-dejavu fonts-liberation \
 && rm -rf /var/lib/apt/lists/* \
 && pandoc --version | head -n 1 \
 && soffice --version \
 && tesseract --list-langs
ENV HOME=/home/claude
USER claude
