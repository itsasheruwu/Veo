#!/bin/zsh

set -euo pipefail
export COPYFILE_DISABLE=1

script_dir="${0:A:h}"
project_root="${script_dir:h}"
derived_data="${VEO_RELEASE_DERIVED_DATA:-/tmp/veo-release-derived}"
output_dir="${VEO_RELEASE_OUTPUT_DIR:-${project_root}/dist}"

version="$(xcodebuild \
  -project "${project_root}/Veo.xcodeproj" \
  -scheme Veo \
  -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk '/MARKETING_VERSION =/ { print $3; exit }')"

if [[ -z "$version" ]]; then
  print -u2 "Could not determine Veo's marketing version."
  exit 1
fi

mkdir -p "$output_dir"

built_app_path="${derived_data}/Build/Products/Release/Veo.app"
dmg_path="${output_dir}/Veo-${version}-macOS-universal.dmg"
pkg_path="${output_dir}/Veo-${version}-macOS-universal.pkg"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/veo-release.XXXXXX")"
signing_dir="$(mktemp -d "${TMPDIR:-/tmp}/veo-signing.XXXXXX")"
app_path="${staging_dir}/Veo.app"
signing_app_path="${signing_dir}/Veo.app"

cleanup() {
  /bin/rm -rf "$staging_dir"
  /bin/rm -rf "$signing_dir"
}
trap cleanup EXIT

xcodebuild \
  -project "${project_root}/Veo.xcodeproj" \
  -scheme Veo \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -destination "generic/platform=macOS" \
  build \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

ditto --noextattr --noqtn "$built_app_path" "$signing_app_path"

codesign \
  --force \
  --deep \
  --sign - \
  --options runtime \
  --timestamp=none \
  "$signing_app_path"

codesign --verify --deep --strict --verbose=2 "$signing_app_path"
ditto --noextattr --noqtn "$signing_app_path" "$app_path"

ln -s /Applications "${staging_dir}/Applications"

hdiutil create \
  -volname "Veo ${version}" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$dmg_path"

pkgbuild \
  --component "$app_path" \
  --install-location /Applications \
  --identifier com.ash.Veo.installer \
  --version "$version" \
  --ownership recommended \
  "$pkg_path"

pkgutil --check-signature "$pkg_path" || true
hdiutil verify "$dmg_path"

file "$app_path/Contents/MacOS/Veo"
shasum -a 256 "$dmg_path" "$pkg_path"

print "Created:"
print "  $dmg_path"
print "  $pkg_path"
