# frozen_string_literal: true
# typed: true

require "test_helper"

module CallTestCase
  def setup
    LLVM.init_jit
  end

  def test_simple_call
    test_module = define_module("test_module") do |host_module|
      define_function(host_module, "test_function", [], LLVM::Int) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(LLVM::Int(1))
      end
    end
    assert function = test_module.functions["test_function"]
    assert_equal :function, function.type.kind
    assert_equal 'i32 ()', function.type.to_s
    assert_equal :function, function.function_type.kind
    assert_equal 'i32 ()', function.function_type.to_s
    assert_equal :integer, function.return_type.kind
    assert_equal 'i32', function.return_type.to_s
    assert_equal 1, run_function_on_module(test_module, "test_function").to_i
  end

  def test_nested_call
    test_module = define_module("test_module") do |host_module|
      function_1 = define_function(host_module, "test_function_1", [], LLVM::Int) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(LLVM::Int(1))
      end
      define_function(host_module, "test_function_2", [], LLVM::Int) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(builder.call(function_1))
      end
    end
    assert_equal 1, run_function_on_module(test_module, "test_function_2").to_i
  end

  def test_recursive_call
    test_module = define_module("test_module") do |host_module|
      define_function(host_module, "test_function", [LLVM::Int], LLVM::Int) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        recurse = function.basic_blocks.append
        exit = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.cond(builder.icmp(:uge, arguments.first, LLVM::Int(5)), exit, recurse)
        builder.position_at_end(recurse)
        result = builder.call(function, builder.add(arguments.first, LLVM::Int(1)))
        builder.br(exit)
        builder.position_at_end(exit)
        builder.ret(builder.phi(LLVM::Int, entry => arguments.first, recurse => result))
      end
    end
    assert_equal 5, run_function_on_module(test_module, "test_function", 1).to_i
  end

  def test_external
    register_jit_symbol('abs')
    test_module = define_module("test_module") do |host_module|
      external = host_module.functions.add("abs", [LLVM::Int], LLVM::Int)
      define_function(host_module, "test_function", [LLVM::Int], LLVM::Int) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(builder.call(external, arguments.first))
      end
    end
    assert_equal(-10.abs, run_function_on_module(test_module, "test_function", -10).to_i)
  end

  def test_external_string
    register_jit_symbol('getenv')
    test_module = define_module("test_module") do |host_module|
      global = host_module.globals.add(LLVM::Array(LLVM::Int8, 5), "path")
      global.linkage = :internal
      global.initializer = LLVM::ConstantArray.string("PATH")
      refute_predicate global, :thread_local?
      external = host_module.functions.add("getenv", [LLVM::Pointer(LLVM::Int8)], LLVM::Pointer(LLVM::Int8))
      define_function(host_module, "test_function", [], LLVM::Pointer(LLVM::Int8)) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        parameter = builder.gep(global, [LLVM::Int(0), LLVM::Int(0)])
        builder.ret(builder.call(external, parameter))
      end
    end
    assert_equal ENV.fetch("PATH", nil), run_function_on_module(test_module, "test_function").to_ptr.read_pointer.read_string
  end

  # JIT'd code calling into libruby, as ffi-llvm-jit's hello.rb does with
  # rb_string_value_cstr. This is the long-branch case: libruby is mapped far from the page the
  # JIT allocates, and on armv7 a BL reaches only +-32MB, so the engine has to emit a veneer
  # rather than a direct branch. Getting that wrong crashes instead of failing an assertion,
  # which is why it is worth exercising separately from the libc calls above -- libc is close
  # enough that a direct branch can happen to work.
  #
  # rb_intern is the safest Ruby C API function to call from JIT'd code: it takes a C string,
  # returns an ID, allocates no object and cannot raise.
  def test_calls_into_libruby
    ptr = process_symbol_pointer('rb_intern')
    skip 'ruby is statically linked without exported symbols' unless ptr

    LLVM::C.add_symbol(underscore_mangled_symbols? ? '_rb_intern' : 'rb_intern', ptr)
    id_type = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")

    test_module = define_module("test_module") do |host_module|
      name = host_module.globals.add(LLVM::Array(LLVM::Int8, 12), "sym_name")
      name.linkage = :internal
      name.initializer = LLVM::ConstantArray.string("ruby_llvm_x")
      external = host_module.functions.add("rb_intern", [LLVM::Pointer(LLVM::Int8)], id_type)
      define_function(host_module, "test_function", [], id_type) do |builder, function, *_args|
        builder.position_at_end(function.basic_blocks.append)
        builder.ret(builder.call(external, builder.gep(name, [LLVM::Int(0), LLVM::Int(0)])))
      end
    end

    # The same call made directly through FFI: the JIT'd one must agree with it, which it can
    # only do if the branch actually landed in libruby's rb_intern.
    expected = FFI::Function.new(:ulong, [:string], ptr).call("ruby_llvm_x")
    assert_equal expected, run_function_on_module(test_module, "test_function").to_i
  end

  def test_call_with_nonfunction
    define_module("test_module") do |host_module|
      define_function(host_module, "test_function", [], LLVM.Void) do |builder, function|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        assert_raises(ArgumentError) do
          builder.call(nil)
        end
        assert_raises(ArgumentError) do
          builder.call("test")
        end
        assert_raises(ArgumentError) do
          builder.call(LLVM::Int64.from_i(0))
        end
        builder.ret nil
      end
    end
  end

  def test_call_default_call_conv
    test_module = define_module("test_module") do |host_module|
      callee_fun = define_function(host_module, "callee_fun", [LLVM::Int64], LLVM::Int64) do |builder, function, *arguments|
        function.call_conv = :fast
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(arguments[0])
      end

      define_function(host_module, "caller_fun", [], LLVM::Int64) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(builder.call(callee_fun, LLVM::Int64.from_i(42)))
      end
    end

    assert function = test_module.functions["caller_fun"]
    assert_match(/call fastcc i64 @callee_fun/, function.to_s)
    assert_equal 42, run_function_on_module(test_module, "caller_fun").to_i
  end

  def test_call_by_function_name
    test_module = define_module("test_module") do |host_module|
      define_function(host_module, "callee_fun", [LLVM::Int64], LLVM::Int64) do |builder, function, *arguments|
        function.call_conv = :fast
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(arguments[0])
      end

      define_function(host_module, "caller_fun", [], LLVM::Int64) do |builder, function, *arguments|
        entry = function.basic_blocks.append
        builder.position_at_end(entry)
        builder.ret(builder.call('callee_fun', LLVM::Int64.from_i(42)))
      end
    end

    assert function = test_module.functions["caller_fun"]
    assert_match(/call fastcc i64 @callee_fun/, function.to_s)
    assert_equal 42, run_function_on_module(test_module, "caller_fun").to_i
  end

  def test_invoke_missing_personality_function
    test_module = define_invalid_module("test_module") do |host_module|
      callee_fun = define_function(host_module, "callee_fun", [], LLVM::Int64) do |builder, function, *arguments|
        function.call_conv = :fast
        entry = function.basic_blocks.append('entry')
        builder.position_at_end(entry)
        builder.ret(LLVM::Int64.from_i(42))
      end

      # invalid because no personality function is set
      define_invalid_function(host_module, "caller_fun", [], LLVM::Int64) do |builder, function, *arguments|
        entry = function.basic_blocks.append('entry')
        normal = function.basic_blocks.append('normal')
        exception = function.basic_blocks.append('exception')
        entry.build do |b|
          b.invoke(callee_fun, [], normal, exception, 'invoking')
        end
        normal.build do |b|
          b.ret LLVM::Int64.from_i(0)
        end
        exception.build do |b|
          b.landing_pad_cleanup(LLVM::Int64, nil, 0)
          b.ret LLVM::Int64.from_i(-1)
        end
      end
    end

    assert function = test_module.functions["caller_fun"]
    assert_match(/%invoking = invoke fastcc i64 @callee_fun()/, function.to_s)
    assert_match(/^LandingPadInst needs to be in a function with a personality.\n/, test_module.verify)

    # cannot run invalid module
    # assert_equal 42, run_function_on_module(test_module, "callee_fun").to_i
    # assert_equal 42, run_function_on_module(test_module, "caller_fun").to_i
  end
end

define_jit_cases(CallTestCase)
