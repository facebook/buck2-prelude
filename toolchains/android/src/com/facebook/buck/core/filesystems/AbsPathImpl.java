/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.core.filesystems;

import java.nio.file.Path;

/** Implementation of {@link com.facebook.buck.core.filesystems.AbsPath} */
class AbsPathImpl extends PathWrapperImpl implements AbsPath {
  public AbsPathImpl(Path path) {
    super(path);
    if (!path.isAbsolute()) {
      throw new IllegalArgumentException("path must be absolute: " + path);
    }
  }
}
