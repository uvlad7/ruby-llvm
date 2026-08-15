# frozen_string_literal: true
# typed: true

require 'ffi'
require 'llvm/version'

module LLVM
  # Loads libLLVM exactly once; every other FFI::Library binding reuses this single dlopen
  # handle via LLVM.inject_llvm_libs instead of calling ffi_lib itself. One handle across all
  # bindings means one LLVM instance (one target/symbol registry) — no split-instance surprises.
  #
  # No RTLD_GLOBAL: reusing the handle is a Ruby-level concern, and the JIT resolves external
  # symbols through its own process generator, so libLLVM need not be global at the C level.
  module LibLLVM
    extend FFI::Library
    ffi_lib LLVM::FFI_LIBS
  end

  # Reuse the single libLLVM dlopen in another FFI::Library module. ffi_lib has stored its loaded
  # libraries in @ffi_libs (read via #ffi_libraries) since at least ffi 1.13, so setting the same
  # array makes that module's attach_function resolve against the already-open handle.
  #: (untyped) -> void
  def self.inject_llvm_libs(mod)
    mod.instance_variable_set(:@ffi_libs, LibLLVM.ffi_libraries)
  end

  # Platform bindings for walking the process's loaded-module list. Guarded per-platform so
  # attach_function only runs for symbols that exist here.
  if FFI::Platform.windows?
    module Loader
      extend FFI::Library
      ffi_lib 'kernel32'
      attach_function :current_process, :GetCurrentProcess, [], :pointer
      attach_function :enum_modules, :K32EnumProcessModules, [:pointer, :pointer, :uint32, :pointer], :bool
      attach_function :module_filename, :K32GetModuleFileNameExW, [:pointer, :pointer, :pointer, :uint32], :uint32
    end
  elsif FFI::Platform.mac?
    module Loader
      extend FFI::Library
      ffi_lib FFI::Library::LIBC
      attach_function :image_count, :_dyld_image_count, [], :uint32
      attach_function :image_name, :_dyld_get_image_name, [:uint32], :string
    end
  else
    module Loader
      extend FFI::Library
      ffi_lib FFI::Library::LIBC
      callback :phdr_cb, [:pointer, :size_t, :pointer], :int
      attach_function :dl_iterate_phdr, [:phdr_cb, :pointer], :int
    end
  end

  # Debug probe. Enumerate every shared object mapped into this process and return the distinct
  # paths that look like a libLLVM / LLVM-C image. More than one means two copies are resident,
  # and each gets its own copy of LLVM's process-global registries (targets, asm parsers) — the
  # "no targets are registered" / silently-wrong-JIT class of bug.
  #
  # Only sees separately *loaded* modules, so a libLLVM statically linked into another module
  # (e.g. inside RubyLLVMSupport on mswin) never appears — this can't false-positive on that
  # topology, and equally can't catch a static-vs-shared registry split (the inline-asm JIT test
  # covers that). Walks the whole module list; call it by hand when diagnosing, not on load.
  #: -> Array[String]
  def self.loaded_llvm_libraries
    loaded_shared_objects.select { |path| File.basename(path) =~ /(?:lib)?LLVM[-.]/i }.uniq
  end

  # Raise if more than one distinct libLLVM image is mapped.
  #: -> void
  def self.assert_single_llvm!
    libs = loaded_llvm_libraries
    return if libs.size <= 1

    raise "Multiple libLLVM images mapped (split registry likely):\n  #{libs.join("\n  ")}"
  end

  #: -> Array[String]
  def self.loaded_shared_objects
    if FFI::Platform.windows?
      windows_loaded_modules
    elsif FFI::Platform.mac?
      Array.new(Loader.image_count) { |i| Loader.image_name(i) }.compact
    else
      names = [] #: Array[String]
      Loader.dl_iterate_phdr(lambda do |info, _size, _data|
        name_ptr = info.get_pointer(FFI.type_size(:pointer)) # skip dlpi_addr, read dlpi_name
        unless name_ptr.null?
          name = name_ptr.read_string
          names << name unless name.empty?
        end
        0
      end, nil)
      names
    end
  end

  #: -> Array[String]
  def self.windows_loaded_modules
    proc_handle = Loader.current_process
    slots = 1024
    handles = FFI::MemoryPointer.new(:pointer, slots)
    needed = FFI::MemoryPointer.new(:uint32)
    return [] unless Loader.enum_modules(proc_handle, handles, handles.size, needed)

    count = [needed.read_uint32 / FFI.type_size(:pointer), slots].min
    name_buf = FFI::MemoryPointer.new(:uint16, 32_768)
    Array.new(count) do |i|
      hmod = handles.get_pointer(i * FFI.type_size(:pointer))
      len = Loader.module_filename(proc_handle, hmod, name_buf, 32_768)
      next if len.zero?

      name_buf.read_bytes(len * 2).force_encoding('UTF-16LE').encode('UTF-8')
    end.compact
  end
end
