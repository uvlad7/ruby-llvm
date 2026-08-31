# frozen_string_literal: true
# typed: strict

require 'llvm'
require 'llvm/core_ffi'
require 'llvm/core_ffi_v2'
require 'llvm/support'

module LLVM
  module C
    attach_function :get_version, :LLVMGetVersion, [:pointer, :pointer, :pointer], :void
  end

  # Verify the loaded LLVM matches the major.minor ruby-llvm targets (patch is ignored). ELF and
  # MinGW pin the version through the versioned library name, but on MSVC (mswin) ffi_lib loads
  # the unversioned LLVM-C.dll, which could be any version -- so fail fast on a mismatch.
  #: -> void
  def self.assert_llvm_version!
    maj = FFI::MemoryPointer.new(:uint)
    min = FFI::MemoryPointer.new(:uint)
    pat = FFI::MemoryPointer.new(:uint)
    C.get_version(maj, min, pat)
    required = LLVM_REQUIRED_VERSION.split('.').first(2).join('.')
    return if "#{maj.read_uint}.#{min.read_uint}" == required

    raise "ruby-llvm #{RUBY_LLVM_VERSION} requires LLVM #{required}.x, " \
          "but loaded LLVM #{maj.read_uint}.#{min.read_uint}.#{pat.read_uint}"
  end
  assert_llvm_version!
  assert_support_shares_llvm!
  # Yields a pointer suitable for storing an LLVM output message.
  # If the message pointer is non-NULL (an error has happened), converts
  # the result to a string and returns it. Otherwise, returns +nil+.
  #
  # @yield  [FFI::MemoryPointer]
  # @return [String, nil]
  #: { (FFI::MemoryPointer) -> Integer } -> String?
  def self.with_message_output(&)
    message = nil #: String?

    FFI::MemoryPointer.new(FFI.type_size(:pointer)) do |str|
      result = yield str

      msg_ptr = str.read_pointer

      if result != 0
        raise "Error is signalled, but msg_ptr is null" if msg_ptr.null?

        message = msg_ptr.read_string
        C.dispose_message msg_ptr
      end
    end

    message
  end

  # Same as #with_message_output, but raises a RuntimeError with the
  # resulting message.
  #
  # @yield  [FFI::MemoryPointer]
  # @return [nil]
  #: { (FFI::MemoryPointer) -> Integer } -> String?
  def self.with_error_output(&blk)
    error = with_message_output(&blk)

    raise error unless error.nil?
  end

  require 'llvm/core/context'
  require 'llvm/core/module'
  require 'llvm/core/type'
  require 'llvm/core/value'
  require 'llvm/core/builder'
  require 'llvm/core/pass_manager'
  require 'llvm/pass_builder'
  require 'llvm/core/bitcode'
  require 'llvm/core/attribute'
end
