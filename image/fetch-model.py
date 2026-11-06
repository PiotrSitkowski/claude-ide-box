"""Download a GLiNER model and the encoder it names, at image build time.

    python3 fetch-model.py REPO REVISION OUT_DIR

Runs only during 'docker build'; the running container has no network and
loads the files with HF_HUB_OFFLINE=1.
"""

import json
import os
import sys

from huggingface_hub import snapshot_download


def main():
    repo, revision, out = sys.argv[1:4]
    if not revision:
        sys.exit("fetch-model: pin GLINER_REVISION to a commit of %s" % repo)
    snapshot_download(repo, revision=revision, local_dir=out)
    with open(os.path.join(out, "gliner_config.json")) as f:
        encoder = json.load(f).get("model_name")
    if encoder:
        # The tokenizer and config of the encoder go to the HF cache, where
        # transformers finds them offline.
        snapshot_download(encoder, allow_patterns=["*.json", "*.model", "*.txt", "*.safetensors", "*.bin"])
    print("fetched %s@%s (encoder %s) into %s" % (repo, revision, encoder, out))


if __name__ == "__main__":
    main()
