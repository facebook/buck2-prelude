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
import subprocess
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
        "--buck2-packagedb-dep",
        required=True,
        help="Path to the dep file.",
    )
    parser.add_argument(
        "--buck2-package-db",
        required=False,
        nargs="*",
        default=[],
        help="Path to a package db that is used during the module compilation",
    )
    parser.add_argument(
        "--ghc", required=True, type=str, help="Path to the Haskell compiler GHC."
    )
    parser.add_argument(
        "--abi-out",
        required=True,
        type=Path,
        help="Output path of the abi file to create.",
    )
    parser.add_argument(
        "--bin-path",
        type=Path,
        action="append",
        default=[],
        help="Add given path to PATH.",
    )

    args, ghc_args = parser.parse_known_args()

    cmd = [args.ghc] + ghc_args

    aux_paths = [str(binpath) for binpath in args.bin_path if binpath.is_dir()]
    env = os.environ.copy()
    path = env.get("PATH", "")
    env["PATH"] = os.pathsep.join([path] + aux_paths)

    subprocess.check_call(cmd, env=env)

    recompute_abi_hash(args.ghc, args.abi_out)

    # write an empty dep file, to signal that all tagged files are unused
    try:
        with open(args.buck2_dep, "w") as f:
            f.write("\n")

    except Exception as e:
        # remove incomplete dep file
        os.remove(args.buck2_dep)
        raise e

    # write an empty dep file, to signal that all tagged files are unused
    try:
        with open(args.buck2_packagedb_dep, "w") as f:
            for db in args.buck2_package_db:
                f.write(db + "\n")
            if not args.buck2_package_db:
                f.write("\n")

    except Exception as e:
        # remove incomplete dep file
        os.remove(args.buck2_packagedb_dep)
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
