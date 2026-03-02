# ZD-2517039 — CentOS 7 yum curl#60 SSL Reproduction

## Issue

Datadog Agent installation on CentOS 7 fails with:

```
[Errno 14] curl#60 - "Peer's Certificate issuer is not recognized."
failure: repodata/repomd.xml from datadog: [Errno 256] No more mirrors to try.
```

Manual `curl https://yum.datadoghq.com/` succeeds while `yum install datadog-agent` fails.

## Root Cause

Datadog's yum repo (`yum.datadoghq.com`) uses a certificate signed by **DigiCert Global Root G2**.

On systems with an outdated CA bundle (old `ca-certificates` or `nss` package), DigiCert Global Root G2 may be missing. `yum` respects the `sslcacert=` directive in the repo file and can be pointed at a stale bundle, while the system `curl` command uses the full NSS built-in roots (`libnssckbi.so`) and succeeds.

## Requirements

- Docker

## Usage

```bash
bash reproduce.sh
```

## What It Does

1. Spins up a `centos:7` Docker container
2. Builds a degraded CA bundle (removes DigiCert Global Root G2 entry)
3. Configures Datadog yum repo with `sslcacert` pointing to degraded bundle
4. Shows manual `curl` succeeding while `yum` fails with `curl#60`
5. Runs diagnostic commands (`rpm -q ca-certificates nss openssl`)
6. Applies the fix (restores full CA bundle) and confirms `yum` succeeds

## Fix

```bash
# Update CA certificates and NSS trust store
yum update ca-certificates nss

# If behind an SSL-inspecting proxy, trust the proxy CA:
update-ca-trust enable
# copy proxy cert to /etc/pki/ca-trust/source/anchors/
update-ca-trust extract
```
