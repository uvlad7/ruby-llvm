# frozen_string_literal: true
# typed: strict

require 'rbconfig'

module LLVM
  LLVM_VERSION = "22"
  LLVM_REQUIRED_VERSION = "22.1.0"
  RUBY_LLVM_VERSION = "22.1.0"

  # Library names passed to ffi_lib, most-specific first. The versioned names pin the LLVM
  # major on ELF (libLLVM-<v>.so.*) and MinGW (libLLVM-<v>.dll). The unversioned "LLVM-C" is
  # appended only on MSVC (mswin), whose LLVM build ships LLVM-C.dll with no version in the
  # name — so it is never a silent fallback on platforms that have a versioned lib.
  FFI_LIBS = [
    "LLVM-#{LLVM_VERSION}",
    "libLLVM-#{LLVM_VERSION}",
    "libLLVM-#{LLVM_VERSION}.so.1",
    "libLLVM.so.#{LLVM_VERSION}",
    "libLLVM.so.#{LLVM_VERSION}.1",
    *(RbConfig::CONFIG["host_os"].match?(/mswin/i) ? ["LLVM-C"] : []),
  ].freeze #: Array[String]
end
