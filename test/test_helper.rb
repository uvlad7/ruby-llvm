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
require "llvm/lljit"
require "llvm/execution_engine"

# Top level rather than inside Minitest::Test: the JIT suites are modules included into
# generated per-engine classes, and constant lookup from a module body does not walk the
# including class's ancestors.
LLVM_SIGNED = true
LLVM_UNSIGNED = false

LLVM_FALSE = 0
LLVM_TRUE = 1

class Minitest::Test
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

def cygwin?
  FFI::Platform::OS == 'cygwin'
end

# i386 mangles C symbols with a leading underscore. 32-bit Cygwin untested.
def underscore_mangled_symbols?
  FFI::Platform::ADDRESS_SIZE == 32 && (FFI::Platform::IS_WINDOWS || cygwin?)
end

# Register libc symbols under the names the JIT will look for. No-op on Unix and 64-bit
# Windows, which auto-resolve; there the whole method returns early.
#
# Cygwin needs the plain name registered at any bitness: the process exports two getenvs --
# cygwin1.dll's, returning POSIX paths, which is what Ruby's ENV agrees with, and the Windows
# CRT's (msvcrt/ucrtbase), returning native paths -- and MCJIT's process-wide search binds
# whichever it finds first, so test_external_string saw the native form on some runs and the
# POSIX form on others. LLVMAddSymbol lands in LLVM's explicit-symbol table, which
# SearchForAddressOfSymbol consults ahead of the process, pinning it to FFI::Library::LIBC
# (cygwin1.dll) and making resolution deterministic.
def register_libc_symbol_for_jit(name)
  return unless underscore_mangled_symbols? || cygwin?

  ptr = FFI::DynamicLibrary.open(FFI::Library::LIBC, FFI::DynamicLibrary::RTLD_LAZY).find_function(name)
  return unless ptr

  LLVM::C.add_symbol("_#{name}", ptr) if underscore_mangled_symbols?
  LLVM::C.add_symbol(name, ptr) if cygwin?
end

# JIT engines the suite exercises.
#
# LLJIT (ORC) runs everywhere: it is where upstream LLVM is heading, it is the only engine that
# works on some targets, and testing it only as a fallback left it barely covered. MCJIT runs
# wherever it is not known-broken -- on riscv64 its RuntimeDyld mis-relocates globals.
JIT_ENGINES = [
  :lljit,
  *(FFI::Platform::ARCH.to_s.start_with?('riscv') ? [] : [:mcjit]),
].freeze #: Array[Symbol]

# Engine a test runs under. Parametrized classes override this; anything else gets the first
# available engine.
def jit_engine
  JIT_ENGINES.first
end

# Build one test class per JIT engine from a module of test methods, so a failure names the
# engine it happened under -- ArrayTestCase_LLJIT#test_x rather than a bare ArrayTestCase#test_x
# that gives no clue which engine broke.
#: (Module) -> void
def define_jit_cases(mod)
  JIT_ENGINES.each do |engine|
    klass = Class.new(Minitest::Test) { include mod }
    klass.send(:define_method, :jit_engine) { engine }
    Object.const_set("#{mod.name}_#{engine.to_s.upcase}", klass)
  end
end

# Build the engine for this test and add host_module to it. Both engines answer
# #run_function(fun, *args) and #dispose.
def jit_engine_for(host_module)
  # i386 codegen assumes a 16-byte-aligned stack, but Ruby calls in 4-byte aligned, so JIT'd
  # functions that call out crash; make each realign its own stack. Real callers own this.
  if underscore_mangled_symbols?
    stackrealign = LLVM::Attribute.string("stackrealign", "")
    host_module.functions.each { |fn| fn.add_attribute(stackrealign) }
  end

  if jit_engine == :lljit
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
