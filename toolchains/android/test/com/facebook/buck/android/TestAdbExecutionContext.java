/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.android;

import com.facebook.buck.util.Console;
import com.google.common.collect.ImmutableMap;

public class TestAdbExecutionContext extends AdbExecutionContext {

  private final ImmutableMap<String, String> extraEnvironment;

  public TestAdbExecutionContext(Console console) {
    this(console, ImmutableMap.of());
  }

  public TestAdbExecutionContext(Console console, ImmutableMap<String, String> environment) {
    super(console);
    extraEnvironment = environment;
  }

  @Override
  public ImmutableMap<String, String> getEnvironment() {
    return ImmutableMap.<String, String>builder()
        .putAll(super.getEnvironment())
        .putAll(extraEnvironment)
        .build();
  }
}
