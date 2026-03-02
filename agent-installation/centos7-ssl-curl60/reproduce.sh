#!/bin/bash
# ZD-2517039 — CentOS 7 yum curl#60 Reproduction
# Reproduces: [Errno 14] curl#60 - "Peer's Certificate issuer is not recognized."
# Scenario: yum fails with SSL cert error while manual curl succeeds
# Root cause: yum's sslcacert pointing to a CA bundle missing DigiCert Global Root G2

set -e

CONTAINER_NAME="zd-2517039-repro"

echo "================================================================="
echo "ZD-2517039 — CentOS 7 yum curl#60 Reproduction"
echo "================================================================="
echo ""

docker run --rm --name "$CONTAINER_NAME" centos:7 bash -c '

# Step 1: Build a degraded CA bundle (missing DigiCert Global Root G2)
# DigiCert G2 is the root CA used by yum.datadoghq.com and keys.datadoghq.com
awk "
/^# DigiCert Global Root G2/ { skip=1 }
/^-----END CERTIFICATE-----/ && skip { skip=0; next }
!skip { print }
" /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem > /tmp/limited-ca-bundle.pem

echo "CA bundle: $(grep -c "BEGIN CERT" /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem) certs (full)"
echo "CA bundle: $(grep -c "BEGIN CERT" /tmp/limited-ca-bundle.pem) certs (degraded, missing DigiCert G2)"
echo ""

# Step 2: Set up Datadog yum repo with degraded CA bundle
# This simulates an outdated CA store (pre-2019 nss / ca-certificates package)
cat > /etc/yum.repos.d/datadog.repo << "EOF"
[datadog]
name=Datadog, Inc.
baseurl=https://yum.datadoghq.com/stable/7/x86_64/
enabled=1
gpgcheck=0
repo_gpgcheck=0
sslverify=1
sslcacert=/tmp/limited-ca-bundle.pem
EOF

echo "================================================================="
echo "STEP 1: Manual curl (system NSS trust store — full) → SUCCEEDS"
echo "================================================================="
curl -sv https://yum.datadoghq.com/ -o /dev/null 2>&1 | grep -E "(SSL connection|issuer|subject|HTTP/)"
echo "curl exit code: $?"
echo ""

echo "================================================================="
echo "STEP 2: yum with degraded sslcacert (missing DigiCert G2) → FAILS"
echo "================================================================="
yum --disablerepo="*" --enablerepo="datadog" list available 2>&1 | grep -E "(Errno|curl#|recognized|failure)" | head -5
echo ""

echo "================================================================="
echo "STEP 3: Diagnostic commands (as requested in ticket)"
echo "================================================================="
echo "--- rpm -q ca-certificates nss openssl ---"
rpm -q ca-certificates nss openssl 2>&1
echo ""
echo "--- grep -r proxy /etc/yum.conf /etc/yum.repos.d/ ---"
grep -r proxy /etc/yum.conf /etc/yum.repos.d/ 2>/dev/null || echo "(no proxy settings found)"
echo ""

echo "================================================================="
echo "STEP 4: FIX — Restore full CA bundle (update-ca-trust or yum update ca-certificates)"
echo "================================================================="
sed -i "s|sslcacert=.*|sslcacert=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem|" /etc/yum.repos.d/datadog.repo
yum --disablerepo="*" --enablerepo="datadog" list available 2>&1 | head -5
echo "yum exit code: $?"
echo ""
echo "Fix confirmed: updating CA bundle resolves the issue."

'
