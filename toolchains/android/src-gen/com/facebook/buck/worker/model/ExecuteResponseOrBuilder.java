// @generated
// Generated by the protocol buffer compiler.  DO NOT EDIT!
// source: worker.proto

package com.facebook.buck.worker.model;

@javax.annotation.Generated(value="protoc", comments="annotations:ExecuteResponseOrBuilder.java.pb.meta")
public interface ExecuteResponseOrBuilder extends
    // @@protoc_insertion_point(interface_extends:worker.ExecuteResponse)
    com.google.protobuf.MessageOrBuilder {

  /**
   * <code>int32 exit_code = 1;</code>
   */
  int getExitCode();

  /**
   * <code>string stderr = 2;</code>
   */
  java.lang.String getStderr();
  /**
   * <code>string stderr = 2;</code>
   */
  com.google.protobuf.ByteString
      getStderrBytes();

  /**
   * <code>uint64 timed_out_after_s = 3;</code>
   */
  long getTimedOutAfterS();
}
