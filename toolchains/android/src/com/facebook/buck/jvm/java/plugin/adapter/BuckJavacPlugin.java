/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.jvm.java.plugin.adapter;

/**
 * Analogue to javac 8's {@link com.sun.source.util.Plugin} class for use within Buck, even on older
 * versions of javac.
 */
public interface BuckJavacPlugin {
  String getName();

  void init(BuckJavacTask task, String... args);
}
