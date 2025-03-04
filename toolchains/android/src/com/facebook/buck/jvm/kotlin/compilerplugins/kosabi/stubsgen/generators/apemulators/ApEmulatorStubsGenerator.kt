/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under both the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree and the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree.
 */

package com.facebook.kotlin.compilerplugins.kosabi.stubsgen.generators.apemulators

import com.facebook.kotlin.compilerplugins.kosabi.stubsgen.generators.GenerationContext
import com.facebook.kotlin.compilerplugins.kosabi.stubsgen.generators.StubsGenerator

/**
 * [ApEmulatorStubsGenerator] emulates AP behaviour. It generates [KStub]s that pretend to be
 * original sources generated by AP.
 */
class ApEmulatorStubsGenerator : StubsGenerator {
  private val customStubsGenerators =
      listOf(
          IgParserStubsGenerator(),
      )

  override fun generateStubs(context: GenerationContext) {
    customStubsGenerators.forEach { it.generateStubs(context) }
  }
}
