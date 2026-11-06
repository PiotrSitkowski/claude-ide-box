# pii-airgap image: text extraction tools, the detector and (optionally) a
# NER model, all baked in at build time. At run time the container gets
# --network none, so nothing can be downloaded or sent anywhere.
#
#   docker build -f image/Dockerfile --build-arg NER=spacy -t pii-airgap .
#
# NER=gliner  GLiNER (needs huggingface.co and download.pytorch.org
#             while building)
# NER=spacy   spaCy xx_ent_wiki_sm (default; needs github.com while building)
# NER=none    checksums, patterns and user lists only
ARG BASE_IMAGE=docker.io/library/ubuntu:24.04
FROM ${BASE_IMAGE}

ARG NER=spacy
ARG TORCH_VERSION=2.9.1
ARG GLINER_MODEL=urchade/gliner_multi-v2.1
# Commit of urchade/gliner_multi-v2.1 on huggingface.co (lastModified 2025-12-08); pinned so a
# rebuild gets the same weights. Licence: Apache-2.0 (model card, checked 2026-11-06).
ARG GLINER_REVISION=443d26d654e0324125a96bebd8e796c14ff2efe6
# The encoder GLiNER names (tokenizer and config), also pinned (lastModified 2023-04-06).
# Licence: MIT (model card, checked 2026-11-06).
ARG GLINER_ENCODER=microsoft/mdeberta-v3-base
ARG GLINER_ENCODER_REVISION=a0484667b22365f84929a935b5e50a51f71f159d
ARG SPACY_MODEL_URL=https://github.com/explosion/spacy-models/releases/download/xx_ent_wiki_sm-3.8.0/xx_ent_wiki_sm-3.8.0-py3-none-any.whl
ARG SPACY_MODEL_SHA256=6f3c4b853852ea9e9d2dc76cc950dddb10a7e4c42d813308caefe6c5e8be2f0a

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv ca-certificates poppler-utils \
      tesseract-ocr tesseract-ocr-pol tesseract-ocr-eng tesseract-ocr-deu \
      libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
 && rm -rf /var/lib/apt/lists/*

ENV VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH HF_HOME=/opt/pii-airgap/hf
COPY image/requirements-spacy.txt image/requirements-gliner.txt image/fetch-model.py /opt/pii-airgap/build/
# Behind a TLS-intercepting proxy, pass its CA for the build only:
#   docker build --secret id=build_ca,src=/path/to/ca.pem ...
# It is mounted for this step and is not stored in the image.
RUN --mount=type=secret,id=build_ca,required=false \
    if [ -s /run/secrets/build_ca ]; then \
      export PIP_CERT=/run/secrets/build_ca SSL_CERT_FILE=/run/secrets/build_ca REQUESTS_CA_BUNDLE=/run/secrets/build_ca; \
    fi \
 && python3 -m venv /opt/venv \
 && case "$NER" in \
      gliner) \
        pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu "torch==${TORCH_VERSION}" \
        && pip install --no-cache-dir -r /opt/pii-airgap/build/requirements-gliner.txt \
        && python3 /opt/pii-airgap/build/fetch-model.py "$GLINER_MODEL" "$GLINER_REVISION" /opt/pii-airgap/model \
             "$GLINER_ENCODER" "$GLINER_ENCODER_REVISION" /opt/pii-airgap/encoder ;; \
      spacy) \
        pip install --no-cache-dir -r /opt/pii-airgap/build/requirements-spacy.txt \
        && python3 -c 'import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], "/tmp/" + sys.argv[1].rsplit("/", 1)[1])' "$SPACY_MODEL_URL" \
        && echo "$SPACY_MODEL_SHA256  /tmp/${SPACY_MODEL_URL##*/}" | sha256sum -c - \
        && pip install --no-cache-dir --no-deps "/tmp/${SPACY_MODEL_URL##*/}" \
        && rm -f /tmp/*.whl ;; \
      none) ;; \
      *) echo "unknown NER=$NER" >&2; exit 1 ;; \
    esac \
 && rm -rf /root/.cache

COPY detector/pii_airgap /opt/pii-airgap/pii_airgap
# The container runs with the caller's UID, which has no /etc/passwd entry;
# USER and LOGNAME keep getpass.getuser() (used by torch) from failing.
ENV PYTHONPATH=/opt/pii-airgap PII_AIRGAP_NER=${NER} HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    PYTHONDONTWRITEBYTECODE=1 PII_AIRGAP_OCR_LANGS=pol+eng+deu USER=pii-airgap LOGNAME=pii-airgap
RUN chmod -R a+rX /opt/pii-airgap /opt/venv

# Self-test without network: the model must load from the image and find a
# name; the checksum rules must find a PESEL. A broken model fails the build.
# It runs as a UID without a passwd entry, as the container does.
USER 54321:54321
RUN mkdir -p /tmp/selftest \
 && printf 'Umowa z Janem Kowalskim, PESEL 44051401359, Warszawa.\n' >/tmp/selftest/a.txt \
 && python3 -P -m pii_airgap scan /tmp/selftest --no-cache --json >/tmp/selftest.json \
 && python3 -c 'import json, os, sys; r = json.load(open("/tmp/selftest.json")); c = r["files"][0]["counts"]; \
assert "PESEL" in c, c; assert os.environ["PII_AIRGAP_NER"] == "none" or "PERSON" in c, c; print("self-test", c)' \
 && rm -rf /tmp/selftest /tmp/selftest.json

WORKDIR /opt/pii-airgap
USER 65534:65534
ENTRYPOINT ["python3", "-P", "-m", "pii_airgap"]
