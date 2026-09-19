#!/usr/bin/env ruby
# frozen_string_literal: true

# release-prep.rb — generates the Homebrew formula and MacPorts Portfile
# for a NanoDictate release.
#
# Usage:  ruby scripts/release-prep.rb v0.1.0
#
# Steps:
#   1. downloads the source tarball
#      https://github.com/kodmial/nanodictate/archive/refs/tags/<tag>.tar.gz
#   2. downloads the two binary tarballs attached to the GitHub Release:
#      https://github.com/kodmial/nanodictate/releases/download/<tag>/nanodictate-<ver>-macos-{arm64,x86_64}.tar.gz
#   3. computes sha256 for both binary tarballs (Homebrew formula) and
#      sha256/rmd160/size for the source tarball (MacPorts Portfile)
#   4. substitutes __VERSION__, __SHA256_ARM64__, __SHA256_X86_64__,
#      __SOURCE_SHA256__, __RMD160__, __SOURCE_SIZE__ in the .tpl files
#   5. writes packaging/homebrew/nanodictate.rb and packaging/macports/Portfile
#
# Stdlib only (open-uri, digest, openssl). No external gems.
#
# NOTE: this needs the GitHub Release to exist (with both tarballs attached),
# so it runs only after the release workflow has published a tag.

require "open-uri"
require "digest/sha2"
require "uri"

begin
  require "openssl"
rescue LoadError
  # rmd160 stays a placeholder if OpenSSL is unavailable.
end

TAG = ARGV[0]
unless TAG && TAG =~ /\Av?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/
  abort "Usage: ruby scripts/release-prep.rb v0.1.0   (tag may be '0.1.0' or 'v0.1.0')"
end

VERSION     = TAG.sub(/\Av/, "")
ROOT        = File.expand_path("..", __dir__)
TARBALL_URL = "https://github.com/kodmial/nanodictate/archive/refs/tags/#{TAG}.tar.gz"

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
rescue OpenSSL::SSL::SSLError, EOFError => e
  # TLS/connection-level failures, e.g. a TLS-intercepting firewall blocking
  # GitHub. Anything else (a script bug, an unexpected error class) is left to
  # propagate — aborting here would mislabel it as a download issue.
  abort network_blocked_msg(e)
end

# --- 1/2. Download the source tarball and both binary tarballs ---------------
src = download(TARBALL_URL, "source tarball")
arm = download(binary_url("arm64"), "arm64 binary tarball")
x86 = download(binary_url("x86_64"), "x86_64 binary tarball")

# --- 3. Checksums ------------------------------------------------------------
sha256_src    = Digest::SHA256.hexdigest(src)
size          = src.bytesize
rmd160 =
  begin
    OpenSSL::Digest.new("RMD160").hexdigest(src)
  rescue StandardError
    nil
  end
sha256_arm64  = Digest::SHA256.hexdigest(arm)
sha256_x86_64 = Digest::SHA256.hexdigest(x86)

# --- 4. Fill templates -------------------------------------------------------
values = {
  "__VERSION__"       => VERSION,                 # "0.1.0" (no leading v)
  "__SHA256_ARM64__"  => sha256_arm64,            # Homebrew formula, arm64 tarball
  "__SHA256_X86_64__" => sha256_x86_64,           # Homebrew formula, x86_64 tarball
  "__SOURCE_SHA256__" => sha256_src,              # MacPorts: source tarball
  "__SOURCE_SIZE__"   => size.to_s,
  "__RMD160__"        => rmd160 || "__RMD160__",  # stays a placeholder when unavailable
}

formula_tpl  = File.join(ROOT, "packaging", "homebrew", "nanodictate.rb.tpl")
formula_out  = File.join(ROOT, "packaging", "homebrew", "nanodictate.rb")
portfile_tpl = File.join(ROOT, "packaging", "macports", "Portfile.tpl")
portfile_out = File.join(ROOT, "packaging", "macports", "Portfile")

File.write(formula_out, filled_template(formula_tpl, values))
File.write(portfile_out, filled_template(portfile_tpl, values))

# --- 5. Report and instructions ----------------------------------------------
puts "Wrote:"
puts "  #{formula_out}"
puts "  #{portfile_out}"
puts "Checksums for #{TAG}:"
puts "  arm64 binary tarball   sha256  #{sha256_arm64}"
puts "  x86_64 binary tarball  sha256  #{sha256_x86_64}"
puts "  source tarball         sha256  #{sha256_src}"
puts "  source tarball         size    #{size}"
puts "  source tarball         rmd160  #{rmd160 || "N/A — fill via `port checksum` or leave the placeholder"}"
puts
puts "Next steps:"
puts "  1. Fill the maintainers handle in #{portfile_out} (never auto-generate a person's id)."
puts "  2. Sanity-check the version string: `nanodictate --version` will print \"nanodictate #{VERSION}\"."
puts "  3. Homebrew: copy #{formula_out} into the nanodictate-homebrew tap as"
puts "     Formula/nanodictate.rb, then run `brew audit --strict --new nanodictate` there."
puts "  4. MacPorts: copy #{portfile_out} into a macports-ports checkout as"
puts "     audio/nanodictate/Portfile, then run `port lint` before opening the PR."
puts "  5. Test a real install: `brew install nanodictate` and `port install`."