# Implementation Guide
## AWS Backup DevOps Agent — Automated Deployment

**Time Required:** ~10 minutes  
**Deploy from:** Delegated admin account only  
**Member account work:** None (StackSet handles it automatically)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AWS Organization                                │
│                                                                          │
│  ┌─────────────────────────┐      ┌────────────────────────────────────┐│
│  │ Member Account (auto)    │      │ Delegated Admin Account            ││
│  │                          │      │                                    ││
│  │  Backup Job FAILS        │      │  EventBridge ──→ Lambda ──→ Webhook││
│  │       │                  │      │      ↑                       │    ││
│  │       ▼                  │      │      │                       ▼    ││
│  │  EventBridge Rule ───────┼──────┼──────┘               DevOps Agent ││
│  │  (StackSet, auto-deploy) │      │                       │    │      ││
│  │                          │      │                       │    ▼      ││
│  │  Investigation Role ◄────┼──────┼───────────────────────┘  Slack    ││
│  │  (StackSet, auto-deploy) │      │                                    ││
│  └─────────────────────────┘      └────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘
```

**Flow:** Member failure → EventBridge forwards → Lambda → DevOps Agent webhook → Agent assumes investigation role → Root cause → Slack

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| AWS Organizations | Configured with OU structure |
| Delegated Backup Admin | Account registered for AWS Backup |
| AWS CLI v2 | Admin credentials for delegated admin account |
| Management account access | One-time only (Step 1) |
| Amazon DevOps Agent | GA access |
| Slack workspace | Permission to install apps |

---

## Step 1: One-Time Setup (Management Account)

Register your delegated admin for CloudFormation StackSets:

```bash
aws organizations register-delegated-administrator \
  --account-id YOUR_DELEGATED_ADMIN_ID \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com
```

> ✅ **Verify:**
> ```bash
> aws organizations list-delegated-administrators \
>   --service-principal member.org.stacksets.cloudformation.amazonaws.com
> ```
> Your account should appear in the output.

**You will not need management account access again.**

---

## Step 2: Deploy the Solution (Delegated Admin Account)

### Step 2.1: Clone and Run

```bash
git clone https://github.com/kukkunuruanil/aws-backup-devops-agent-v6.git
cd aws-backup-devops-agent-v6
./deploy.sh
```

### Step 2.2: Prompts

The script asks for **3 inputs** plus webhook credentials — everything else is automated:

| Prompt | Example | Where to find it |
|--------|---------|-------------------|
| Organization ID | `o-abc1234567` | AWS Organizations console or `aws organizations describe-organization` |
| Target OU ID | `ou-xxxx-xxxxxxxx` | AWS Organizations → Organizational units |
| Region | `us-west-2` | Your primary backup region |
| Webhook URL | `https://event-ai...` | DevOps Agent console → Capabilities → Webhook |
| Webhook Secret | (hidden) | Generated when creating the webhook |

> **Tip:** Use `r-xxxx` (root ID) to cover all accounts in the organization.

> **Webhook Setup:** During Step 3/5, the script pauses and asks for webhook credentials. Open the DevOps Agent console, select your Agent Space, go to Capabilities → Webhook → Generate webhook (HMAC type), then copy the URL and secret back into the terminal.

### Step 2.3: Automated Steps

The script performs 5 steps automatically:

| Step | Action | What it creates |
|------|--------|----------------|
| 1/5 | Create Agent Space | DevOps Agent space via CLI |
| 2/5 | Create IAM role & associate AWS | IAM role + account association |
| 3/5 | Configure webhook & deploy stack | Lambda, EventBridge, IAM, Secrets Manager |
| 4/5 | Deploy StackSet | Event forwarder + investigation role to all member accounts |
| 5/5 | Verify deployment | Shows per-account status table + Lambda test |

Expected output:

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
  (Provide webhook URL and secret from console)
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

> ✅ **Verification:** All accounts show `SUCCEEDED` and Lambda returns `{"statusCode": 200}`

---

## Step 3: Connect Slack

### Step 3.1: Register Slack

1. Open **DevOps Agent console** → Capability Providers → Slack → **Register**
2. Complete OAuth authorization

> ✅ Slack shows "Registered"

### Step 3.2: Associate Slack Channel

