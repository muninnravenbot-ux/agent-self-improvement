#!/bin/bash
# examples/minimal-setup.sh — Create a minimal demo repo for testing the loop.
#
# This sets up a tiny git repo with a simple Node/TypeScript app, pre-loads
# example signals, and configures the loop for dry-run testing.

set -uo pipefail

DEMO_REPO="/tmp/demo-agent-repo"
DEMO_STAGING="/tmp/demo-agent-staging"

echo "Setting up minimal demo..."

# Create demo repo.
rm -rf "$DEMO_REPO" "$DEMO_STAGING"
mkdir -p "$DEMO_REPO" "$DEMO_STAGING"
cd "$DEMO_REPO"

git init
git config user.email "demo@example.com"
git config user.name "Demo Agent"

# Create minimal package.json.
cat > package.json << 'EOF'
{
  "name": "demo-agent",
  "version": "0.1.0",
  "main": "src/main.ts",
  "scripts": {
    "build": "tsc --noEmit && echo 'Build OK'"
  },
  "dependencies": {}
}
EOF

# Create minimal TypeScript source.
mkdir -p src
cat > src/main.ts << 'EOF'
// Demo agent app
const VERSION = "0.1.0";

async function main() {
  console.log(`Demo agent v${VERSION} running`);
}

main().catch(console.error);
EOF

# Create tsconfig.json.
cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "lib": ["ES2020"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules"]
}
EOF

# Create a dummy error log.
mkdir -p logs
cat > logs/error.log << 'EOF'
2024-06-09 10:15:22 ERROR Handler panicked on nil pointer
2024-06-09 10:16:45 ERROR Timeout waiting for API response
2024-06-09 10:17:12 ERROR Memory spike detected
EOF

# Create observations (memory).
cat > observations.md << 'EOF'
🔴 2024-06-09 10:15 — Handler nil pointer panic occurred in request loop; needs null check [source:error-log]
🟡 2024-06-08 15:30 — API rate limiting causes cascading timeout failures; exponential backoff recommended [source:design-review]
🟢 2024-06-01 12:00 — Architecture uses Node event emitter pattern for async dispatch [source:audit]
EOF

# Initial commit.
git add .
git commit -m "Initial demo agent" >/dev/null

echo "Demo repo created at: $DEMO_REPO"
echo "Demo staging dir:     $DEMO_STAGING"
echo ""
echo "To run the loop with this demo:"
echo "  export REPO_PATH=$DEMO_REPO"
echo "  export STAGING_DIR=$DEMO_STAGING"
echo "  export AGENT_ERROR_LOG=$DEMO_REPO/logs/error.log"
echo "  export MEMORY_FILE=$DEMO_REPO/observations.md"
echo "  export BUILD_CMD='npm run build'"
echo "  export DRY_RUN=1"
echo "  cd /path/to/agent-self-improvement && bash src/self-improve.sh"
