#!/bin/sh
# Runs before every Xcode Cloud build. Installs SwiftLint if missing and lints the source.
# Violations are reported as Xcode warnings but do not fail the build (|| true).
# Remove "|| true" once the codebase has zero SwiftLint errors.
set -e

if ! command -v swiftlint &>/dev/null; then
  brew install swiftlint
fi

swiftlint lint \
  --config "$CI_PRIMARY_REPOSITORY_PATH/wonni/.swiftlint.yml" \
  --reporter xcode \
  "$CI_PRIMARY_REPOSITORY_PATH/wonni/wonni/" || true
