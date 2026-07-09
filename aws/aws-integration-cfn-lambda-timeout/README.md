# AWS Integration CloudFormation template — custom resource Lambda hits hard 5s timeout, hangs stack for ~60 minutes

## Context

The Datadog AWS Integration can be installed/updated via a CloudFormation
template (`aws_attach_integration_permissions/main.yaml` in
[`DataDog/cloudformation-template`](https://github.com/DataDog/cloudformation-template)).
This template deploys a custom-resource Lambda,
`DatadogAttachIntegrationPermissionsFunction` (custom resource logical ID
`DatadogAttachIntegrationPermissionsFunctionTrigger`), which sequentially
attaches the Datadog-required IAM managed policies to the integration role.

That Lambda has a **hardcoded `Timeout: 5`** (seconds) in its
`AWS::Lambda::Function` definition:

```53:60:aws_attach_integration_permissions/main.yaml
  DatadogAttachIntegrationPermissionsFunction:
    Type: AWS::Lambda::Function
    Properties:
      Description: "A function to attach Datadog AWS integration permissions to an IAM role."
      Role: !GetAtt DatadogAttachIntegrationPermissionsFunctionRole.Arn
      Runtime: python3.12
      Timeout: 5
      Handler: index.handler
```

Datadog's own Lambda already needs to attach **7 managed policies** by
itself (`SecurityAudit` + 6 split
`datadog-aws-integration-iam-permissions-*-partN` policies) before the
customer adds anything of their own. AWS enforces a **hard limit of 10
managed policies per IAM role**. Once the role's policy count gets close to
(or hits) that limit — or simply because the sequential `AttachRolePolicy`
API calls take a bit longer than usual — the Lambda cannot finish within
5 seconds and is killed by the Lambda runtime **mid-execution**, before it
can send its `SUCCESS`/`FAILED` signal back to CloudFormation.

Because this happens inside a CloudFormation **custom resource**,
CloudFormation doesn't see an immediate error — it just waits for a
callback that never arrives, and the stack sits in `CREATE_IN_PROGRESS`
until CloudFormation's own custom-resource wait window (~60 minutes)
expires and rolls it back.

This sandbox reproduces the bug end-to-end in a real AWS account: a fresh
run that only barely survives the timeout, a run that hits `LimitExceeded`
and just manages to report `FAILED` in time, a run that gets killed
mid-flight exactly like the customer described, **and a verified fix run**
proving a one-line patch resolves it completely.

**Known reports:**
- Reported independently by two customers so far: this Zendesk case (root
  cause self-diagnosed by the customer with their own CloudWatch evidence)
  and an earlier, separately resolved case with the identical signature.
- **Fix status:** an external community contributor opened
  [PR #309](https://github.com/DataDog/cloudformation-template/pull/309)
  ("Increase Lambda timeout from 5 to 300 seconds"), filed 2026-05-17.
  As of this writing it is **still open / not merged**, untriaged (no
  reviewer, no assignee, no labels). **The fix itself has been independently
  verified in this sandbox — see "Run 4" below — so a locally patched
  template can be used immediately without waiting for the PR to merge.**

## Environment

- **Template:** `aws_attach_integration_permissions/main.yaml`
- **Repo:** [`DataDog/cloudformation-template`](https://github.com/DataDog/cloudformation-template) (public)
- **Lambda runtime:** `python3.12`
- **Datadog Site:** not site-specific — the bug is in the CloudFormation template logic itself, independent of which Datadog org/site is being integrated

## Schema

```mermaid
sequenceDiagram
    participant CFN as CloudFormation
    participant Lambda as DatadogAttachIntegrationPermissionsFunction
    participant IAM as AWS IAM

    CFN->>Lambda: Invoke (Create/Update custom resource)
    Note over Lambda: Hard Timeout: 5s
    loop For each required managed policy
        Lambda->>IAM: AttachRolePolicy
        IAM-->>Lambda: OK / LimitExceeded
    end
    alt Finishes < 5s
        Lambda->>CFN: cfn-response SUCCESS/FAILED (HTTP PUT)
    else Exceeds 5s
        Note over Lambda: Killed by Lambda runtime timeout
        Lambda--xCFN: no response ever sent
        Note over CFN: CREATE_IN_PROGRESS for ~60 min, then rollback
    end
```

## Quick Start

These steps reproduce the bug in any AWS sandbox account. Replace
`ACCOUNT_ID` and role/stack names as needed.

### 1. Download the live template

```bash
mkdir -p /tmp/cfn-lambda-timeout-repro && cd /tmp/cfn-lambda-timeout-repro
gh api repos/DataDog/cloudformation-template/contents/aws_attach_integration_permissions/main.yaml \
  --jq '.content' | base64 -d > main.yaml
grep -n -A2 "Timeout:" main.yaml   # confirm it still shows "Timeout: 5"
```

### 2. Create a test IAM role with headroom already consumed

Datadog's Lambda needs 7 slots (`SecurityAudit` + 6 split permission
policies). Attach enough *other* policies first to push the total over
AWS's 10-per-role ceiling once the Lambda's own policies are added:

```bash
ROLE_NAME="DatadogIntegrationRole-repro"
ACCOUNT_ID="<your-sandbox-account-id>"

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::464622532012:root"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:ExternalId": "<your-external-id>"}}
    }]
  }'

for POLICY_ARN in \
  arn:aws:iam::aws:policy/ReadOnlyAccess \
  arn:aws:iam::aws:policy/job-function/ViewOnlyAccess \
  arn:aws:iam::aws:policy/AWSSupportAccess \
  arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  arn:aws:iam::aws:policy/SecurityAudit ; do
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
done
```

This leaves only 5 of the 10 slots free — not enough for the Lambda's 7
required policies, guaranteeing it hits `LimitExceeded` partway through
its attachment loop.

### 3. Deploy the CloudFormation stack against that role

```bash
aws cloudformation create-stack \
  --stack-name cfn-lambda-timeout-repro \
  --template-body file://main.yaml \
  --parameters \
      ParameterKey=DatadogIntegrationRole,ParameterValue="$ROLE_NAME" \
      ParameterKey=AccountId,ParameterValue="$ACCOUNT_ID" \
  --capabilities CAPABILITY_IAM

# Poll status — do NOT wait the full hour, the Lambda logs (step 4) tell you
# everything within seconds of the invocation finishing.
watch -n 10 'aws cloudformation describe-stacks \
  --stack-name cfn-lambda-timeout-repro \
  --query "Stacks[0].StackStatus" --output text'
```

### 4. Watch the Lambda's own CloudWatch logs

```bash
FN_NAME=$(aws cloudformation describe-stack-resource \
  --stack-name cfn-lambda-timeout-repro \
  --logical-resource-id DatadogAttachIntegrationPermissionsFunction \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)

aws logs tail "/aws/lambda/$FN_NAME" --since 5m --follow
```

## Test Commands / Evidence captured

Four sandbox runs, escalating conditions, show the full spectrum of this
bug — and confirm the fix:

**Run 1 — fresh role, zero pre-existing policies (best case):**
The Lambda *succeeds*, but only just — `Duration: 4966.937 ms` against the
hard `5000ms` limit. Even the happy path has almost no margin.

**Run 2 — role pushed to the policy quota:**
The Lambda catches IAM's `LimitExceeded` and manages to send its `FAILED`
response just **35ms** before the hard kill:
- `Duration: 4964.906 ms`
- `Billed Duration: 5687 ms` (note the gap vs. actual duration — overhead
  from the `cfn-response` HTTP PUT itself eating into the remaining budget)

**Run 3 — same setup, retried — the literal customer-reported hang:**
This is a byte-for-byte match of the reported symptom, captured directly
from the Lambda's platform telemetry:

```json
{"time":"2026-07-09T06:05:50.562Z","type":"platform.runtimeDone","record":{"requestId":"aec7a529-47f9-4090-be01-c9ed91bf83cf","status":"timeout","metrics":{"durationMs":5001.182,"producedBytes":0}}}
{"time":"2026-07-09T06:05:50.581Z","type":"platform.report","record":{"requestId":"aec7a529-47f9-4090-be01-c9ed91bf83cf","metrics":{"durationMs":5000.0,"billedDurationMs":5000,"memorySizeMB":128,"maxMemoryUsedMB":94},"status":"timeout"}}
```

`"status":"timeout"` on both the `runtimeDone` and `report` records
confirms the Lambda **runtime itself** killed the invocation — it is not
an application-level exception. No `cfn-response` PUT was ever sent, so
CloudFormation received nothing and the stack sat in `CREATE_IN_PROGRESS`
indefinitely (verified directly — no `StatusReason`, no forward progress —
then manually deleted rather than waiting out the full ~60-minute window).

**Run 4 — fix verification: same official template, `Timeout: 5` → `300`, otherwise byte-for-byte identical:**
Deployed against a role matching a real customer's exact reported condition
(2 pre-existing policies, `ReadOnlyAccess` + `ViewOnlyAccess`, after they'd
manually detached everything else to free up quota headroom):

```json
{"time":"2026-07-09T09:59:05.883Z","type":"platform.report","record":{"requestId":"91a84db4-9215-4ea8-ade4-d5f24e9c6e79","metrics":{"durationMs":5622.492,"billedDurationMs":6322,"memorySizeMB":128,"maxMemoryUsedMB":97,"initDurationMs":698.806},"status":"success"}}
```

- Stack reached `CREATE_COMPLETE` in ~30 seconds (vs. a ~60-minute hang).
- **`durationMs: 5622.492`** — notably *longer* than the original hard
  5000ms limit, confirming there was never a safe execution margin at 5s,
  independent of whether `LimitExceeded` is hit.
- All 9 expected policies verified attached on the role afterward: the 2
  pre-existing + `SecurityAudit` + all 6
  `datadog-aws-integration-iam-permissions-*-partN` policies.
- Conclusion: **this is confirmed to be solely a timeout-value problem.**
  A locally patched template (only `Timeout: 5` → `300` changed, otherwise
  the current official file) is a complete, working fix — it does **not**
  require PR #309 to merge upstream first. The PR merging only matters for
  the long-term fix so future installs don't need a manual patch.

## Expected vs Actual

| | Expected | Actual |
|---|---|---|
| Lambda execution | Completes all `AttachRolePolicy` calls within timeout, returns `SUCCESS`/`FAILED` to CloudFormation | Killed by the Lambda runtime at the hard 5000ms mark before it can respond |
| Stack behavior on failure | Fails fast with a clear `CREATE_FAILED` / `ResourceStatusReason` | Hangs silently in `CREATE_IN_PROGRESS` for up to ~60 minutes, then rolls back with no actionable reason |
| Margin for error | Comfortable buffer for sequential IAM API calls | Razor-thin even on a *fresh* role with zero pre-existing policies (4.97s of a 5.0s budget) — and confirmed insufficient even at 5.6s total workload (Run 4) |

## Fix / Workaround

### Fix (upstream, not yet merged — but independently verified, see Run 4 above)

[PR #309](https://github.com/DataDog/cloudformation-template/pull/309)
bumps `Timeout: 5` to `Timeout: 300` on the same Lambda resource. The
author's own testing notes independently corroborate this reproduction:
*"During testing, the Lambda consistently timed out at 5 seconds, causing
the CloudFormation stack to fail... Previous tests with 5-second timeout
consistently failed."*

**This sandbox independently re-verified the same fix** by patching the
current official template directly (not the contributor's fork) and
deploying it against a role matching a real reported failure condition —
see Run 4. Confirmed: a locally patched template works today, without
waiting for the PR to merge.

### Immediate workaround — deploy a locally patched template (recommended, verified)

1. Fetch the current official template and change only `Timeout: 5` to
   `Timeout: 300` on the `DatadogAttachIntegrationPermissionsFunction`
   resource — nothing else needs to change.
2. Deploy that patched file in place of the original via
   `create-stack`/`update-stack` — same parameters as usual.
3. Once PR #309 (or an equivalent internal fix) merges upstream, switch
   back to the standard template on your next update.

### Alternative workaround — manual IAM policy attachment (works, but doesn't fix CFN stack status)

1. Let the stuck stack fail/roll back, or delete it manually rather than
   waiting the full ~60 minutes.
2. Manually attach the remaining required Datadog-managed IAM policies to
   the integration role:
   ```bash
   aws iam attach-role-policy --role-name <role> --policy-arn <policy-arn>
   ```
   (repeat for each Datadog-required policy that wasn't attached before
   the Lambda was killed)
3. Re-verify the AWS integration in Datadog — it picks up correctly once
   all required policies are present, without needing the CloudFormation
   resource itself to report success.

### What does NOT work (confirmed by a real customer report)

- **Reducing pre-existing policy count alone** — even a completely fresh
  role with zero pre-existing policies is not safe (Run 1: 4966.937ms of
  5000ms budget; Run 4 confirms real-world runs can take 5.6s+). The
  bottleneck is the total sequential workload (Datadog API fetch + create
  6 policies + attach 7 policies), not solely the IAM quota.
- **Increasing the Lambda's timeout in the console/CLI *after* stack
  creation has already started** — CloudFormation's initial invocation is
  already in-flight using the 5-second config baked in at Lambda creation
  time; a runtime config edit does not retroactively affect an in-flight
  invocation. The template itself must be patched *before* deployment.

## Cleanup

```bash
aws cloudformation delete-stack --stack-name cfn-lambda-timeout-repro
aws cloudformation wait stack-delete-complete --stack-name cfn-lambda-timeout-repro

for POLICY_ARN in \
  arn:aws:iam::aws:policy/ReadOnlyAccess \
  arn:aws:iam::aws:policy/job-function/ViewOnlyAccess \
  arn:aws:iam::aws:policy/AWSSupportAccess \
  arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  arn:aws:iam::aws:policy/SecurityAudit ; do
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" || true
done
aws iam delete-role --role-name "$ROLE_NAME"
rm -rf /tmp/cfn-lambda-timeout-repro
```

Note: the Lambda's own `Delete` handler cleans up the 6
`datadog-aws-integration-iam-permissions-*-partN` policies automatically on
stack deletion, but does **not** detach `SecurityAudit` — detach that one
manually before deleting the role, or `delete-role` will fail with
`DeleteConflict`.

## References

- [`DataDog/cloudformation-template`](https://github.com/DataDog/cloudformation-template) — source repo
- [`aws_attach_integration_permissions/main.yaml`](https://github.com/DataDog/cloudformation-template/blob/master/aws_attach_integration_permissions/main.yaml) — file containing the hardcoded `Timeout: 5`
- [PR #309 — "fix: Increase Lambda timeout from 5 to 300 seconds"](https://github.com/DataDog/cloudformation-template/pull/309) — open, unmerged fix, independently re-verified in this sandbox (Run 4)
- [AWS IAM quotas — managed policies per role (10)](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html)
- [AWS Lambda function timeout configuration](https://docs.aws.amazon.com/lambda/latest/dg/configuration-timeout.html)
- [CloudFormation custom resources — response objects](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/crpg-ref-responses.html)
