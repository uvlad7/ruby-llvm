# frozen_string_literal: true
# typed: strict

require 'ffi'

module LLVM
  require 'llvm/version'

  # On Windows (RubyInstaller2), register the LLVM lib directory in the DLL
  # search path so that FFI can find libLLVM-*.dll at runtime.
  # See https://github.com/oneclick/rubyinstaller2/wiki/For-gem-developers#dll-loading
  if Gem.win_platform?
    begin
      require 'ruby_installer/runtime'
      RubyInstaller::Runtime.add_dll_directory(LLVM::CONFIG::LIBDIR)
    rescue LoadError
      # Not running under RubyInstaller — rely on PATH or standard DLL resolution.
    end
  end

  require 'llvm/support'

  class DeprecationError < StandardError; end

  module PointerIdentity
    attr_reader :ptr #: as FFI::Pointer

    # @private
    #: -> FFI::Pointer
    def to_ptr
      ptr #: FFI::Pointer
    end

    # Checks if the value is equal to other.
    #: (untyped) -> bool
    def ==(other)
      other.respond_to?(:to_ptr) &&
          ptr == other.to_ptr
    end

    # Computes hash.
    #: -> Integer
    def hash
      ptr.address.hash
    end

    # Checks if the value is equivalent to other.
    #: (untyped) -> bool
    def eql?(other)
      self == other
    end
  end
end
