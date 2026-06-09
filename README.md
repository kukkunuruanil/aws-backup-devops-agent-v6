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
./deploy.sh
```

The script automatically creates the Agent Space, webhook, infrastructure, and StackSet.

### Step 3: Connect Slack

Register Slack in the DevOps Agent console and associate your channel.

## What it does

When any backup or copy job fails in any member account:
1. EventBridge forwards the failure event to the delegated admin
2. Lambda sends the event to DevOps Agent via webhook
3. DevOps Agent investigates root cause across accounts
4. Results are delivered to Slack

## Files

```
├── deploy.sh                          # Automated deployment script
├── templates/
│   ├── main-stack.yaml                # Delegated admin resources
│   └── member-forwarder.yaml          # Member account resources (via StackSet)
├── BLOG_POST.md                       # Full blog post
└── README.md
```

## Prerequisites

- AWS Organizations with delegated admin for AWS Backup
- Delegated admin registered for CloudFormation StackSets (Step 1)
- AWS CLI v2
- Amazon DevOps Agent access (GA)

## Cleanup

```bash
REGION=us-west-2

aws cloudformation delete-stack-instances \
  --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=YOUR_OU_ID \
  --regions $REGION --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region $REGION

aws cloudformation delete-stack-set \
  --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region $REGION

aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION
```
