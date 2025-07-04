/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.jvm.kotlin.cd.workertool;

import com.facebook.buck.core.util.log.Logger;
import com.facebook.buck.jvm.cd.CompilerDaemonLoggerUtil;
import com.facebook.buck.jvm.cd.CompilerDaemonRunner;
import com.google.common.collect.ImmutableMap;
import java.io.IOException;
import java.util.logging.Level;

/**
 * KotlinCD main class.
 *
 * <p>This provides a simple executable that can run any of the kotlincd actions.
 */
public class KotlinCDMain {
  private static final String LOG_PATH = "buck-out/v2/kotlincd";

  /** Main entrypoint of KotlinCD worker tool. */
  public static void main(String[] args) throws IOException {
    try {
      CompilerDaemonLoggerUtil.setDefaultLogger("kotlincd_worker", LOG_PATH);
      CompilerDaemonLoggerUtil.setConsoleHandlerLogLevelTo(Level.WARNING);
      KotlinCDCommand command = new KotlinCDCommand(args, ImmutableMap.copyOf(System.getenv()));
      Logger logger = Logger.get(KotlinCDMain.class.getName());
      logger.info(String.format("Starting KotlinCDWorkerTool %s", command));
      System.setErr(new KotlinStdErrInterceptor());
      CompilerDaemonRunner.run(command);
      command.postExecute();
      System.err.println("KotlinCDWorkerTool succeeded!");
      System.exit(0);
    } catch (Exception e) {
      System.err.println("KotlinCDWorkerTool failed: " + e.getMessage());
      e.printStackTrace(System.err);
    }
    System.exit(2);
  }
}
