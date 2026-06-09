# AWS Backup DevOps Agent

Automated backup failure investigation across AWS Organizations using Amazon DevOps Agent.

## Quick Start

### Step 1: One-time setup (management account)

```bash
aws organizations register-delegated-administrator \
  --account-id YOUR_DELEGATED_ADMIN_ID \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com
```

### Step 2: Deploy (delegated admin account)

```bash
git clone https://github.com/kukkunuruanil/aws-backup-devops-agent-v6.git
cd aws-backup-devops-agent-v6
./deploy.sh
```

The script creates the Agent Space, IAM roles, infrastructure, and StackSet. You'll be prompted to create a webhook in the DevOps Agent console during deployment.

### Step 3: Connect Slack

Register Slack in the DevOps Agent console, then associate your channel:

```bash
aws devops-agent associate-service \
  --agent-space-id YOUR_AGENT_SPACE_ID \
  --service-id YOUR_SLACK_SERVICE_UUID \
  --configuration '{"slack":{"workspaceId":"YOUR_TEAM_ID","workspaceName":"YOUR_WORKSPACE","transmissionTarget":{"opsOncallTarget":{"channelId":"YOUR_CHANNEL_ID"}}}}' \
  --region us-west-2
```

### Step 4: Multi-region (optional)

Deploy to additional regions to cover all backup activity:

```bash
# Option A: All regions
for REGION in us-east-1 us-east-2 us-west-1 ca-central-1 eu-west-1 eu-west-2 eu-central-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-south-1 sa-east-1; do
  aws cloudformation deploy --template-file templates/main-stack.yaml --stack-name BackupDevOpsAgent \
    --parameter-overrides WebhookUrl="$WEBHOOK_URL" WebhookSecret="$WEBHOOK_SECRET" \
      AgentSpaceId=YOUR_AGENT_SPACE_ID OrganizationId=YOUR_ORG_ID \
    --capabilities CAPABILITY_NAMED_IAM --region $REGION --no-fail-on-empty-changeset
  aws cloudformation create-stack-instances --stack-set-name BackupEventForwarder \
    --deployment-targets OrganizationalUnitIds=YOUR_OU_ID --regions $REGION \
    --call-as DELEGATED_ADMIN --region us-west-2 2>/dev/null || true
done

# Option B: Specific regions only
for REGION in us-east-1 us-west-2 eu-central-1; do
  # Same commands as above
done
```

## What it does

When any backup or copy job fails in any member account, in any deployed region:
1. EventBridge forwards the failure event to the delegated admin
2. Lambda sends the event to DevOps Agent via webhook
3. DevOps Agent investigates root cause across accounts
4. Results are delivered to Slack

## What gets deployed

| Scope | Resources |
|-------|-----------|
| **Global (once)** | Agent Space, Webhook, IAM role `DevOpsAgentBackupRole`, Slack association |
| **Per-region (delegated admin)** | Lambda, EventBridge rule, EventBus policy, Secrets Manager secret |
| **Per-region (member accounts)** | EventBridge forwarding rule, 2 IAM roles (forwarding + investigation) |

## Files

```
├── deploy.sh                          # Automated deployment script
├── templates/
│   ├── main-stack.yaml                # Delegated admin resources (per-region)
│   └── member-forwarder.yaml          # Member account resources (via StackSet)
├── BLOG_POST.md                       # Full blog post
├── IMPLEMENTATION_GUIDE.md            # Step-by-step implementation guide
└── README.md
```

## Prerequisites

- AWS Organizations with delegated admin for AWS Backup
- Delegated admin registered for CloudFormation StackSets (Step 1)
- AWS CLI v2.34+ (for `aws devops-agent` commands)
- Amazon DevOps Agent access

## Cleanup

```bash
OU_ID=YOUR_OU_ID
REGIONS="us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 eu-west-1 eu-west-2 eu-central-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-south-1 sa-east-1"

aws cloudformation delete-stack-instances --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions $REGIONS --no-retain-stacks --call-as DELEGATED_ADMIN --region us-west-2

aws cloudformation delete-stack-set --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region us-west-2

for REGION in $REGIONS; do
  aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION
done

aws iam detach-role-policy --role-name DevOpsAgentBackupRole \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy
aws iam delete-role --role-name DevOpsAgentBackupRole
```
