#!/bin/sh
# Runs before every Xcode Cloud build. Installs SwiftLint if missing and lints the source.
set -e

if ! command -v swiftlint &>/dev/null; then
  brew install swiftlint
fi

swiftlint --config "$CI_PRIMARY_REPOSITORY_PATH/wonni/.swiftlint.yml" \
          "$CI_PRIMARY_REPOSITORY_PATH/wonni/wonni/"
