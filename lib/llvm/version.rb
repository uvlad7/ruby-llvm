# frozen_string_literal: true
# typed: strict

require 'rbconfig'

module LLVM
  LLVM_VERSION = "22"
  LLVM_REQUIRED_VERSION = "22.1"
  RUBY_LLVM_VERSION = "22.1.0"

  # Candidate names for the shared library, tried in order by ffi_lib until one
  # loads. Each entry targets a different platform/packaging scheme, so the
  # ones that miss on any given system are expected, not dead weight:
  #
  #   LLVM-22           undecorated; FFI.map_library_name adds the platform
  #                     form -- libLLVM-22.dylib on macOS, libLLVM-22.so on
  #                     Linux. The only entry that can match on macOS, since
  #                     the others are literal .so names. Moved to the front in
  #                     ec556af (LLVM 19), alongside homebrew CI support.
  #   libLLVM-22        MinGW's libLLVM-22.dll and Cygwin's cygLLVM-22.dll;
  #                     FFI.map_library_name maps the bare name to the DLL
  #                     form. Never matches on Linux/macOS.
  #   libLLVM.so.22     openSUSE layout. Added in 9246958 (LLVM 10) --
  #                     "Support libLLVM.so.<version> as used in openSUSE".
  #   libLLVM.so.22.1   Debian/Ubuntu layout since LLVM 19, and the real file on
  #                     current systems; added in ec556af to work around the
  #                     LLVM 19 packaging change.
  #   libLLVM-22.so.1   ELF soname some distributions ship for the versioned lib.
  #   LLVM-C            the MSVC build ships the C API as LLVM-C.dll, with no version in the
  #                     name. Appended only on mswin: everywhere else a versioned lib exists,
  #                     and an unversioned entry would be a silent fallback to whatever LLVM
  #                     happens to be installed. LLVM.assert_llvm_version! covers the mswin case.
  LIB_NAMES = [
    "LLVM-#{LLVM_VERSION}",
    "libLLVM-#{LLVM_VERSION}",
    "libLLVM-#{LLVM_VERSION}.so.1",
    "libLLVM.so.#{LLVM_VERSION}",
    "libLLVM.so.#{LLVM_REQUIRED_VERSION}",
    *(RbConfig::CONFIG["host_os"].match?(/mswin/i) ? ["LLVM-C"] : []),
  ].freeze #: Array[String]
end
