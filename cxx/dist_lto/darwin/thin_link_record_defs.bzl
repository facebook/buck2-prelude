# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

# These records are documented in the dist_lto_planner_darwin.py script and must be kept in sync with those definitions

BitcodeMergeState = enum(
    "STANDALONE",
    "ABSORBED",
    "ROOT",
    "NOT_LOADED",
)

ObjectFileOptimizationPlan = record(
    imports = field(list[int]),
    is_bitcode = field(bool),
    merge_state = field(str | None, None),  # BitcodeMergeState
    loaded_by_linker = field(bool),
)
