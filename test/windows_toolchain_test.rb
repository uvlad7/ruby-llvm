# frozen_string_literal: true
# typed: true

require "test_helper"

class WindowsToolchainTest < Minitest::Test
  # Windows has three incompatible toolchains and a libLLVM belongs to exactly one; pairing a
  # Ruby from one with a library from another miscompiles rather than failing to load.
  def test_matched_toolchains_are_accepted
    refute LLVM.windows_toolchain_mismatch?('x64-mswin64_140', 'x86_64-pc-windows-msvc')
    refute LLVM.windows_toolchain_mismatch?('x64-mingw-ucrt', 'x86_64-w64-windows-gnu')
    refute LLVM.windows_toolchain_mismatch?('x64-mingw32', 'x86_64-w64-windows-gnu')
    refute LLVM.windows_toolchain_mismatch?('x86_64-cygwin', 'x86_64-pc-windows-cygnus')
  end

  def test_crossed_toolchains_are_rejected
    assert LLVM.windows_toolchain_mismatch?('x64-mswin64_140', 'x86_64-w64-windows-gnu')
    assert LLVM.windows_toolchain_mismatch?('x64-mingw-ucrt', 'x86_64-pc-windows-msvc')
    assert LLVM.windows_toolchain_mismatch?('x86_64-cygwin', 'x86_64-pc-windows-msvc')
    assert LLVM.windows_toolchain_mismatch?('x86_64-cygwin', 'x86_64-w64-windows-gnu')
    assert LLVM.windows_toolchain_mismatch?('x64-mingw-ucrt', 'x86_64-pc-windows-cygnus')
    assert LLVM.windows_toolchain_mismatch?('x64-mswin64_140', 'x86_64-pc-windows-cygnus')
  end

  # 'cygnus' contains 'gnu', so a looser MinGW test would swallow the Cygwin triple.
  def test_cygwin_triple_is_not_read_as_mingw
    assert_equal :cygwin, LLVM.windows_toolchain('x86_64-pc-windows-cygnus')
    assert_equal :cygwin, LLVM.windows_toolchain('x86_64-cygwin')
    assert_equal :mingw, LLVM.windows_toolchain('x86_64-w64-windows-gnu')
    assert_equal :msvc, LLVM.windows_toolchain('x86_64-pc-windows-msvc')
  end

  def test_non_windows_platforms_are_not_judged
    assert_nil LLVM.windows_toolchain('x86_64-linux')
    assert_nil LLVM.windows_toolchain_mismatch?('x86_64-linux', 'x86_64-pc-linux-gnu')
    assert_nil LLVM.windows_toolchain_mismatch?('arm64-darwin23', 'arm64-apple-darwin23')
    # a windows Ruby against a non-windows LLVM is not this check's business
    assert_nil LLVM.windows_toolchain_mismatch?('x64-mingw-ucrt', 'x86_64-pc-linux-gnu')
  end

  # The check must read the loaded library, not the generated config, so it still holds when ffi
  # resolved a different libLLVM than the support extension was built against.
  def test_reads_the_triple_from_the_loaded_library
    assert_match(/\w+-/, LLVM::C.get_default_triple.to_s)
  end
end
