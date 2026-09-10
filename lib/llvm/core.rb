# frozen_string_literal: true
# typed: strict

require 'llvm'
require 'llvm/core_ffi'
require 'llvm/core_ffi_v2'
require 'llvm/support'

module LLVM
  module C
    attach_function :get_version, :LLVMGetVersion, [:pointer, :pointer, :pointer], :void
    # LLVM_DEFAULT_TARGET_TRIPLE, baked in when libLLVM itself was built -- so it names the
    # toolchain that produced the library now loaded, not the machine running it.
    attach_function :get_default_triple, :LLVMGetDefaultTargetTriple, [], LLVM::OwnedString
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

  # Windows has two incompatible toolchains, and a build of LLVM belongs to exactly one of them:
  # MSVC (mswin Ruby, LLVM-C.dll, windows-msvc triple) and MinGW/MSYS2 (mingw Ruby,
  # libLLVM-<v>.dll, windows-gnu triple). They disagree on the C++ ABI, the C runtime, and how
  # structs are returned, so pairing a Ruby from one with a libLLVM from the other miscompiles
  # rather than failing to load: calls appear to work and return corrupt values, or crash far
  # from the cause.
  #
  # Refuse the pairing instead. The triple comes from the loaded library rather than from the
  # generated config.rb, so this still holds when ffi resolved a different libLLVM than the
  # support extension was built against.
  # The Windows toolchain a Ruby platform string or an LLVM triple belongs to, or nil for
  # anything outside the Windows family. Cygwin counts as its own: it is neither MSVC nor MinGW,
  # being built against cygwin1.dll, and pairs only with a Cygwin-built LLVM.
  #
  # Order matters. The Cygwin triple is windows-cygnus, and 'cygnus' contains 'gnu', so a looser
  # MinGW test would claim it -- matching on the full 'windows-gnu' and taking Cygwin first
  # keeps them apart.
  #: (String) -> Symbol?
  def self.windows_toolchain(name)
    return :cygwin if name.match?(/cygwin|cygnus/)
    return :msvc   if name.match?(/mswin|windows-msvc/)
    return :mingw  if name.match?(/mingw|windows-gnu/)

    nil
  end

  # Whether a Ruby platform and an LLVM build triple name different Windows toolchains. nil when
  # the question does not arise, i.e. either side is not a Windows platform at all.
  #: (String, String) -> bool?
  def self.windows_toolchain_mismatch?(ruby_platform, triple)
    ruby_chain = windows_toolchain(ruby_platform)
    llvm_chain = windows_toolchain(triple)
    return nil if ruby_chain.nil? || llvm_chain.nil?

    ruby_chain != llvm_chain
  end

  TOOLCHAIN_NAMES = {
    msvc: 'MSVC (mswin)',
    mingw: 'MinGW/MSYS2',
    cygwin: 'Cygwin',
  }.freeze #: Hash[Symbol, String]

  #: -> void
  def self.assert_llvm_toolchain_matches!
    triple = C.get_default_triple.to_s
    return unless windows_toolchain_mismatch?(RUBY_PLATFORM, triple)

    # both are non-nil: a mismatch is only reported when each side classified
    ruby_kind = windows_toolchain(RUBY_PLATFORM) #: as !nil
    llvm_kind = windows_toolchain(triple) #: as !nil
    ruby_chain = TOOLCHAIN_NAMES.fetch(ruby_kind)
    llvm_chain = TOOLCHAIN_NAMES.fetch(llvm_kind)
    raise "ruby-llvm cannot mix Windows toolchains: this Ruby is #{ruby_chain} but the loaded " \
          "LLVM was built for #{llvm_chain} (#{triple}). They differ in C++ ABI and C runtime, " \
          "so the pairing miscompiles rather than failing cleanly. Use an LLVM built for " \
          "#{ruby_chain}."
  end

  assert_llvm_version!
  assert_llvm_toolchain_matches!
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
