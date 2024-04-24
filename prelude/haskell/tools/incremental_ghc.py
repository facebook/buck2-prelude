#!/usr/bin/env python3

"""Helper script to compile haskell modules incrementally

"""

import argparse
import graphlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys

def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        add_help=False,
        fromfile_prefix_chars="@")
    parser.add_argument(
        "--ghc",
        required=True,
        type=str,
        help="Path to the Haskell compiler GHC.")
    parser.add_argument(
        "--abi",
        type=str,
        action="append",
        help="File with ABI hash for a interface file.")
    parser.add_argument(
        "--source",
        required=True,
        type=str,
        help="Haskell module source file.")

    args, ghc_args = parser.parse_known_args()

    metadata_file = os.environ.get('ACTION_METADATA')

    if metadata_file:
        # open metadata file as json
        with open(metadata_file) as f:
            digests = json.load(f)
            #print(digests, file=sys.stderr)

    cmd = [
        args.ghc,
        args.source,
    ] + ghc_args

    subprocess.check_call(cmd)


if __name__ == "__main__":
    main()
