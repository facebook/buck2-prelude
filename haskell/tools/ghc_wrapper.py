#!/usr/bin/env python3

"""Wrapper script to call ghc.

It accepts a dep file where all used inputs are written to. For any passed ABI
hash file, the corresponding interface is marked as unused, so these can change
without triggering compilation actions.

"""

import argparse
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
        "--worker-id", required=False, type=str, help="worker id",
    )
    parser.add_argument(
        "--worker-close", required=False, type=bool, default=False, help="worker close",
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
    parser.add_argument(
        "--bin-exe",
        type=Path,
        action="append",
        default=[],
        help="Add given exe (more specific than bin-path)",
    )
    parser.add_argument(
        "--extra-env-key",
        type=str,
        action="append",
        default=[],
        help="Extra environment variable name",
    )
    parser.add_argument(
        "--extra-env-value",
        type=str,
        action="append",
        default=[],
        help="Extra environment variable value",
    )

    args, ghc_args = parser.parse_known_args()
    if args.worker_id:
        worker_args = ["--worker-id={}".format(args.worker_id)] + (["--worker-close"] if args.worker_close else [])
    else:
        worker_args = []
    cmd = [args.ghc] + worker_args + ghc_args

    aux_paths = [str(binpath) for binpath in args.bin_path if binpath.is_dir()] + [str(os.path.dirname(binexepath)) for binexepath in args.bin_exe]
    env = os.environ.copy()
    path = env.get("PATH", "")
    env["PATH"] = os.pathsep.join([path] + aux_paths)

    extra_env_keys = [str(k) for k in args.extra_env_key]
    extra_env_values = [str(v) for v in args.extra_env_value]
    assert len(extra_env_keys) == len(extra_env_values), "number of --extra-env-key and --extra-env-value flags must match"
    n_extra_env = len(extra_env_keys)
    if n_extra_env > 0:
        for i in range(0, n_extra_env):
            k = extra_env_keys[i]
            v = extra_env_values[i]
            env[k] = v

    # Note, Buck2 swallows stdout on successful builds.
    # Redirect to stderr to avoid this.
    returncode = subprocess.call(cmd, env=env, stdout=sys.stderr.buffer)
    if returncode != 0:
        return returncode

    recompute_abi_hash(args.ghc, args.abi_out, args.worker_id)

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

    return 0


def recompute_abi_hash(ghc, abi_out, worker_id):
    """Call ghc on the hi file and write the ABI hash to abi_out."""
    hi_file = abi_out.with_suffix("")
    if worker_id:
        worker_args = ["--worker-id={}".format(worker_id)]
    else:
        worker_args = []

    cmd = [ghc, "-v0", "-package-env=-", "--show-iface-abi-hash", hi_file] + worker_args

    hash = subprocess.check_output(cmd, text=True).split(maxsplit=1)[0]

    abi_out.write_text(hash)


if __name__ == "__main__":
    main()
