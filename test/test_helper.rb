# frozen_string_literal: true
# typed: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))

begin
  require "debug"
rescue LoadError
  # Ignore ruby-debug is case it's not installed
end

begin
  require 'simplecov'

  unless SimpleCov::Configuration.method_defined?(:skip)
    mod = SimpleCov::Configuration #: as untyped
    mod.send(:alias_method, :skip, :add_filter)
  end
  SimpleCov.start do
    skip "/test/"
    skip "/lib/llvm/transforms/scalar.rb"
    skip "/lib/llvm/transforms/ipo.rb"
    skip "/lib/llvm/transforms/vectorize.rb"
    skip "/lib/llvm/transforms/utils.rb"
    skip "/lib/llvm/transforms/builder.rb"
    skip "/lib/llvm/core/pass_manager.rb"
  end
rescue LoadError
  warn "Proceeding without SimpleCov. gem install simplecov on supported platforms."
end

require "minitest/autorun"
require 'minitest/reporters'

if !ENV['RM_INFO']
  Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
end

require "llvm/core"
require "llvm/execution_engine"
require "llvm/lljit"

class Minitest::Test
  LLVM_SIGNED = true
  LLVM_UNSIGNED = false

  LLVM_FALSE = 0
  LLVM_TRUE = 1

  private

  def with_function(arguments, retty, &block)
    mod = LLVM::Module.new('test')
    fun = mod.functions.add('fun', arguments, retty)
    block.yield(fun)
    mod.dispose
  end

  def create_square_function_module
    LLVM::Module.new('square').tap do |mod|
      mod.functions.add(:square, [LLVM::Int], LLVM::Int) do |fun, x|
        fun.basic_blocks.append.build do |builder|
          n = builder.mul(x, x)
          builder.ret(n)
        end
      end

      mod.verify!
    end
  end

  def create_cube_function_module
    LLVM::Module.new('cube').tap do |mod|
      mod.functions.add(:cube, [LLVM::Int], LLVM::Int) do |fun, x|
        fun.basic_blocks.append.build do |builder|
          n2 = builder.mul(x, x)
          n3 = builder.mul(n2, x)
          builder.ret(n3)
        end
      end

      mod.verify!
    end
  end
end

def define_module(module_name)
  new_module = LLVM::Module.new(module_name)
  yield new_module
  assert_predicate new_module, :valid?
  new_module
end

def define_invalid_module(module_name)
  new_module = LLVM::Module.new(module_name)
  yield new_module
  refute_predicate new_module, :valid?
  new_module
end

def define_function(host_module, function_name, argument_types, return_type)
  function = host_module.functions.add(function_name, argument_types, return_type) do |function, *arguments|
    yield(LLVM::Builder.new, function, *arguments)
  end
  assert_predicate function, :valid?
  function
end

def define_invalid_function(host_module, function_name, argument_types, return_type)
  function = host_module.functions.add(function_name, argument_types, return_type) do |function, *arguments|
    yield(LLVM::Builder.new, function, *arguments)
  end
  refute_predicate function, :valid?
  function
end

# Find a libc/libm symbol's address, trying libc then libm. Returns nil if not found.
def jit_symbol_pointer(name)
  [FFI::Library::LIBC, 'm'].each do |lib|
    dl = begin
      FFI::DynamicLibrary.send(:load_library, lib, nil)
    rescue LoadError
      next
    end
    ptr = dl.find_function(name)
    return ptr if ptr
  end
  nil
end

# Make a libc/libm symbol resolvable by JIT'd code (MCJIT, or LLJIT's process generator). Most
# libc funcs auto-resolve, but libm (e.g. sin) isn't in MCJIT's default search, so register from
# wherever the symbol lives. i386 COFF (Windows/Cygwin) mangles names with a leading '_'.
def register_jit_symbol(name)
  ptr = jit_symbol_pointer(name)
  return unless ptr

  i386_coff = FFI::Platform::ADDRESS_SIZE == 32 && (FFI::Platform::IS_WINDOWS || FFI::Platform::OS == 'cygwin')
  LLVM::C.add_symbol(i386_coff ? "_#{name}" : name, ptr)
end

# Build a JIT engine with host_module added. MCJIT is the default (works everywhere, incl. i386
# where JITLink has no backend); on riscv MCJIT/RuntimeDyld mis-relocates globals (upstream LLVM
# bug), so use LLJIT/ORC there. Both respond to #run_function(fun, *args) and #dispose.
def jit_engine_for(host_module)
  # i386 codegen assumes a 16-byte-aligned stack, but Ruby calls in 4-byte aligned, so JIT'd
  # functions that call out crash; make each realign its own stack. Real callers own this.
  if FFI::Platform::ADDRESS_SIZE == 32 && (FFI::Platform::IS_WINDOWS || FFI::Platform::OS == 'cygwin')
    stackrealign = LLVM::Attribute.string("stackrealign", "")
    host_module.functions.each { |fn| fn.add_attribute(stackrealign) }
  end
  if FFI::Platform::ARCH.to_s.start_with?('riscv')
    engine = LLVM::LLJit.new
    engine.add_module(host_module)
    engine
  else
    LLVM::MCJITCompiler.new(host_module)
  end
end

def run_function_on_module(host_module, function_name, *argument_values)
  engine = jit_engine_for(host_module)
  engine.run_function(
    host_module.functions[function_name],
    *argument_values #: as untyped
  )
ensure
  engine&.dispose
end

def run_function(argument_types, argument_values, return_type, &block)
  test_module = define_module("test_module") do |host_module|
    define_function(host_module, "test_function", argument_types, return_type, &block)
  end

  run_function_on_module(
    test_module,
    "test_function",
    *argument_values #: as untyped
  )
end
