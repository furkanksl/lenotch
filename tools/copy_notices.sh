#!/bin/bash
# Run from the repository root after swift build; paths match the macOS app's resolved graph.
set -euo pipefail

resources=$1
sparkle_root=$2
licenses="$resources/Third-Party-Licenses"

copy_notice() {
  local source=$1 destination="$licenses/$2"
  if [[ ! -f "$source" || ! -s "$source" ]]; then
    printf 'error: missing or empty third-party notice: %s\n' "$source" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
}

cp Resources/Third-Party-Notices.md "$resources/"
copy_notice Resources/Hugeicons-LICENSE.txt Hugeicons-LICENSE.txt
copy_notice Resources/Interspace-LICENSE.txt Interspace-LICENSE.txt
copy_notice Resources/InstantSpaceSwitcher-LICENSE.txt InstantSpaceSwitcher-LICENSE.txt
if [[ -f "$resources/mediaremote-adapter.pl" ]]; then
  copy_notice Vendor/mediaremote-adapter/LICENSE mediaremote-adapter/LICENSE
fi
copy_notice "$sparkle_root/LICENSE" Sparkle/LICENSE

# Use an explicit list: the app links static libraries too, while whole checkouts
# contain build tools and optional code (e.g. FluidAudio's eSpeak) that do not ship.
# SwiftSyntax builds a macro plugin; MLX's disabled FoundationModelsIntegration
# trait would bring in XGrammar. CryptoExtras (SwiftASN1 and BoringSSL) is unused.
# Review this list when updating packages, enabling traits, or adding app targets.
for notice in \
  EventSource/LICENSE.md \
  FluidAudio/LICENSE \
  FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md \
  FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md \
  mlx-swift/LICENSE \
  mlx-swift/ACKNOWLEDGMENTS.md \
  mlx-swift/Source/Cmlx/fmt/LICENSE \
  mlx-swift/Source/Cmlx/json/LICENSE.MIT \
  mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt \
  mlx-swift/Source/Cmlx/mlx/LICENSE \
  mlx-swift/Source/Cmlx/mlx-c/LICENSE \
  mlx-swift-lm/LICENSE \
  mlx-swift-lm/ACKNOWLEDGMENTS.md \
  swift-collections/LICENSE.txt \
  swift-crypto/LICENSE.txt \
  swift-crypto/NOTICE.txt \
  swift-huggingface/LICENSE \
  swift-jinja/LICENSE \
  swift-numerics/LICENSE.txt \
  swift-transformers/LICENSE \
  yyjson/LICENSE; do
  copy_notice ".build/checkouts/$notice" "$notice"
done
