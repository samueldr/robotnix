#!/usr/bin/env nix-shell
#!nix-shell -p ruby nix nix-prefetch-git -i ruby

require "fileutils"
require "json"
require "open-uri"
require "open3"
require "shellwords"

def get(uri)
  URI.open(uri).read
end

BRANCH = ARGV.shift
OEM = ARGV.shift
DEVICE = ARGV.shift

REMOTES = {
  "gh" => "https://github.com",
}

REMOTES_RAW = {
  "gh" => "https://raw.githubusercontent.com",
}

def to_json(obj)
  JSON.pretty_generate(obj)
end

def get_deps(repository, ref, remote: "gh")
  deps = []
  begin
  curr_deps = JSON.parse(get([
    REMOTES_RAW[remote],
    repository,
    ref,
    "carbon.dependencies",
  ].join("/")))
  rescue OpenURI::HTTPError => e
    $stderr.puts("No dependencies declared for #{repository}...")
    return []
  end

  curr_deps.each do |dep|
    revision = dep["revision"]
    revision ||= ref
    deps += get_deps(dep["repository"], revision)
  end
end

def get_all_deps()
  repository = [
    "CarbonROM",
    "android_device_" + [OEM, DEVICE].join("_"),
  ].join("/")

  [{
    "repository" => repository,
    "target_path" => ["device", OEM, DEVICE].join("/"),
  }] +
  get_deps(
    repository,
    BRANCH,
  )
end

# Wrong parsing of makefile metadata...
def parse_mk(contents)
  parsed = contents
    .gsub(/\s*#.*/, "")                           # First remove all comments
    .split(/\n+/)                                 # Get lines
    .select { |line| line.match(/[A-Z_]\s*:=/) }  # Keep assignations
    .map { |line| line.split(/\s*:=\s*/) }        # KEY := Value -> ["KEY", "Value"]
    .to_h
end

def device_metadata(deps)
  repository = [
    "CarbonROM",
    "android_device_" + [OEM, DEVICE].join("_"),
  ].join("/")

  data = parse_mk(get("https://github.com/#{repository}/raw/#{BRANCH}/carbon_#{DEVICE}.mk"))

  {
    branch: BRANCH,
    deps: deps.map { |dep| dep["repository"].split("/").last },
    name: data["PRODUCT_MODEL"],
    oem: data["PRODUCT_MANUFACTURER"],
    variant: "user",
  }
end

def prefetch_repo(repository, ref: nil, remote: nil)
  ref ||= BRANCH
  remote ||= "gh"
  url = "#{REMOTES[remote]}/#{repository}.git"
  stdout, status = Open3.capture2("nix-prefetch-git", "--url", url, "--branch-name", ref)
  JSON.parse(stdout)
end

device_deps = get_all_deps
metadata = device_metadata(device_deps)

base = File.join(__dir__(), "devices")
FileUtils.mkdir_p(base)
File.write(File.join(base, "#{DEVICE}.json"), to_json(metadata))
File.write(File.join(base, "#{DEVICE}_flattened_dependencies.json"), to_json(device_deps))

device_dirs = device_deps.map do |dep|
  info = prefetch_repo(dep["repository"], ref: dep["revision"], remote: dep["remote"])
  [dep["target_path"], info]
end.to_h

File.write(File.join(base, "#{DEVICE}_dirs.json"), to_json(device_dirs))
