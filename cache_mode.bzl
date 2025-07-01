# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

CacheModeInfo = provider(fields = {"allow_cache_uploads": provider_field(typing.Any, default = None), "cache_bust_genrules": provider_field(typing.Any, default = None)})