```bash
# Get Slack service UUID
aws devops-agent list-services --region us-west-2

# Associate channel
aws devops-agent associate-service \
  --agent-space-id YOUR_AGENT_SPACE_ID \
  --service-id YOUR_SLACK_SERVICE_UUID \
  --configuration '{"slack":{"workspaceId":"YOUR_TEAM_ID","workspaceName":"YOUR_WORKSPACE","transmissionTarget":{"opsOncallTarget":{"channelId":"YOUR_CHANNEL_ID"}}}}' \
  --region us-west-2
```

### Step 3.3: Add Bot

In your Slack channel: `/invite @AWS DevOps Agent`

> ✅ Confirmation message appears

---

## Step 4: Test End-to-End

### Option A: Synthetic test (instant)

```bash
aws lambda invoke --function-name BackupFailureBridge \
  --payload $(echo '{"source":"aws.backup","detail-type":"Copy Job State Change","detail":{"state":"FAILED","copyJobId":"TEST-001","statusMessage":"KMS key not accessible","accountId":"111122223333","resourceArn":"arn:aws:ec2:us-west-2:111122223333:volume/vol-0abc","backupVaultName":"Default"}}' | base64) \
  /tmp/test.json && cat /tmp/test.json
```

Expected: `{"statusCode": 200}` + investigation appears in Slack within 3–5 minutes.

### Option B: Trigger a real failure

Create a copy job to a non-existent vault:

```bash
aws backup start-copy-job \
  --recovery-point-arn YOUR_RECOVERY_POINT_ARN \
  --source-backup-vault-name Default \
  --destination-backup-vault-arn arn:aws:backup:us-east-1:999999999999:backup-vault:NonExistent \
  --iam-role-arn arn:aws:iam::YOUR_ACCOUNT:role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup
```

> ✅ Investigation triggered, root cause delivered to Slack

---

## What Gets Deployed

### Delegated Admin Account

| Resource | Type | Purpose |
|----------|------|---------|
| `BackupInvestigations` | Agent Space | Receives webhook events |
| HMAC Webhook | Webhook | Authenticated event intake |
| `BackupFailureBridge` | Lambda | Transforms events → webhook POST |
| `BackupFailures-TriggerInvestigation` | EventBridge Rule | Catches FAILED events |
| EventBus Policy | EventBridge | Allows org accounts to send events |
| `DevOpsAgentBackupRole` | IAM Role | Agent investigation access |
| `BackupFailureBridgeRole` | IAM Role | Lambda execution |
| `devops-agent/backup-webhook` | Secret | Webhook URL + HMAC key |

### Member Accounts (via StackSet, auto-deployed)

| Resource | Type | Purpose |
|----------|------|---------|
| `ForwardBackupFailures-ToCentral` | EventBridge Rule | Forwards FAILED events to delegated admin |
| `BackupEventForwardingRole` | IAM Role | Allows EventBridge cross-account PutEvents |
| `DevOpsAgentInvestigationRole` | IAM Role | Allows Agent to investigate in this account |

---

## Multi-Region

To cover multiple regions, run the script once per region:

```bash
for REGION in us-east-1 us-west-2 eu-west-1; do
  AWS_DEFAULT_REGION=$REGION ./deploy.sh
done
```

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| StackSet creation fails | Registered as CF StackSets delegated admin? (Step 1) |
| No events from member accounts | `aws cloudformation list-stack-instances --stack-set-name BackupEventForwarder --call-as DELEGATED_ADMIN` |
| Lambda error | `aws logs tail /aws/lambda/BackupFailureBridge --since 10m` |
| No Slack notification | Bot in channel? Check Agent console for pending investigations |
| Webhook 403 | Secret rotated? Update `devops-agent/backup-webhook` in Secrets Manager |
| Agent can't investigate member | Verify `DevOpsAgentInvestigationRole` trusts the delegated admin |

---

## Cleanup

```bash
REGION=us-west-2

# 1. Remove StackSet instances
aws cloudformation delete-stack-instances \
  --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=YOUR_OU_ID \
  --regions $REGION --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region $REGION

# 2. Wait, then delete StackSet
aws cloudformation delete-stack-set \
  --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region $REGION

# 3. Delete main stack
aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION

# 4. (Optional) Delete Agent Space
aws devops-agent delete-agent-space \
  --agent-space-id YOUR_AGENT_SPACE_ID --region $REGION
```
