# typed: true

# lib/llvm/config.rb is generated at build time (ext/ruby-llvm-support) and gitignored, so
# Sorbet never sees LLVM::CONFIG. Declare its shape here so references to it typecheck.
module LLVM::CONFIG
  VERSION = T.let(T.unsafe(nil), String)
  COMPONENTS = T.let(T.unsafe(nil), T::Array[String])
  TARGETS_BUILT = T.let(T.unsafe(nil), T::Array[String])
  HOST_TARGET = T.let(T.unsafe(nil), String)
  BUILD_MODE = T.let(T.unsafe(nil), String)
  CFLAGS = T.let(T.unsafe(nil), String)
  CXXFLAGS = T.let(T.unsafe(nil), String)
  LDFLAGS = T.let(T.unsafe(nil), String)
  LIBS = T.let(T.unsafe(nil), String)
end
