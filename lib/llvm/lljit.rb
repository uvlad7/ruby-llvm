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
    #
    # target_machine overrides the host detection ORC would otherwise do, which is how you get a
    # JIT for something other than exactly this CPU -- a generic CPU with no target features,
    # say, so instruction selection falls back to libcalls the way it would on a machine lacking
    # those extensions. ORC takes ownership of it: do not dispose or reuse it afterwards.
    #: (?LLVM::TargetMachine?) -> void
    def initialize(target_machine = nil)
      builder = C.create_lljit_builder
      if target_machine
        jtmb = C.jtmb_from_target_machine(target_machine)
        C.builder_set_jtmb(builder, jtmb)
      end
      FFI::MemoryPointer.new(FFI.type_size(:pointer)) do |out|
        raise_if_error(C.create_lljit(out, builder))
        @ptr = out.read_pointer
      end

      # global_prefix is '\0' on ELF, '_' on Mach-O / i386 COFF; a null filter accepts all.
      begin
        add_generator { |out| C.create_process_generator(out, C.get_global_prefix(@ptr), nil, nil) }
      rescue StandardError
        dispose
        raise
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

    # Make a shared library's symbols visible to JIT'd code. The process generator installed in
    # #initialize only sees what the running process already exports, so anything loaded later --
    # or never loaded at all -- has to be added explicitly.
    #: (String) -> void
    def add_library(path)
      add_generator do |out|
        C.create_dylib_path_generator(out, path, C.get_global_prefix(@ptr), nil, nil)
      end
    end

    # As #add_library, but for a static archive (.a). Needed for the compiler runtime: builtins
    # like __muldi3 and __adddf3, which LLVM emits as libcalls on targets lacking the instruction,
    # live in libgcc.a or libclang_rt.builtins-*.a and are absent from libgcc_s.so, so no dynamic
    # generator can reach them. Without this, JIT'd float or 64-bit arithmetic fails to
    # materialize on soft-float targets such as riscv64.
    #: (String) -> void
    def add_static_library(path)
      add_generator { |out| C.create_static_lib_generator(out, C.get_obj_linking_layer(@ptr), path) }
    end

    # Look up a compiled symbol by name; returns its address as an Integer.
    # LLVMOrcExecutorAddress is uint64_t (upper bits zero on 32-bit targets).
    def function_address(name)
      address = nil #: Integer?
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

    # Build a generator with the given block and attach it to the main dylib, which takes
    # ownership. The block receives an out-parameter and returns an LLVMErrorRef.
    #: { (FFI::MemoryPointer) -> FFI::Pointer } -> void
    def add_generator(&)
      FFI::MemoryPointer.new(FFI.type_size(:pointer)) do |out|
        raise_if_error(yield(out))
        C.dylib_add_generator(C.get_main_jit_dylib(@ptr), out.read_pointer)
      end
    end

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
      C.get_error_message(err)
    end

    module C
      extend FFI::Library

      LLVM.inject_llvm_libs(self)

      attach_function :create_lljit_builder, :LLVMOrcCreateLLJITBuilder, [], :pointer
      # takes ownership of the TargetMachine; the JTMB is in turn owned by the builder
      attach_function :jtmb_from_target_machine,
                      :LLVMOrcJITTargetMachineBuilderCreateFromTargetMachine,
                      [:pointer], :pointer
      attach_function :builder_set_jtmb,
                      :LLVMOrcLLJITBuilderSetJITTargetMachineBuilder,
                      [:pointer, :pointer], :void
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
      attach_function :create_dylib_path_generator,
                      :LLVMOrcCreateDynamicLibrarySearchGeneratorForPath,
                      [:pointer, :string, :char, :pointer, :pointer], :pointer
      # takes the object linking layer rather than a triple, despite what the header comment says
      attach_function :create_static_lib_generator,
                      :LLVMOrcCreateStaticLibrarySearchGeneratorForPath,
                      [:pointer, :pointer, :string], :pointer
      attach_function :get_obj_linking_layer, :LLVMOrcLLJITGetObjLinkingLayer, [:pointer], :pointer
      attach_function :dylib_add_generator, :LLVMOrcJITDylibAddGenerator, [:pointer, :pointer], :void

      # LLVMGetErrorMessage consumes the error and returns a heap char* the caller must free
      # with LLVMDisposeErrorMessage. :strptr returns [message, char_ptr] so we can dispose it.
      attach_function :get_error_message, :LLVMGetErrorMessage, [:pointer], LLVM::OwnedErrorString
    end
  end
end
