#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d build/SourcePackages/checkouts ]]; then
  echo "missing build/SourcePackages/checkouts"
  exit 1
fi

SRC="/tmp/GRDB-src"
if [[ ! -f "$SRC/Package.swift" ]]; then
  SRC="build/SourcePackages/checkouts/GRDB.swift"
fi
if [[ ! -f "$SRC/Package.swift" ]]; then
  echo "GRDB source missing: /tmp/GRDB-src or build/SourcePackages/checkouts/GRDB.swift"
  exit 1
fi

PBX="/tmp/app_handoff.pbxproj"
RESOLVED="/tmp/app_handoff.Package.resolved"
LOG="/tmp/app_handoff_build.log"
cp APP.xcodeproj/project.pbxproj "$PBX"
cp APP.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved "$RESOLVED"

restore() {
  cd "$ROOT"
  cp "$PBX" APP.xcodeproj/project.pbxproj
  cp "$RESOLVED" APP.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  rm -rf VendorLocal
  sed -i '' '/^VendorLocal\/$/d' .git/info/exclude 2>/dev/null || true
}
trap restore EXIT

rm -rf VendorLocal
mkdir -p VendorLocal/GRDB.swift
rsync -a --exclude '.git' --exclude '.gitmodules' --exclude 'SQLiteCustom' "$SRC/" VendorLocal/GRDB.swift/

ruby - <<'RUBY'
require "xcodeproj"
project = Xcodeproj::Project.open("APP.xcodeproj")
remote = project.objects_by_uuid["D6A1B2C3D4E5F60718293003"]
abort "GRDB remote package reference missing" unless remote
local = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local.relative_path = "VendorLocal/GRDB.swift"
project.root_object.package_references << local
project.targets.each do |target|
  target.package_product_dependencies.each do |dependency|
    dependency.package = local if dependency.package == remote
  end
end
project.root_object.package_references.delete(remote)
project.save
RUBY

python3 - <<'PY'
import json
path = "APP.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
data = json.load(open(path))
data["pins"] = [pin for pin in data["pins"] if pin.get("identity") != "grdb.swift"]
json.dump(data, open(path, "w"), indent=2)
PY

grep -q "VendorLocal" .git/info/exclude 2>/dev/null || echo "VendorLocal/" >> .git/info/exclude

xcodebuild \
  -project APP.xcodeproj \
  -scheme APP \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build > "$LOG" 2>&1

echo "BUILD_OK"
