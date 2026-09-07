#!/usr/bin/env ruby
# frozen_string_literal: true

# pins.rb — read recipe.yml's `tools:` block (the repo's toolchain pin
# SSOT) and emit KEY=VALUE lines for $GITHUB_ENV. The workflow carries NO
# version or digest literals — every value flows from the recipe.
#
#   ruby tools/pins.rb <tool-platform> [flavor] [--env]
#   ruby tools/pins.rb --release-only [flavor]
#
# <tool-platform> is the tebako release asset platform (macos-arm64,
# linux-gnu-x86_64, linux-gnu-arm64). [flavor] is the recipe's flavor key
# (the spec 28 §8 axis shape; for truffleruby the flavor names the MODE —
# default "native"; `jvm` lands with TODO.truffleruby/03). --release-only
# emits just TEBAKO_RELEASE/PKG_NAME/PKG_VERSION. A tool listed in
# tools.sha256 without a pin for the requested platform is a named error,
# never a guess (spec 00 §9).
#
# Runtime-promotion additions (the kind: runtime pair): the wrapper exe
# pin flows from recipe.yml's runtime.wrapper_tebako (WRAPPER_RELEASE /
# WRAPPER_ASSET / RUNTIME_STEM_BASE) and the POSIX legs get PRELOAD_SHIM
# (the extracted link-unit tarball's libtfs_preload path). The sha256
# map is data-driven: every tool key under tools.sha256 emits
# <TOOL>_ASSET/<TOOL>_SHA256 (link-unit names a .tar.gz, the CLIs name
# bare binaries).
#
# NEVER emit a bare TEBAKO_VERSION: in the sibling feedstocks tools/build
# uses that name for the RUNTIME release line with an env override, so a
# tools-version export silently clobbers the runtime pin (the 2026-08-27
# metanorma collision: the press resolved runtime release v0.3.1, exit
# 124). The tools version lives inside the computed ASSET names.

require "yaml"

def die(msg)
  warn "pins.rb: #{msg}"
  exit 64
end

root = File.expand_path("..", __dir__)
recipe = YAML.load_file(File.join(root, "recipe.yml"))
tools = recipe.fetch("tools")
release = tools.fetch("release")
version = release.sub(/\Av/, "")
die "recipe.yml tools.sha256 missing" unless tools["sha256"].is_a?(Hash)

# The flavor axis (spec 28 §8's shape): the flavor key names the recipe's
# flavors:<flavor> block (default native). Positional after the
# tool-platform (`pins.rb macos-arm64 native --env`), or the sole
# positional in --release-only mode (`pins.rb --release-only native`).
# PKG_VERSION, RUNTIME_STEM_BASE and IMPLEMENTATION follow the selected
# flavor.
positional = ARGV - ["--env", "--release-only"]
flavor = if ARGV.include?("--release-only")
           positional[0] || ENV["FLAVOR"] || "native"
         else
           positional[1] || ENV["FLAVOR"] || "native"
         end
flavors = recipe.fetch("flavors") do
  die "recipe.yml flavors block missing"
end
flavor_block = flavors[flavor] or
  die "recipe.yml: unknown flavor '#{flavor}' (have: #{flavors.keys.join(', ')})"

runtime = recipe.fetch("runtime")
# The wrapper pin is per-FLAVOR overridable (the jvm flavor requires the
# spec-33-aware launcher line; the shared runtime block stays the native
# flavor's): flavors.<flavor>.wrapper_tebako / .wrapper_sha256 win when
# present. A missing pin is a named error either way (spec 00 §9).
wrapper_tebako = flavor_block["wrapper_tebako"] || runtime.fetch("wrapper_tebako")
wrapper_shas = flavor_block["wrapper_sha256"] || runtime.fetch("wrapper_sha256")
pkg_version = flavor_block.dig("upstream", "version") ||
              die("recipe.yml flavors.#{flavor}.upstream.version missing")

pairs = {
  "TEBAKO_RELEASE" => release,
  "PKG_NAME" => recipe.fetch("name"),
  "PKG_VERSION" => pkg_version,
  "FLAVOR" => flavor,
  "IMPLEMENTATION" => flavor_block.fetch("implementation"),
}

