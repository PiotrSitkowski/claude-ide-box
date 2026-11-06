"""Download a GLiNER model and the encoder it names, at image build time.

    python3 fetch-model.py REPO REVISION OUT_DIR ENCODER ENCODER_REVISION ENCODER_DIR

Both are fetched at pinned commits. The encoder (its tokenizer and config)
goes to ENCODER_DIR, and the model's gliner_config.json is pointed at that
directory, so loading needs neither the network nor a Hugging Face cache
lookup by name. Runs only during 'docker build'; the running container has
no network and loads the files with HF_HUB_OFFLINE=1.
"""

import json
import os
import sys

from huggingface_hub import snapshot_download


def main():
    repo, revision, out, encoder, encoder_revision, encoder_dir = sys.argv[1:7]
    for name, value in (("GLINER_REVISION", revision), ("GLINER_ENCODER_REVISION", encoder_revision)):
        if len(value) != 40 or any(c not in "0123456789abcdef" for c in value):
            sys.exit("fetch-model: %s must be a full commit hash, got %r" % (name, value))
    snapshot_download(repo, revision=revision, local_dir=out)
    config_path = os.path.join(out, "gliner_config.json")
    with open(config_path) as f:
        config = json.load(f)
    named = config.get("model_name")
    if named != encoder:
        sys.exit("fetch-model: %s@%s names encoder %r, but %r is pinned (GLINER_ENCODER)"
                 % (repo, revision, named, encoder))
    snapshot_download(encoder, revision=encoder_revision, local_dir=encoder_dir,
                      allow_patterns=["*.json", "*.model", "*.txt", "*.safetensors", "*.bin"])
    config["model_name"] = encoder_dir
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print("fetched %s@%s into %s, encoder %s@%s into %s"
          % (repo, revision, out, encoder, encoder_revision, encoder_dir))


if __name__ == "__main__":
    main()
