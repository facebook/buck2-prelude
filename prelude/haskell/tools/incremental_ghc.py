#!/usr/bin/env python3

"""Helper script to compile haskell modules incrementally

"""

import argparse
import graphlib
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
        return FileDigest(d['path'], d['digest'])

    def to_dict(self):
        return {'path': self.path, 'digest': self.digest}


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        add_help=False,
        fromfile_prefix_chars="@")
    parser.add_argument(
        "--state",
        required=True,
        help="Path to the state file.",
    )
    parser.add_argument(
        "--ghc",
        required=True,
        type=str,
        help="Path to the Haskell compiler GHC.")
    parser.add_argument(
        "--abi",
        type=str,
        default=[],
        action="append",
        help="File with ABI hash for a interface file.")
    parser.add_argument(
        "--source",
        required=True,
        type=str,
        help="Haskell module source file.")

    args, ghc_args = parser.parse_known_args()

    metadata_file = os.environ.get('ACTION_METADATA')

    needs_recompilation = True

    if os.path.exists(args.state):
        with open(args.state) as f:
            old_state = json.load(f)

            print(old_state, file=sys.stderr)

        # 1. delete file
        os.remove(args.state)
    else:
        old_state = {'digests': []}

    if metadata_file:
        with open(metadata_file) as f:
            metadata = json.load(f)

            # check version
            assert metadata.get('version') == 1

            digests = set([FileDigest.from_dict(entry) for entry in metadata['digests']])

            pprint(digests, stream=sys.stderr)

    if needs_recompilation:
        cmd = [
            args.ghc,
            args.source,
        ] + ghc_args

        subprocess.check_call(cmd)

    # 2. write file
    with open(args.state, 'w') as f:
        json.dump(old_state, f)


if __name__ == "__main__":
    main()
