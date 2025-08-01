# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo")

def _system_haskell_toolchain(_ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = "ghc",
            packager = "ghc-pkg",
            linker = "ghc",
            haddock = "haddock",
            compiler_flags = [],
            linker_flags = [],
        ),
        HaskellPlatformInfo(
            name = host_info().arch,
        ),
    ]

system_haskell_toolchain = rule(
    impl = _system_haskell_toolchain,
    attrs = {},
    is_toolchain_rule = True,
)
