/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.util.concurrent;

public interface CommonThreadFactoryState extends ThreadIdToCommandIdMapper {

  CommonThreadFactoryState NOOP =
      new CommonThreadFactoryState() {

        @Override
        public String threadIdToCommandId(long threadId) {
          return "";
        }

        @Override
        public void register(long threadId, String commandId) {}
      };

  void register(long threadId, String commandId);
}
