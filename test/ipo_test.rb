# frozen_string_literal: true
# typed: true

require "test_helper"
require "llvm/core"
require 'llvm/transforms/ipo'
require 'llvm/core/pass_manager'

class IPOTestCase < Minitest::Test
  def setup
    LLVM.init_jit
  end

  def test_gdce
    mod = LLVM::Module.new('test')

    fn1 = add_internal_void_fn(mod, "fn1")
    fn2 = add_internal_void_fn(mod, "fn2")

    main = mod.functions.add("main", [], LLVM.Void) do |fn|
      fn.basic_blocks.append.build do |builder|
        builder.call(fn1)
        builder.ret_void
      end
    end

    fns = mod.functions.to_a
    assert_includes fns, fn1
    assert_includes fns, fn2
    assert_includes fns, main

    # optimize
    engine = LLVM::MCJITCompiler.new(mod)
    pass_builder = LLVM::PassBuilder.new

    pass_builder.gdce!
    pass_builder.run(mod, engine.target_machine)

    fns = mod.functions.to_a
    assert_includes fns, fn1
    refute_includes fns, fn2, 'fn2 should be eliminated'
    assert_includes fns, main
  ensure
    engine&.dispose
  end

  def add_internal_void_fn(mod, name)
    mod.functions.add(name, [], LLVM.Void) do |fn|
      fn.linkage = :internal
      fn.basic_blocks.append.build(&:ret_void)
    end
  end
end
