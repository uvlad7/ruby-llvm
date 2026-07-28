# frozen_string_literal: true
# typed: true

require 'llvm/core'
require 'llvm/execution_engine'

module LLVM
  # Wrapper around LLVMOrcLLJITRef (ORC JIT v2). Unlike MCJIT/RuntimeDyld, ORC uses
  # JITLink on supported targets (x86-64, AArch64, RISCV) and works where MCJIT is
  # broken (e.g. RuntimeDyld mis-relocates globals on riscv64).
  class LLJit
    # Create an LLJIT and wire its main dylib to resolve symbols from the current process
    # (so JIT'd code can call puts/getenv/etc without manual registration).
    def initialize
      FFI::MemoryPointer.new(FFI.type_size(:pointer)) do |out|
        raise_if_error(C.create_lljit(out, C.create_lljit_builder))
        @ptr = out.read_pointer
      end

      # global_prefix is '\0' on ELF, '_' on Mach-O / i386 COFF; a null filter accepts all.
      FFI::MemoryPointer.new(FFI.type_size(:pointer)) do |gen_out|
        err = C.create_process_generator(gen_out, C.get_global_prefix(@ptr), nil, nil)
        unless err.null?
          dispose
          raise_if_error(err)
        end
        C.dylib_add_generator(C.get_main_jit_dylib(@ptr), gen_out.read_pointer)
      end
    end

    # Add an LLVM::Module for JIT compilation. A clone is handed to ORC (which consumes the
    # module), so the caller's `mod` stays valid for type/function queries afterward.
    def add_module(mod)
      ts_ctx = C.create_thread_safe_context
      ts_mod = C.create_thread_safe_module(mod.clone_module, ts_ctx)
      C.dispose_thread_safe_context(ts_ctx)
      # add_ir_module transfers ownership of ts_mod unconditionally (per LLJIT.h): do not
      # dispose or reference ts_mod after this call, even on error.
      err = C.add_ir_module(@ptr, C.get_main_jit_dylib(@ptr), ts_mod)
      raise_if_error(err)
    end

    # Look up a compiled symbol by name; returns its address as an Integer.
    # LLVMOrcExecutorAddress is uint64_t (upper bits zero on 32-bit targets).
    def function_address(name)
      address = nil
      FFI::MemoryPointer.new(:uint64) do |out|
        raise_if_error(C.lookup(@ptr, out, name))
        address = out.read_uint64
      end
      address
    end

    # Call a JIT-compiled function and wrap the result in a GenericValue (like
    # ExecutionEngine#run_function). The function's module must already be added.
    #: (Function, *untyped) -> GenericValue?
    def run_function(fun, *args)
      arg_types = fun.params.map { |p| convert_type(p.type) }
      ptr = FFI::Pointer.new(function_address(fun.name))
      raise "Couldn't find function" if ptr.null?

      return_type = convert_type(fun.function_type.return_type)
      f = FFI::Function.new(return_type, arg_types, ptr) #: as untyped
      ret = f.call(*args)
      begin
        LLVM.make_generic_value(fun.function_type.return_type, ret)
      rescue ArgumentError
        nil
      end
    end

    def dispose
      return if @ptr.nil?
      err = C.dispose_lljit(@ptr)
      @ptr = nil
      raise_if_error(err)
    end

    def triple_string
      C.get_triple_string(@ptr)
    end

    def data_layout
      C.get_data_layout_str(@ptr)
    end

    def global_prefix
      gp = C.get_global_prefix(@ptr)
      gp.zero? ? "" : gp.chr
    end

    private

    # Map an LLVM type to the FFI type FFI::Function expects (mirrors ExecutionEngine#convert_type).
    def convert_type(type)
      case type.kind
      when :integer
        type.width <= 8 ? :int8 : :"int#{type.width}"
      else
        type.kind
      end
    end

    def raise_if_error(err)
      return if err.null?
      raise "LLJIT error: #{error_message(err)}"
    end

    # Consume an LLVMErrorRef, returning its message and freeing the heap char* LLVM allocated.
    def error_message(err)
      msg, ptr = C.get_error_message(err)
      C.dispose_error_message(ptr)
      msg
    end

    module C
      extend FFI::Library

      ffi_lib_flags(:lazy, :global)
      ffi_lib ["LLVM-#{LLVM_VERSION}", "libLLVM-#{LLVM_VERSION}",
               "libLLVM-#{LLVM_VERSION}.so.1",
               "libLLVM.so.#{LLVM_VERSION}", "libLLVM.so.#{LLVM_VERSION}.1", "LLVM-C",]

      attach_function :create_lljit_builder, :LLVMOrcCreateLLJITBuilder, [], :pointer
      attach_function :create_lljit, :LLVMOrcCreateLLJIT, [:pointer, :pointer], :pointer
      attach_function :dispose_lljit, :LLVMOrcDisposeLLJIT, [:pointer], :pointer

      attach_function :get_main_jit_dylib, :LLVMOrcLLJITGetMainJITDylib, [:pointer], :pointer
      attach_function :get_global_prefix, :LLVMOrcLLJITGetGlobalPrefix, [:pointer], :char
      attach_function :get_triple_string, :LLVMOrcLLJITGetTripleString, [:pointer], :string
      attach_function :get_data_layout_str, :LLVMOrcLLJITGetDataLayoutStr, [:pointer], :string

      attach_function :create_thread_safe_context, :LLVMOrcCreateNewThreadSafeContext, [], :pointer
      attach_function :dispose_thread_safe_context, :LLVMOrcDisposeThreadSafeContext, [:pointer], :void
      attach_function :create_thread_safe_module, :LLVMOrcCreateNewThreadSafeModule, [:pointer, :pointer], :pointer

      attach_function :add_ir_module, :LLVMOrcLLJITAddLLVMIRModule, [:pointer, :pointer, :pointer], :pointer
      attach_function :lookup, :LLVMOrcLLJITLookup, [:pointer, :pointer, :string], :pointer

      attach_function :create_process_generator,
                      :LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess,
                      [:pointer, :char, :pointer, :pointer], :pointer
      attach_function :dylib_add_generator, :LLVMOrcJITDylibAddGenerator, [:pointer, :pointer], :void

      # LLVMGetErrorMessage consumes the error and returns a heap char* the caller must free
      # with LLVMDisposeErrorMessage. :strptr returns [message, char_ptr] so we can dispose it.
      attach_function :get_error_message, :LLVMGetErrorMessage, [:pointer], :strptr
      attach_function :dispose_error_message, :LLVMDisposeErrorMessage, [:pointer], :void
    end
  end
end
