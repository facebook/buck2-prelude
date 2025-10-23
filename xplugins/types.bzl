# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@prelude//:artifact_tset.bzl", "ArtifactTSet")

XPluginsSocketUsageInfo = provider(fields = {
    "target": provider_field(Label),
    "usage_info": provider_field(Artifact),
})

XPluginsPluginUsageInfo = provider(fields = {
    "target": provider_field(Label),
    "usage_info": provider_field(Artifact),
})

XPluginsUsageInfo = provider(fields = {
    "socket_info_tset": provider_field(ArtifactTSet),
})
