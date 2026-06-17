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
