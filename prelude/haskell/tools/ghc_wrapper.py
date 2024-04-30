#!/usr/bin/env python3

"""Wrapper script to call ghc.

It accepts a dep file where all used inputs are written to. For any passed ABI
hash file, the corresponding interface is marked as unused, so these can change
without triggering compilation actions.

"""

import argparse
import json
import os
from pathlib import Path
from pprint import pprint
import subprocess
import tempfile
import sys


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--buck2-dep",
        required=True,
        help="Path to the dep file.",
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
        "--abi-out",
        required=True,
        type=Path,
        help="Output path of the abi file to create.",
    )

    args, ghc_args = parser.parse_known_args()

    metadata_file = os.environ["ACTION_METADATA"]

    with open(metadata_file) as f:
        metadata = json.load(f)

        # check version
        version = metadata.get("version")
        if version != 1:
            sys.exit("version of metadata file not supported: {}".format(version))

        inputs = set(Path(entry["path"]) for entry in metadata["digests"])

    # get interface files that have a corresponding ABI hash file
    hi_files = set([abi.with_suffix("") for abi in args.abi])

    # all inputs are used *except* the hi files
    used_inputs = inputs - hi_files

    cmd = [args.ghc] + ghc_args

    subprocess.check_call(cmd)

    recompute_abi_hash(args.ghc, args.abi_out)

    # write the dep file
    try:
        with open(args.buck2_dep, "w") as f:
            f.write("\n".join(map(str, used_inputs)))

    except Exception as e:
        # remove incomplete dep file
        os.remove(args.buck2_dep)
        raise e


def recompute_abi_hash(ghc, abi_out):
    """Call ghc on the hi file and write the ABI hash to abi_out."""
    hi_file = abi_out.with_suffix("")

    cmd = [ghc, "--show-iface", hi_file]
    for line in subprocess.check_output(cmd, text=True).splitlines():
        if "ABI hash:" in line:
            hash = line.split(":", 1)[1]
            with open(abi_out, "w") as outfile:
                print(hash, file=outfile)
            return
    raise "ABI hash not found in ghc output"


if __name__ == "__main__":
    main()
