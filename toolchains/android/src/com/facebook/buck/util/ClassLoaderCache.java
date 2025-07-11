/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.util;

import com.facebook.buck.core.util.log.Logger;
import com.google.common.annotations.VisibleForTesting;
import com.google.common.collect.ImmutableList;
import java.io.IOException;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import javax.annotation.Nullable;

/**
 * Maintain a cache mapping class paths to class loaders that load from these class paths. The class
 * loaders remain active until ClassLoaderCache itself is unloaded.
 */
public final class ClassLoaderCache implements AutoCloseable {
  private static final Logger LOG = Logger.get(ClassLoaderCache.class);

  private final Map<ClassLoader, Map<ImmutableList<URL>, ClassLoader>> cache = new HashMap<>();

  private int referenceCount = 1;
  private boolean skipCleanup = false;

  private synchronized Map<ImmutableList<URL>, ClassLoader> getCacheForParent(
      @Nullable ClassLoader parentClassLoader) {
    Map<ImmutableList<URL>, ClassLoader> cacheForParent = cache.get(parentClassLoader);

    if (cacheForParent == null) {
      cacheForParent = new HashMap<>();
      cache.put(parentClassLoader, cacheForParent);
    }

    return cacheForParent;
  }

  public synchronized ClassLoader getClassLoaderForClassPath(
      @Nullable ClassLoader parentClassLoader, ImmutableList<URL> classPath) {

    Map<ImmutableList<URL>, ClassLoader> cacheForParent = getCacheForParent(parentClassLoader);

    ClassLoader classLoader = cacheForParent.get(classPath);
    if (classLoader == null) {
      LOG.info(
          "Encountered cache miss for parent: %s and classpath:%s", parentClassLoader, classPath);
      URL[] urls = classPath.toArray(new URL[0]);
      classLoader = new CachedURLClassLoader(urls, parentClassLoader);
      cacheForParent.put(classPath, classLoader);
    }

    return classLoader;
  }

  @VisibleForTesting
  public synchronized void injectClassLoader(
      @Nullable ClassLoader parentClassLoader,
      ImmutableList<URL> classPath,
      ClassLoader injectedClassLoader) {
    Map<ImmutableList<URL>, ClassLoader> cacheForParent = getCacheForParent(parentClassLoader);

    cacheForParent.put(classPath, injectedClassLoader);
  }

  public synchronized ClassLoaderCache addRef() {
    referenceCount += 1;
    return this;
  }

  public synchronized void setSkipCleanup(boolean skipCleanup) {
    this.skipCleanup = skipCleanup;
  }

  @Override
  public synchronized void close() throws IOException {
    if (referenceCount > 1) {
      referenceCount -= 1;
      return;
    }
    // Since kotlin 2.1, the Kotlin analysis API standalone mode can outlive the compiler itself, as
    // per https://youtrack.jetbrains.com/issue/KT-73753/, we need skip unloading the caffeine
    // library otherwise analysis API would crash. s512268
    // The error only happens in non-persistent worker mode, as in persistent worker mode, buck
    // shutdown the workers and ignores any error afterwards.
    // Without persistent workers, we can safely skip cleaning all cloassloaders as they are removed
    // altogether when the process exits.
    // After Kotlin 2.2.0 upgrade, we can test if the new
    // disposeGlobalStandaloneApplicationServices() API could properly terminate the
    // analysis API.
    if (skipCleanup) {
      return;
    }

    Optional<IOException> caughtEx = Optional.empty();

    for (Map<ImmutableList<URL>, ClassLoader> cacheForParent : cache.values()) {
      for (ClassLoader cl : cacheForParent.values()) {
        try {
          if (cl instanceof CachedURLClassLoader) {
            ((CachedURLClassLoader) cl).reallyClose();
          }
        } catch (IOException ex) {
          if (caughtEx.isPresent()) {
            caughtEx.get().addSuppressed(ex);
          } else {
            caughtEx = Optional.of(ex);
          }
        }
      }
    }

    if (caughtEx.isPresent()) {
      throw caughtEx.get();
    }
  }

  private static class CachedURLClassLoader extends URLClassLoader {
    public CachedURLClassLoader(URL[] urls, @Nullable ClassLoader parent) {
      super(urls, parent);
    }

    @Override
    public void close() {
      // Do nothing; only the cache can close this ClassLoader
    }

    private void reallyClose() throws IOException {
      super.close();
    }
  }
}
