/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.jvm.java.abi.source;

import java.util.List;
import javax.lang.model.element.TypeParameterElement;

/**
 * Interface for {@link TypeParameterElement}s that are implemented by something other than javac
 * itself.
 */
interface ArtificialTypeParameterElement extends TypeParameterElement, ArtificialElement {
  @Override
  List<? extends ArtificialElement> getEnclosedElements();
}
