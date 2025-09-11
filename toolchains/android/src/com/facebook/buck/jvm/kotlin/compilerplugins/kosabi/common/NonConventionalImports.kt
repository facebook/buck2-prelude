/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.kotlin.compilerplugins.kosabi.common

object NonConventionalImports {
  /** [interfaces] is exclude list from Constant Value Naming convention in kosabi. */
  val interfaces: Set<List<String>> =
      setOf(
          listOf("javax", "microedition", "khronos", "egl", "EGL"),
          listOf("javax", "microedition", "khronos", "egl", "EGL10"),
          listOf("javax", "microedition", "khronos", "egl", "EGL11"),
          listOf("javax", "microedition", "khronos", "opengles", "GL"),
          listOf("javax", "microedition", "khronos", "opengles", "GL10"),
          listOf("javax", "microedition", "khronos", "opengles", "GL11"),
      )
}
