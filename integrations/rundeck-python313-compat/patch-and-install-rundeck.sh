#!/bin/bash
# patch-and-install-rundeck.sh
#
# Workaround: installs datadog-rundeck==1.1.0 on Agent < 7.72 (Python 3.12)
# by patching the wheel's version constraints before installing.
#
# UNSUPPORTED — use at your own risk. Upgrade to Agent 7.72+ when possible.
#
# Usage: run this script on the host where the Datadog Agent is installed,
# as the same user that runs the agent (or with sudo).

set -euo pipefail

AGENT_PIP="/opt/datadog-agent/embedded/bin/pip3"
AGENT_PYTHON="/opt/datadog-agent/embedded/bin/python3"
AGENT_BIN="/opt/datadog-agent/bin/agent/agent"
WORK=$(mktemp -d)
WHEEL_NAME="datadog_rundeck-1.1.0-py3-none-any.whl"
WHEEL_CACHE="/opt/datadog-agent/embedded/lib/python3.12/site-packages/datadog_checks/downloader/data/repo/targets/simple/datadog-rundeck/${WHEEL_NAME}"

echo "[1/4] Triggering agent downloader to cache the wheel..."
"$AGENT_BIN" integration install -t datadog-rundeck==1.1.0 --allow-root 2>&1 || true

if [ ! -f "$WHEEL_CACHE" ]; then
    echo "ERROR: Wheel not found at $WHEEL_CACHE — did the download fail?"
    exit 1
fi

echo "[2/4] Patching wheel constraints..."
cp "$WHEEL_CACHE" "$WORK/$WHEEL_NAME"

"$AGENT_PYTHON" - <<PYEOF
import zipfile, os

work = '${WORK}'
extracted = os.path.join(work, 'extracted')
os.makedirs(extracted, exist_ok=True)

with zipfile.ZipFile(f'{work}/${WHEEL_NAME}', 'r') as z:
    z.extractall(extracted)

meta_path = f'{extracted}/datadog_rundeck-1.1.0.dist-info/METADATA'
with open(meta_path) as f:
    content = f.read()

content = content.replace('Requires-Python: >=3.13', 'Requires-Python: >=3.12')
content = content.replace('datadog-checks-base>=37.21.0', 'datadog-checks-base>=37.20.0')

with open(meta_path, 'w') as f:
    f.write(content)

patched = f'{work}/datadog_rundeck-1.1.0-py312-none-any.whl'
with zipfile.ZipFile(patched, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(extracted):
        for file in files:
            filepath = os.path.join(root, file)
            arcname = os.path.relpath(filepath, extracted)
            z.write(filepath, arcname)

print(f'Patched wheel ready: {patched}')
PYEOF

echo "[3/4] Installing patched wheel..."
"$AGENT_PIP" install --force-reinstall "$WORK/datadog_rundeck-1.1.0-py312-none-any.whl" --no-deps

echo "[4/4] Verifying..."
"$AGENT_PYTHON" -c 'from datadog_checks.rundeck import RundeckCheck; print("Import OK:", RundeckCheck)'
"$AGENT_PIP" show datadog-rundeck | grep -E "^(Name|Version|Location)"

echo ""
echo "Done. Restart the agent and run: datadog-agent check rundeck"
echo "Remember: this is unsupported. Upgrade to Agent 7.72+ when possible."

rm -rf "$WORK"
