/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package com.facebook.buck.android.manifest;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

/** Tests for {@link ReplaceApplicationIdPlaceholdersExecutableMain}. */
public class ReplaceApplicationIdPlaceholdersExecutableMainTest {

  @Rule public TemporaryFolder tempFolder = new TemporaryFolder();

  private static class SystemExitException extends SecurityException {
    private final int exitCode;

    SystemExitException(int exitCode) {
      super("System.exit(" + exitCode + ") intercepted");
      this.exitCode = exitCode;
    }

    int getExitCode() {
      return exitCode;
    }
  }

  @SuppressWarnings("deprecation")
  private static class NoExitSecurityManager extends SecurityManager {
    @Override
    public void checkExit(int status) {
      throw new SystemExitException(status);
    }

    @Override
    public void checkPermission(java.security.Permission perm) {
      // Allow everything else
    }
  }

  @SuppressWarnings("deprecation")
  private int callMain(String... args) {
    SecurityManager originalSecurityManager = System.getSecurityManager();
    System.setSecurityManager(new NoExitSecurityManager());
    try {
      ReplaceApplicationIdPlaceholdersExecutableMain.main(args);
      return -1;
    } catch (SystemExitException e) {
      return e.getExitCode();
    } catch (Exception e) {
      throw new RuntimeException("Unexpected exception from main", e);
    } finally {
      System.setSecurityManager(originalSecurityManager);
    }
  }

  @Test
  public void shouldReplaceApplicationIdPlaceholderInManifest() throws Exception {
    String manifestContent =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission android:name=\"${applicationId}.permission.C2D_MESSAGE\" />\n"
            + "</manifest>";

    Path manifestFile = tempFolder.newFile("AndroidManifest.xml").toPath();
    Files.writeString(manifestFile, manifestContent);

    Path outputFile = tempFolder.getRoot().toPath().resolve("output.xml");

    int exitCode =
        callMain(
            "--manifest", manifestFile.toString(),
            "--output", outputFile.toString());

    assertEquals(0, exitCode);
    String result = Files.readString(outputFile);
    String expected =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission android:name=\"com.example.app.permission.C2D_MESSAGE\" />\n"
            + "</manifest>";
    assertEquals(expected, result);
  }

  @Test
  public void shouldReplaceMultipleApplicationIdPlaceholders() throws Exception {
    String manifestContent =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission android:name=\"${applicationId}.permission.C2D_MESSAGE\" />\n"
            + "   <provider android:authorities=\"${applicationId}.provider\" />\n"
            + "</manifest>";

    Path manifestFile = tempFolder.newFile("AndroidManifest.xml").toPath();
    Files.writeString(manifestFile, manifestContent);

    Path outputFile = tempFolder.getRoot().toPath().resolve("output.xml");

    int exitCode =
        callMain(
            "--manifest", manifestFile.toString(),
            "--output", outputFile.toString());

    assertEquals(0, exitCode);
    String result = Files.readString(outputFile);
    assertTrue(result.contains("com.example.app.permission.C2D_MESSAGE"));
    assertTrue(result.contains("com.example.app.provider"));
  }

  @Test
  public void shouldWriteManifestWithNoPlaceholdersUnchanged() throws Exception {
    String manifestContent =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission android:name=\"com.example.app.permission.C2D_MESSAGE\" />\n"
            + "</manifest>";

    Path manifestFile = tempFolder.newFile("AndroidManifest.xml").toPath();
    Files.writeString(manifestFile, manifestContent);

    Path outputFile = tempFolder.getRoot().toPath().resolve("output.xml");

    int exitCode =
        callMain(
            "--manifest", manifestFile.toString(),
            "--output", outputFile.toString());

    assertEquals(0, exitCode);
    String result = Files.readString(outputFile);
    assertEquals(manifestContent, result);
  }

  @Test
  public void shouldPassSanityCheckWhenAllPlaceholdersAreReplaced() throws Exception {
    String manifestContent =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission android:name=\"${applicationId}.permission.C2D_MESSAGE\" />\n"
            + "</manifest>";

    Path manifestFile = tempFolder.newFile("AndroidManifest.xml").toPath();
    Files.writeString(manifestFile, manifestContent);

    Path outputFile = tempFolder.getRoot().toPath().resolve("output.xml");

    int exitCode =
        callMain(
            "--manifest",
            manifestFile.toString(),
            "--output",
            outputFile.toString(),
            "--sanity-check-placeholders");

    assertEquals(0, exitCode);
    String result = Files.readString(outputFile);
    assertEquals(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission android:name=\"com.example.app.permission.C2D_MESSAGE\" />\n"
            + "</manifest>",
        result);
  }

  @Test
  public void shouldExitWithErrorWhenRequiredArgsAreMissing() {
    int exitCode = callMain();

    assertEquals(1, exitCode);
  }

  @Test
  public void shouldNotThrowWhenSanityCheckDisabledAndUnreplacedPlaceholdersExist()
      throws Exception {
    String manifestContent =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "   <permission\n"
            + "       android:name=\"${applicationId}.permission.C2D_MESSAGE\"\n"
            + "       android:protectionLevel=\"${unreplacedPlaceholder}\" />\n"
            + "</manifest>";

    Path manifestFile = tempFolder.newFile("AndroidManifest.xml").toPath();
    Files.writeString(manifestFile, manifestContent);

    Path outputFile = tempFolder.getRoot().toPath().resolve("output.xml");

    int exitCode =
        callMain(
            "--manifest", manifestFile.toString(),
            "--output", outputFile.toString());

    assertEquals(0, exitCode);
    String result = Files.readString(outputFile);
    assertTrue(result.contains("com.example.app.permission.C2D_MESSAGE"));
    assertTrue(result.contains("${unreplacedPlaceholder}"));
  }

  @Test
  public void shouldCreateOutputFileAtSpecifiedPath() throws Exception {
    String manifestContent =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<manifest\n"
            + "   xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
            + "   package=\"com.example.app\">\n"
            + "</manifest>";

    Path manifestFile = tempFolder.newFile("AndroidManifest.xml").toPath();
    Files.writeString(manifestFile, manifestContent);

    Path outputFile = tempFolder.getRoot().toPath().resolve("subdir").resolve("output.xml");
    Files.createDirectories(outputFile.getParent());

    int exitCode =
        callMain(
            "--manifest", manifestFile.toString(),
            "--output", outputFile.toString());

    assertEquals(0, exitCode);
    assertTrue(Files.exists(outputFile));
    String result = Files.readString(outputFile);
    assertEquals(manifestContent, result);
  }
}
