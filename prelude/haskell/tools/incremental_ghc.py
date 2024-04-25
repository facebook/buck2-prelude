#!/usr/bin/env python3

"""Helper script to compile haskell modules incrementally

"""

import argparse
import json
import os
from pathlib import Path
from pprint import pprint
import subprocess
import tempfile
import sys


# this class keeps track of a path of a file and its corresponding digest
class FileDigest:
    def __init__(self, path, digest):
        self.path = path
        self.digest = digest

    def __hash__(self):
        return hash((self.path, self.digest))

    def __eq__(self, other):
        return self.path == other.path and self.digest == other.digest

    def __repr__(self):
        return f"FileDigest({self.path}, {self.digest})"

    @staticmethod
    def from_dict(d):
        return FileDigest(Path(d["path"]), d["digest"])

    def to_dict(self):
        return {"path": str(self.path), "digest": self.digest}


class FileDigestEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, FileDigest):
            return o.to_dict()
        elif isinstance(o, set):
            return [self.default(e) for e in o]
        return super().default(o)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--state",
        required=True,
        help="Path to the state file.",
    )
    parser.add_argument(
        "--ghc", required=True, type=str, help="Path to the Haskell compiler GHC."
    )
    parser.add_argument(
        "--abi",
        type=Path,
        default=[],
        action="append",
        help="File with ABI hash for a interface file.",
    )
    parser.add_argument(
        "--source", required=True, type=str, help="Haskell module source file."
    )

    args, ghc_args = parser.parse_known_args()

    metadata_file = os.environ["ACTION_METADATA"]

    with open(metadata_file) as f:
        metadata = json.load(f)

        # check version
        version = metadata.get("version")
        if version != 1:
            sys.exit("version of metadata file not supported: {}".format(version))

        digests = set([FileDigest.from_dict(entry) for entry in metadata["digests"]])

    if os.path.exists(args.state):
        with open(args.state) as f:
            old_state = json.load(f)

        old_state = set([FileDigest.from_dict(entry) for entry in old_state])

        # delete file
        os.remove(args.state)
    else:
        old_state = set()

    # filter out all files that have a corresponding ABI hash file, remove the `.hash` extension
    hi_files = set([abi.with_suffix("") for abi in args.abi])

    digests = set([d for d in digests if d.path not in hi_files])

    diff = digests ^ old_state  # changed, newly added, removed
    if diff:
        print("Files that changed:", file=sys.stderr)
        pprint(diff, stream=sys.stderr)

    needs_recompilation = digests != old_state

    if needs_recompilation:
        cmd = [
            args.ghc,
            args.source,
        ] + ghc_args

        subprocess.check_call(cmd)
    else:
        print("No recompilation needed", file=sys.stderr)

    # 2. write file
    try:
        with open(args.state, "w") as f:
            json.dump(digests, f, cls=FileDigestEncoder, indent=2)
    except Exception as e:
        # remove incomplete state file
        os.remove(args.state)
        raise e


if __name__ == "__main__":
    main()