unless ARGV.include?("--release-only")
  platform = ARGV[0] or die "usage: pins.rb <tool-platform> [--env] | pins.rb --release-only"
  exe = platform.start_with?("windows") ? ".exe" : ""
  # Tools the recipe pins for POSIX legs only: a missing platform pin
  # warns + skips; for every other tool a missing pin is a named error,
  # never a guess. (This feedstock ships NO windows leg — upstream has no
  # windows build — but the guard stays: a tool's POSIX-only scope is the
  # recipe's data, not this script's assumption.)
  posix_only = %w[link-unit]
  tools.fetch("sha256").each do |tool, shas|
    sha = shas[platform]
    if sha.nil?
      die "recipe.yml: no tools.sha256.#{tool}.#{platform} pin" unless posix_only.include?(tool)
      warn "pins.rb: #{tool} has no #{platform} pin (POSIX-only tool — skipped)"
      next
    end
    key = tool.upcase.tr("-", "_")
    asset = if tool == "link-unit"
              "#{tool}-#{version}-#{platform}.tar.gz"
            else
              "#{tool}-#{version}-#{platform}#{exe}"
            end
    pairs["#{key}_ASSET"] = asset
    pairs["#{key}_SHA256"] = sha
  end
  # The wrapper exe (spec 29): the recipe's runtime.wrapper_tebako names
  # the line (ships since tebako v2.1.0); runtime.wrapper_sha256 is its
  # per-platform trust anchor — a missing pin is a named error, never a
  # guess (the launcher ships as the runtime pair's entry point).
  pairs["WRAPPER_RELEASE"] = "v#{wrapper_tebako}"
  pairs["WRAPPER_ASSET"] = "tebako-runtime-launcher-#{wrapper_tebako}-#{platform}#{exe}"
  pairs["WRAPPER_SHA256"] = wrapper_shas[platform] ||
                            die("recipe.yml: no wrapper_sha256.#{platform} pin for flavor '#{flavor}'")
  pairs["RUNTIME_STEM_BASE"] = "tebako-runtime-#{wrapper_tebako}-#{pkg_version}"
  pairs["RUNTIME_STEM"] = "#{pairs['RUNTIME_STEM_BASE']}-#{platform}"
  # The extracted preload shim (POSIX legs only). The tarball's internal
  # top dir is VERSION-LESS (link-unit-<platform>/; the version lives in
  # the asset name) — link-unit-stage.sh has tarred it that way since the
  # script exists.
  unless platform.start_with?("windows")
    dl_ext = platform.include?("macos") ? "dylib" : "so"
    pairs["PRELOAD_SHIM"] = ".packager/link-unit-#{platform}/libtfs_preload.#{dl_ext}"
  end
  # The composed smoke's owner pair (flavors with an on_runtime edge —
  # spec 33): the workflow downloads the PUBLISHED owner runtime into a
  # throwaway store. The recipe's flavors.<flavor>.owner_smoke block is
  # the pin SSOT (repo/release/version/tebako line + exe/image sha256
  # per platform, cross-checked against that release's own SHA256SUMS at
  # fetch). The store dir ids ride the release-asset platform spelling
  # (java-<ver>-<line>-<platform>), matching the store grammar.
  if (owner = flavor_block["owner_smoke"])
    owner_version = owner.fetch("version")
    owner_line = owner.fetch("tebako")
    pairs["OWNER_REPO"] = owner.fetch("repo")
    pairs["OWNER_RELEASE"] = owner.fetch("release")
    pairs["OWNER_STEM"] = "tebako-runtime-#{owner_line}-#{owner_version}-#{platform}"
    pairs["OWNER_STORE_ID"] = "java-#{owner_version}-#{owner_line}-#{platform}"
    pairs["OWNER_EXE_SHA256"] = owner.fetch("exe_sha256")[platform] ||
                                die("recipe.yml: no owner_smoke.exe_sha256.#{platform} pin")
    pairs["OWNER_IMAGE_SHA256"] = owner.fetch("image_sha256")[platform] ||
                                  die("recipe.yml: no owner_smoke.image_sha256.#{platform} pin")
    pairs["DEP_STORE_ID"] = "ruby-#{pkg_version}-#{wrapper_tebako}-#{platform}"
  end
end

if ARGV.include?("--env") || ARGV.include?("--release-only")
  pairs.each { |k, v| puts "#{k}=#{v}" }
else
  pairs.each { |k, v| puts "export #{k}=#{v}" }
end
