# frozen_string_literal: true
# typed: true

require "test_helper"
require "llvm/config"
require "llvm/target"

module LLVM
  class LLJit
    module C
      attach_function :detect_host_jtmb, :LLVMOrcJITTargetMachineBuilderDetectHost, [:pointer], :pointer
      attach_function :jtmb_get_triple, :LLVMOrcJITTargetMachineBuilderGetTargetTriple, [:pointer], :strptr
      attach_function :dispose_jtmb, :LLVMOrcDisposeJITTargetMachineBuilder, [:pointer], :void
    end
  end
end

class LLJitTest < Minitest::Test
  def setup
    LLVM.init_jit
  end

  def test_create_lljit
    lljit = LLVM::LLJit.new
    assert lljit
  ensure
    lljit&.dispose
  end

  def test_lljit_strings_exist
    lljit = LLVM::LLJit.new
    refute_empty(lljit.triple_string)
    refute_empty(lljit.data_layout)
    assert(lljit.global_prefix)
  ensure
    lljit&.dispose
  end

  def test_lljit_strings
    lljit = LLVM::LLJit.new

    jtmb = nil #: FFI::Pointer?
    FFI::MemoryPointer.new(:pointer) do |out|
      assert(LLVM::LLJit::C.detect_host_jtmb(out).null?)
      jtmb = out.read_pointer
    end
    triple, triple_ptr = LLVM::LLJit::C.jtmb_get_triple(jtmb)
    LLVM::C.dispose_message(triple_ptr)
    # e.g. "x86_64-pc-linux-gnu", "x86_64-apple-darwin24.6.0" — the runtime triple, matching lljit's
    assert_equal(triple, lljit.triple_string)

    target_out = FFI::MemoryPointer.new(:pointer)
    error_out = FFI::MemoryPointer.new(:pointer)
    assert_equal(0, LLVM::C.get_target_from_triple(triple, target_out, error_out))
    target = LLVM::Target.from_ptr(target_out.read_pointer)
    machine = target.create_machine(triple)
    data = LLVM::C.create_target_data_layout(machine)

    # "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128" on x86_64-linux
    assert_equal(LLVM::TargetDataLayout.from_ptr(data).to_s, lljit.data_layout)
  ensure
    LLVM::C.dispose_target_data(data) if data
    machine&.dispose
    LLVM::LLJit::C.dispose_jtmb(jtmb) if jtmb
    lljit&.dispose
  end

  def test_simple_function
    mod = create_square_function_module

    engine = LLVM::LLJit.new
    engine.add_module(mod)

    result = engine.run_function(mod.functions['square'], 5)
    assert_equal 25, result.to_i
  ensure
    engine&.dispose
  end

  def test_function_address
    mod = create_square_function_module

    engine = LLVM::LLJit.new
    engine.add_module(mod)

    assert_operator engine.function_address('square'), :>, 0
  ensure
    engine&.dispose
  end

  def test_add_module
    main_mod = LLVM::Module.new('main')

    main_mod.functions.add(:square, [LLVM::Int], LLVM::Int) do |square|
      main_mod.functions.add(:call_square, [], LLVM::Int) do |call_square|
        call_square.basic_blocks.append.build do |builder|
          n = builder.call(square, LLVM::Int(5))
          builder.ret(n)
        end
      end
    end

    main_mod.verify!

    engine = LLVM::LLJit.new
    engine.add_module(main_mod)
    engine.add_module(create_square_function_module)

    result = engine.run_function(main_mod.functions['call_square'])
    assert_equal 25, result.to_i
  ensure
    engine&.dispose
  end
end
