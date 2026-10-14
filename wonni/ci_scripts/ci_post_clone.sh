#!/bin/sh
# Regenerates Secrets.xcconfig from Xcode Cloud environment variables.
# Add EBAY_CLIENT_ID, EBAY_RUNAME, ETSY_CLIENT_ID as secret env vars
# in the Xcode Cloud workflow: Environment → Environment Variables → Secret ✓
set -e

SECRETS_PATH="$CI_PRIMARY_REPOSITORY_PATH/wonni/wonni/Secrets.xcconfig"

cat > "$SECRETS_PATH" << EOF
EBAY_CLIENT_ID = ${EBAY_CLIENT_ID}
EBAY_RUNAME = ${EBAY_RUNAME}
ETSY_CLIENT_ID = ${ETSY_CLIENT_ID}
EOF

echo "Secrets.xcconfig written to $SECRETS_PATH"

# Build number = UTC minute stamp, shared with .github/workflows/testflight.yml
# and scripts/testflight.sh so every uploader is on one monotonic sequence.
# Xcode Cloud's own CI_BUILD_NUMBER restarts from its own counter and a rebuild
# reuses it, which is what produced "The bundle version must be higher than the
# previously uploaded version" for build 180 (2026-10-14).
cd "$CI_PRIMARY_REPOSITORY_PATH/wonni"
agvtool new-version -all "$(date -u +%Y%m%d%H%M)"
