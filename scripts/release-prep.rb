#!/usr/bin/env ruby
# frozen_string_literal: true

# release-prep.rb — generates the Homebrew formula and MacPorts Portfile
# for a NanoDictate release.
#
# Usage:  ruby scripts/release-prep.rb v0.1.0
#
# Steps:
#   1. downloads the two binary tarballs attached to the GitHub Release:
#      https://github.com/kodmial/nanodictate/releases/download/<tag>/nanodictate-<ver>-macos-{arm64,x86_64}.tar.gz
#   2. computes sha256 for both binary tarballs (Homebrew formula AND MacPorts
#      Portfile — the port consumes the same arch-specific tarballs)
#   3. substitutes __VERSION__, __SHA256_ARM64__, __SHA256_X86_64__ in the .tpl files
#   4. writes packaging/homebrew/nanodictate.rb and packaging/macports/Portfile
#
# Stdlib only (open-uri, digest). No external gems.
#
# NOTE: this needs the GitHub Release to exist (with both tarballs attached),
# so it runs only after the release workflow has published a tag.

require "open-uri"
require "digest/sha2"
require "uri"

TAG = ARGV[0]
unless TAG && TAG =~ /\Av?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/
  abort "Usage: ruby scripts/release-prep.rb v0.1.0   (tag may be '0.1.0' or 'v0.1.0')"
end

VERSION     = TAG.sub(/\Av/, "")
ROOT = File.expand_path("..", __dir__)

# Binary tarballs attached to the GitHub Release. The tag in the download path
# keeps the "v" prefix; the archive filename does not. Contract fixed in
# .github/workflows/release.yml — keep this in sync with it.
def binary_url(arch)
  "https://github.com/kodmial/nanodictate/releases/download/#{TAG}/" \
    "nanodictate-#{VERSION}-macos-#{arch}.tar.gz"
end

def filled_template(path, values)
  content = File.read(path)
  values.each { |k, v| content = content.gsub(k, v) }
  content
end

def network_blocked_msg(err)
  "Download blocked: #{err.class}: #{err.message}\n" \
    "  Direct GitHub access appears blocked; retry from a network where\n" \
    "  github.com is reachable.\n"
end

# Download +url+, aborting with a tag-specific message on failure. Exits the
# script, so a non-nil return is guaranteed on success.
def download(url, what)
  puts "Downloading #{url}"
  URI.open(url, read_timeout: 120, open_timeout: 30).read
rescue OpenURI::HTTPError => e
  abort "Download failed: HTTP #{e.io.status.join(" ")} — is tag '#{TAG}' published?\n" \
        "  Verify in a browser first that the #{what} exists, then re-run.\n"
rescue SystemCallError, SocketError, Timeout::Error => e
  abort network_blocked_msg(e)
rescue EOFError => e
  # Connection-level failures, e.g. a dropped connection mid-download.
  # Anything else (a script bug, an unexpected error class) is left to
  # propagate — aborting here would mislabel it as a download issue.
  abort network_blocked_msg(e)
end

# --- 1. Download both binary tarballs ----------------------------------------
arm = download(binary_url("arm64"), "arm64 binary tarball")
x86 = download(binary_url("x86_64"), "x86_64 binary tarball")

# --- 2. Checksums (binary tarballs: Homebrew formula + MacPorts Portfile) -----
sha256_arm64  = Digest::SHA256.hexdigest(arm)
sha256_x86_64 = Digest::SHA256.hexdigest(x86)

# --- 3. Fill templates -------------------------------------------------------
values = {
  "__VERSION__"       => VERSION,                 # "0.1.0" (no leading v)
  "__SHA256_ARM64__"  => sha256_arm64,            # Homebrew formula + Portfile, arm64 tarball
  "__SHA256_X86_64__" => sha256_x86_64,           # Homebrew formula + Portfile, x86_64 tarball
}

formula_tpl  = File.join(ROOT, "packaging", "homebrew", "nanodictate.rb.tpl")
formula_out  = File.join(ROOT, "packaging", "homebrew", "nanodictate.rb")
portfile_tpl = File.join(ROOT, "packaging", "macports", "Portfile.tpl")
portfile_out = File.join(ROOT, "packaging", "macports", "Portfile")

File.write(formula_out, filled_template(formula_tpl, values))
File.write(portfile_out, filled_template(portfile_tpl, values))

# --- 4. Report and instructions ----------------------------------------------
puts "Wrote:"
puts "  #{formula_out}"
puts "  #{portfile_out}"
puts "Checksums for #{TAG}:"
puts "  arm64 binary tarball   sha256  #{sha256_arm64}"
puts "  x86_64 binary tarball  sha256  #{sha256_x86_64}"
puts
puts "Next steps:"
puts "  1. Fill the maintainers handle in #{portfile_out} (never auto-generate a person's id)."
puts "  2. Sanity-check the version string: `nanodictate --version` will print \"nanodictate #{VERSION}\"."
puts "  3. Homebrew: copy #{formula_out} into the nanodictate-homebrew tap as"
puts "     Formula/nanodictate.rb, then run `brew audit --strict --new nanodictate` there."
puts "  4. MacPorts: copy #{portfile_out} into a macports-ports checkout as"
puts "     audio/nanodictate/Portfile, then run `port lint` before opening the PR."
puts "  5. Test a real install: `brew install nanodictate` and `port install`."