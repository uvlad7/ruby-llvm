# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# No Windows/mingw/Cygwin/riscv64 build of sorbet-static exists (only x86_64-linux,
# aarch64-linux, universal-darwin, java); tapioca pulls it in via sorbet-static-and-runtime.
# Keep both in a group so platforms without a sorbet-static build skip it explicitly with
# BUNDLE_WITHOUT=typecheck — Gem.win_platform? can't guard this, since it is false on Cygwin.
group :typecheck do
  gem "sorbet-static"
  gem "tapioca", "~> 0.16.11"
end

group :devtools, optional: true do
  gem "ffi_gen", source: "https://gem.coop/@uvlad7"
end
