# Automating AWS Backup failure investigations with Amazon DevOps Agent

*Anil Kukkunur, Solutions Architect, AWS*

When managing backups across dozens or hundreds of accounts in [AWS Organizations](https://aws.amazon.com/organizations/), investigating failed backup jobs can be time-consuming. Each failure might involve different root causes—from [AWS KMS](https://aws.amazon.com/kms/) key access issues to misconfigured IAM policies—and tracing the problem across accounts requires context-switching and manual log analysis.

In this post, I show you how to build an automated investigation pipeline that detects failed backup and copy jobs across your entire organization and uses [Amazon DevOps Agent](https://aws.amazon.com/devops-agent/) to autonomously perform root cause analysis, delivering findings directly to your team's Slack channel.

**Content level:** 300 – Advanced

**Time to deploy:** ~10 minutes

## Overview

[AWS Backup](https://aws.amazon.com/backup/) is a fully managed backup service that centralizes and automates data protection across AWS services. When you designate a delegated administrator account, you gain cross-account visibility into backup jobs across your organization.

This solution takes that visibility a step further: when any backup or copy job fails in any member account, an automated investigation is triggered and root cause analysis is delivered to Slack within minutes—without human intervention.

## Architecture

The solution uses a two-account deployment model: a one-time setup in the management account, and a single deployment script in the delegated admin that handles everything else—including automatic rollout to all member accounts via [AWS CloudFormation StackSets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/what-is-cfnstacksets.html).

![Architecture diagram](architecture-diagram.png)

*Figure 1: End-to-end architecture for automated backup failure investigation*

The flow works as follows:

1. A backup or copy job fails in a member account.
2. An [Amazon EventBridge](https://aws.amazon.com/eventbridge/) rule in the member account (deployed via StackSet) captures the failure event and forwards it to the delegated admin account's event bus.
3. An EventBridge rule in the delegated admin invokes an [AWS Lambda](https://aws.amazon.com/lambda/) function.
4. The Lambda function transforms the event into a signed webhook payload and sends it to the DevOps Agent.
5. DevOps Agent assumes a cross-account investigation role into the member account, analyzes the failure, and delivers root cause analysis to your Slack channel.

**Key design decisions:**

- **Event-driven** — zero cost when nothing fails, instant detection when something does.
- **Fully automated** — the deploy script creates the Agent Space, webhook, main stack, and StackSet in one run.
- **No member account logins** — SERVICE_MANAGED StackSets deploy via the Organizations trust.
- **Auto-scaling coverage** — new accounts joining the OU are automatically covered.

## Prerequisites

Before you begin, confirm the following:

- An AWS Organizations environment with a [delegated administrator for AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/manage-cross-account.html)
- Access to the management account (one-time setup only)
- Access to [Amazon DevOps Agent](https://aws.amazon.com/devops-agent/) (GA)
- AWS CLI v2 installed
- A Slack workspace where you can install apps

## Walkthrough

### Step 1: One-time setup (management account)

Register your delegated admin account for CloudFormation StackSets. This allows the delegated admin to deploy resources to member accounts without needing management account credentials again.

Run the following from the **management account**:

```bash
aws organizations register-delegated-administrator \
  --account-id YOUR_DELEGATED_ADMIN_ACCOUNT_ID \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com
```

Verify the registration:

```bash
aws organizations list-delegated-administrators \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com
```

> **Note:** This is a one-time operation. Once registered, all subsequent deployments happen from the delegated admin account.

### Step 2: Deploy the solution (delegated admin account)

Clone the repository and run the deployment script from your **delegated admin account**:

```bash
git clone https://github.com/kukkunuruanil/aws-backup-devops-agent-v6.git
cd aws-backup-devops-agent-v6
./deploy.sh
```

The script prompts you for three inputs, then asks you to create a webhook in the console:

| Prompt | Example |
|--------|---------|
| Organization ID | `o-abc1234567` |
| Target OU ID | `ou-xxxx-xxxxxxxx` or `r-xxxx` (root) |
| Region | `us-west-2` |
| Webhook URL | From DevOps Agent console (Capabilities → Webhook → Generate) |
| Webhook Secret | HMAC secret from the console |

The script then performs five automated steps:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[1/5] Creating DevOps Agent Space...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  → Creating Agent Space: BackupInvestigations
  ✓ Agent Space ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2/5] Creating IAM role & associating AWS account...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ IAM role created
  ✓ Account associated

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[3/5] Configuring webhook & deploying main stack...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  (You provide the webhook URL and secret from the console)
  ✓ Main stack deployed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[4/5] Deploying event forwarder + investigation role to member accounts...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[5/5] Verifying StackSet deployment across accounts...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ┌─────────────────┬──────────┬───────────────────────┐
  │ Account         │ Region   │ Status                │
  ├─────────────────┼──────────┼───────────────────────┤
  │ 444455556666    │ us-west-2│ ✓ SUCCEEDED           │
  │ 777788889999    │ us-west-2│ ✓ SUCCEEDED           │
  └─────────────────┴──────────┴───────────────────────┘

  → Testing Lambda (sending synthetic failure event)...
  ✓ Lambda invocation: HTTP 200 | Response: {"statusCode": 200}

╔════════════════════════════════════════════════════════════╗
║              ✓ DEPLOYMENT COMPLETE                        ║
╚════════════════════════════════════════════════════════════╝
```

### Step 3: Connect Slack

1. In the DevOps Agent console, navigate to **Capability Providers** and register Slack.
2. Complete the OAuth authorization in your Slack workspace.
3. Associate the Slack channel with your agent space:

```bash
aws devops-agent associate-service \
  --agent-space-id YOUR_AGENT_SPACE_ID \
  --service-id YOUR_SLACK_SERVICE_UUID \
  --configuration '{"slack":{"workspaceId":"YOUR_TEAM_ID","workspaceName":"YOUR_WORKSPACE","transmissionTarget":{"opsOncallTarget":{"channelId":"YOUR_CHANNEL_ID"}}}}' \
  --region us-west-2
```

4. Add the DevOps Agent bot to your channel:

```
/invite @AWS DevOps Agent
```

## What gets deployed

The solution creates resources at two scopes: **global** (one-time) and **per-region** (replicated to each region you choose).

### Global resources (created once)

| Account | Resource | Purpose |
|---------|----------|---------|
| Delegated admin | Agent Space `BackupInvestigations` | Receives and processes webhook events |
| Delegated admin | HMAC Webhook | Authenticated entry point for failure events |
| Delegated admin | IAM role `DevOpsAgentBackupRole` | Agent investigation access |
| Delegated admin | Slack association | Delivers findings to your channel |

### Per-region resources (delegated admin)

| Resource | Purpose |
|----------|---------|
| Lambda `BackupFailureBridge` | Transforms events and posts to webhook |
| EventBridge rule `BackupFailures-TriggerInvestigation` | Catches FAILED backup/copy events |
| EventBus policy | Accepts forwarded events from org accounts |
| IAM role (Lambda execution) | Auto-generated per region |
| Secrets Manager secret `devops-agent/backup-webhook` | Webhook credentials |

### Per-region resources (member accounts, via StackSet)

| Resource | Purpose |
|----------|---------|
| EventBridge rule `ForwardBackupFailures-ToCentral` | Forwards FAILED events to delegated admin |
| IAM role `BackupEventForwardingRole` | Allows cross-account event delivery |
| IAM role `DevOpsAgentInvestigationRole` | Allows DevOps Agent cross-account analysis |

> **Note:** On the delegated admin account, the StackSet skips the forwarding rule (cannot forward to itself) but still creates the investigation role so the agent can analyze local failures.

The member account footprint is minimal: one EventBridge rule and two IAM roles—no Lambda functions, no secrets, no compute resources.

## Multi-region deployment

EventBridge rules operate within a single Region. The initial `./deploy.sh` covers one region. To cover additional regions where your backup jobs run, use the multi-region command below.

### Option A: Deploy to all supported regions

```bash
WEBHOOK=$(aws secretsmanager get-secret-value --secret-id devops-agent/backup-webhook --region us-west-2 --query SecretString --output text)
WEBHOOK_URL=$(echo $WEBHOOK | python3 -c "import sys,json;print(json.load(sys.stdin)['webhookUrl'])")
WEBHOOK_SECRET=$(echo $WEBHOOK | python3 -c "import sys,json;print(json.load(sys.stdin)['webhookSecret'])")

for REGION in us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 \
              eu-west-1 eu-west-2 eu-central-1 eu-north-1 \
              ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-south-1 \
              sa-east-1; do
  echo "Deploying to $REGION..."
  aws cloudformation deploy --template-file templates/main-stack.yaml \
    --stack-name BackupDevOpsAgent \
    --parameter-overrides WebhookUrl="$WEBHOOK_URL" WebhookSecret="$WEBHOOK_SECRET" \
      AgentSpaceId=YOUR_AGENT_SPACE_ID OrganizationId=YOUR_ORG_ID \
    --capabilities CAPABILITY_NAMED_IAM --region $REGION --no-fail-on-empty-changeset
  aws cloudformation create-stack-instances --stack-set-name BackupEventForwarder \
    --deployment-targets OrganizationalUnitIds=YOUR_OU_ID --regions $REGION \
    --call-as DELEGATED_ADMIN --region us-west-2 2>/dev/null || true
done
```

### Option B: Deploy to specific regions only

Choose only the regions where your organization runs backup jobs:

```bash
# Example: US regions + EU (Frankfurt) only
for REGION in us-east-1 us-west-2 eu-central-1; do
  echo "Deploying to $REGION..."
  aws cloudformation deploy --template-file templates/main-stack.yaml \
    --stack-name BackupDevOpsAgent \
    --parameter-overrides WebhookUrl="$WEBHOOK_URL" WebhookSecret="$WEBHOOK_SECRET" \
      AgentSpaceId=YOUR_AGENT_SPACE_ID OrganizationId=YOUR_ORG_ID \
    --capabilities CAPABILITY_NAMED_IAM --region $REGION --no-fail-on-empty-changeset
  aws cloudformation create-stack-instances --stack-set-name BackupEventForwarder \
    --deployment-targets OrganizationalUnitIds=YOUR_OU_ID --regions $REGION \
    --call-as DELEGATED_ADMIN --region us-west-2 2>/dev/null || true
done
```

> **Tip:** Only deploy to regions where you have active backup plans or copy jobs. Regions without backup activity generate no events and incur no cost, but deploying everywhere ensures you're covered as your organization scales into new regions.

### How multi-region works

All regions share the **same** Agent Space, webhook, and Slack channel. Each region simply catches local failures and forwards them to the central webhook:

```
┌─────────────────────────────────────────────────────────────┐
│ us-east-1: EventBridge → Lambda ──┐                         │
│ us-west-2: EventBridge → Lambda ──┼──→ Webhook ──→ Agent    │
│ eu-west-1: EventBridge → Lambda ──┘         ↓               │
│                                           Slack             │
└─────────────────────────────────────────────────────────────┘
```

## How the investigation works

When a backup job fails, DevOps Agent performs autonomous investigation by:

1. **Parsing the failure event** — extracting the account ID, resource ARN, vault name, and error message.
2. **Assuming the investigation role** — using `DevOpsAgentInvestigationRole` to access the member account.
3. **Analyzing root cause** — checking AWS Backup job details, KMS key policies, IAM role permissions, and CloudTrail events.
4. **Delivering findings** — posting a structured root cause analysis to your Slack channel with the failure reason and remediation steps.

Common root causes the agent identifies:

- KMS key policies missing the backup service principal
- IAM role trust policies not allowing `backup.amazonaws.com`
- Resource tags not matching backup plan selection criteria
- Cross-Region copy jobs failing due to destination vault permissions
- Lifecycle policies conflicting with retention rules

## Cleanup

To remove all resources across all deployed regions:

```bash
# Set your values
OU_ID=YOUR_OU_ID
REGIONS="us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 eu-west-1 eu-west-2 eu-central-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-south-1 sa-east-1"

# 1. Remove StackSet instances (all regions)
aws cloudformation delete-stack-instances \
  --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions $REGIONS --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region us-west-2

# 2. Wait, then delete StackSet
aws cloudformation delete-stack-set \
  --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region us-west-2

# 3. Delete main stack in each region
for REGION in $REGIONS; do
  aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION
done

# 4. Delete Agent Space (optional)
aws devops-agent delete-agent-space \
  --agent-space-id YOUR_AGENT_SPACE_ID --region us-west-2

# 5. Delete IAM role (global)
aws iam detach-role-policy --role-name DevOpsAgentBackupRole \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy
aws iam delete-role --role-name DevOpsAgentBackupRole
```

## Conclusion

In this post, you built an automated backup failure investigation pipeline that covers your entire AWS Organization:

1. **One-time:** register the delegated admin for StackSets (management account).
2. **Deploy:** run a single script that creates the Agent Space, webhook, infrastructure, and StackSet—with full verification.
3. **Scale:** deploy to additional regions with a single loop command, choosing only the regions your organization uses.

By combining AWS Backup's cross-account management, EventBridge event-driven architecture, and Amazon DevOps Agent's autonomous investigation capabilities, you reduced the mean time to root cause from hours of manual investigation to minutes of automated analysis—delivered directly to your team's Slack channel.

The solution costs nothing when your backups are succeeding, automatically covers new accounts as they join your organization, scales to any number of regions, and requires no manual intervention when failures occur.

To get started, clone the [repository on GitHub](https://github.com/kukkunuruanil/aws-backup-devops-agent-v6) and run `./deploy.sh`.

---

**About the author**

**Anil Kukkunur** is a Solutions Architect at AWS, focused on helping customers build resilient data protection strategies using AWS Backup and AWS Organizations.
