# frozen_string_literal: true
# typed: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))

begin
  require "debug"
rescue LoadError
  # Ignore ruby-debug is case it's not installed
rescue ArgumentError => e
  # debug installs a method-added tracker built on TracePoint's :call event, which TruffleRuby
  # does not implement. It raises ArgumentError rather than LoadError, so the rescue above does
  # not catch it and the whole suite dies on require. It is only a convenience for interactive
  # debugging, so carrying on without it is fine.
  warn "Proceeding without the debug gem: #{e.message}"
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

# Find a symbol for JIT'd code to call: libc first, then libm. Most libc functions resolve
# themselves, but libm (sin and friends) is not in MCJIT's default search, so it has to be
# registered explicitly.
#
# libc is FFI::Library::LIBC deliberately rather than whatever the process search finds first:
# on Cygwin that is cygwin1.dll, and the process ALSO exports the Windows CRT's (msvcrt /
# ucrtbase) versions. The two disagree -- cygwin1.dll's getenv returns the POSIX PATH that
# Ruby's ENV agrees with, the CRT's returns the native one -- and MCJIT bound whichever it
# reached first, so test_external_string saw either form depending on the run.
def jit_symbol_pointer(name)
  [FFI::Library::LIBC, 'm'].each do |lib|
    dl = begin
      # load_library applies FFI's platform name mapping ('m' -> libm.so.6 etc); the public
      # .open takes an already-mapped filename.
      FFI::DynamicLibrary.send(:load_library, lib, nil)
    rescue LoadError
      next
    end
    ptr = dl&.find_function(name)
    return ptr if ptr
  end
  nil
end

# Find a symbol exported by the running process itself -- notably libruby's, which live
# neither in libc nor libm. Returns nil when Ruby is statically linked without exported
# symbols, which is a legitimate configuration rather than a failure.
def process_symbol_pointer(name)
  FFI::DynamicLibrary.open(nil, FFI::DynamicLibrary::RTLD_LAZY).find_function(name)
rescue LoadError, FFI::NotFoundError
  nil
end

# Make a libc/libm symbol resolvable by JIT'd code (MCJIT, or LLJIT's process generator).
# LLVMAddSymbol lands in LLVM's explicit-symbol table, which SearchForAddressOfSymbol consults
# ahead of the process, so this both adds what is missing and pins what is ambiguous.
# i386 COFF (Windows/Cygwin) mangles C symbols with a leading underscore.
def register_jit_symbol(name)
  ptr = jit_symbol_pointer(name)
  return unless ptr

  LLVM::C.add_symbol(underscore_mangled_symbols? ? "_#{name}" : name, ptr)
end

# Targets where MCJIT's RuntimeDyld is unusable:
#
#   riscv64  mis-relocates globals, so JIT'd code reads the wrong memory.
#   arm      JIT'd calls out of the module can spin forever. Observed on Alpine musl with
#            LLVM 21, where both a libruby call (CallTestCase#test_calls_into_libruby) and a
#            plain libc one (#test_external) hung. It is not universal on armv7 -- the same
#            suite passes on Debian glibc with LLVM 22 -- but which toolchains are affected is
#            not established, so the engine is skipped on 32-bit arm outright.
#
# It has to be avoided rather than contained: the spinning frame is JIT'd code holding the GIL,
# so Timeout's thread never runs and the process has to be killed from outside. A hang costs a
# whole CI job, which is why this errs toward skipping.
#: -> bool
def mcjit_supported?
  # Escape hatch for probing a platform that is skipped here, without editing this list. Set
  # RL_FORCE_MCJIT=1 to find out what MCJIT actually does on it -- see test-riscv-mcjit-probe.
  return true if ENV['RL_FORCE_MCJIT'] == '1'
  return false if FFI::Platform::ARCH.to_s.start_with?('riscv')

  # 32-bit arm only: aarch64 is fine, and it also reports an 'arm'-prefixed arch on some
  # platforms, so the pointer size is what separates them -- as for Windows above.
  !(FFI::Platform::ARCH.to_s.start_with?('arm') && FFI::Platform::ADDRESS_SIZE == 32)
end

# JIT engines the suite exercises. LLJIT (ORC) runs everywhere: it is where upstream LLVM is
# heading, it is the only engine that works on some targets, and testing it only as a fallback
# left it barely covered.
JIT_ENGINES = [
  :lljit,
  *(mcjit_supported? ? [:mcjit] : []),
].freeze #: Array[Symbol]

# Engine a test runs under. Parametrized classes override this. Everything else keeps MCJIT,
# the engine those suites have always used: defaulting to JIT_ENGINES.first silently moved
# every non-parametrized suite onto LLJIT, which is how LinkerTestCase started failing to
# materialize symbols on Windows.
def jit_engine
  JIT_ENGINES.include?(:mcjit) ? :mcjit : JIT_ENGINES.first
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
