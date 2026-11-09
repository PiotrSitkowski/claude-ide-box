# OCR: read text from scans and photos (Tesseract; languages from OCR_LANGUAGES, default English)
#
#   tesseract page.png - -l deu+eng
#   pdftoppm -r 300 -png scan.pdf page ; tesseract page-1.png - -l eng
# The languages are a global setting, e.g. OCR_LANGUAGES=eng deu chi_sim in
# ~/.config/claude-ide-box/config; `claude-ide-box setup` rebuilds the image.
ARG BASE_IMAGE=claude-ide-box/base:latest
FROM ${BASE_IMAGE}
ARG OCR_LANGUAGES=eng
USER root
# Root steps must not leave files in the home directory (see setup).
ENV HOME=/root
# Tesseract codes (chi_sim) are Debian package suffixes with "-" (chi-sim).
RUN set -e; \
    pkgs=""; \
    for l in $OCR_LANGUAGES; do \
      case "$l" in *[!a-z_]*|"") echo "invalid OCR language '$l'" >&2; exit 1 ;; esac; \
      pkgs="$pkgs tesseract-ocr-$(printf '%s' "$l" | tr _ -)"; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends tesseract-ocr poppler-utils $pkgs; \
    rm -rf /var/lib/apt/lists/*; \
    tesseract --list-langs
ENV HOME=/home/claude
USER claude
