# frozen_string_literal: true
# typed: true

require 'ffi'
require 'llvm/version'

module LLVM
  # Loads libLLVM exactly once; every other FFI::Library binding reuses this single dlopen handle
  # via LLVM.inject_llvm_libs instead of calling ffi_lib itself.
  #
  # Why one handle rather than one ffi_lib call per binding: ffi_lib resolves the candidate names
  # afresh each time, so two bindings can end up on two different files -- most easily when the
  # installed LLVM is upgraded or relinked while the process is running, and the name that
  # resolved for the first binding now points at a different image. Two images mean two LLVM
  # instances with separate target, asm and pass registries, so a target initialized through one
  # is invisible to the other and the failure surfaces far from its cause. Loading once and
  # sharing the handle makes that impossible by construction.
  #
  # No RTLD_GLOBAL: reusing the handle is a Ruby-level concern, and the JIT resolves external
  # symbols through its own process generator, so libLLVM need not be global at the C level.
  module LibLLVM
    extend FFI::Library
    ffi_lib LLVM::LIB_NAMES
  end

  # Reuse the single libLLVM dlopen in another FFI::Library module. ffi_lib has stored its loaded
  # libraries in @ffi_libs (read via #ffi_libraries) since at least ffi 1.13, so setting the same
  # array makes that module's attach_function resolve against the already-open handle.
  #: (untyped) -> void
  def self.inject_llvm_libs(mod)
    mod.instance_variable_set(:@ffi_libs, LibLLVM.ffi_libraries)
  end

  # Verify the ruby-llvm-support extension and the ffi-loaded libLLVM are one image. Support hands
  # back the real address of LLVMGetVersion as it links it (dllimport on MSVC, so the IAT target
  # in LLVM-C.dll rather than a local thunk); LibLLVM resolves the same symbol through its own
  # handle. A mismatch means two libLLVM copies are loaded and their target/asm registries split
  # -- including the case where support is statically linked against a different libLLVM than ffi
  # loaded, which comparing the actual bindings catches directly.
  #: -> void
  def self.assert_support_shares_llvm!
    require 'llvm/support'
    support_addr = LLVM::Support::C.get_version_addr
    ffi_addr = LibLLVM.ffi_libraries.first.find_symbol('LLVMGetVersion')
    return if ffi_addr && !support_addr.null? && support_addr.address == ffi_addr.address

    raise "ruby-llvm-support and the ffi-loaded libLLVM resolve LLVMGetVersion to different " \
          "addresses (support=#{support_addr}, ffi=#{ffi_addr}) -- two libLLVM images are loaded, " \
          "so target and asm registries are split."
  end
end
