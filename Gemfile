# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# sorbet-static publishes gems only for x86_64-linux, aarch64-linux, and universal-darwin
# (tapioca pulls it in via sorbet-static-and-runtime) — nothing for Windows, Cygwin, or riscv64.
# Bundler still *resolves* a gem in a `without` group (it only skips installing it), so a plain
# group + BUNDLE_WITHOUT can't avoid the resolution failure on those platforms; guard by platform
# so it's absent from the dependency graph there. Kept in a group so it can still be skipped
# explicitly (e.g. for a faster install) where it does build.
if RUBY_PLATFORM.match?(/darwin|(?:x86_64|aarch64)-linux/)
  group :typecheck do
    gem "sorbet-static"
    gem "tapioca", "~> 0.16.11"
  end
end

unless RUBY_PLATFORM.match?(/mswin|mingw|cygwin/)
  group :devtools, optional: true do
    gem "ffi_gen", source: "https://gem.coop/@uvlad7"
  end
end
