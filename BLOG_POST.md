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
cd aws-backup-devops-agent
./deploy.sh
```

The script prompts you for three inputs:

| Prompt | Example |
|--------|---------|
| Organization ID | `o-abc1234567` |
| Target OU ID | `ou-xxxx-xxxxxxxx` or `r-xxxx` (root) |
| Region | `us-west-2` |

The script then performs five automated steps:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[1/5] Creating DevOps Agent Space & Webhook...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  → Creating Agent Space: BackupInvestigations
  ✓ Agent Space ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
  → Creating HMAC webhook...
  ✓ Webhook URL: https://webhooks.devops-agent...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2/5] Deploying main stack in 111122223333 (us-west-2)...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Waiting for stack create/update to complete
  ✓ Main stack deployed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[3/5] Associating account with DevOps Agent...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ Account associated

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[4/5] Deploying event forwarder + investigation role to member accounts...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  → Creating StackSet: BackupEventForwarder
  ✓ StackSet created
  → Deploying to OU: ou-xxxx-xxxxxxxx in region us-west-2...
  → Waiting for StackSet deployment (Operation: abc123...)
    Status: RUNNING ...
    Status: RUNNING ...
  ✓ StackSet deployment SUCCEEDED

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

The following table summarizes all resources created by the solution.

| Account | Resource | Purpose |
|---------|----------|---------|
| Delegated admin | Agent Space `BackupInvestigations` | Receives and processes webhook events |
| Delegated admin | HMAC Webhook | Authenticated entry point for failure events |
| Delegated admin | Lambda `BackupFailureBridge` | Transforms events and posts to webhook |
| Delegated admin | EventBridge rule | Catches FAILED backup events |
| Delegated admin | EventBus policy | Accepts forwarded events from org |
| Delegated admin | IAM roles (2) | Agent access + Lambda execution |
| Delegated admin | Secrets Manager secret | Webhook credentials |
| Member accounts | EventBridge rule | Forwards FAILED events to delegated admin |
| Member accounts | IAM role (forwarding) | Allows cross-account event delivery |
| Member accounts | IAM role (investigation) | Allows DevOps Agent cross-account analysis |

The member account footprint is minimal: one EventBridge rule and two IAM roles—no Lambda functions, no secrets, no compute resources.

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

## Multi-region considerations

EventBridge rules operate within a single Region. If your backup jobs span multiple Regions, run the deploy script once per Region:

```bash
for REGION in us-east-1 us-west-2 eu-west-1; do
  AWS_DEFAULT_REGION=$REGION ./deploy.sh
done
```

The StackSet deployment in each run targets only the specified Region in the member accounts.

## Cleanup

To remove all resources:

```bash
REGION=us-west-2

# Remove member account resources
aws cloudformation delete-stack-instances \
  --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=YOUR_OU_ID \
  --regions $REGION --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region $REGION

# Delete StackSet (after instances complete deletion)
aws cloudformation delete-stack-set \
  --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region $REGION

# Delete main stack
aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION

# Delete Agent Space (optional)
aws devops-agent delete-agent-space \
  --agent-space-id YOUR_AGENT_SPACE_ID --region $REGION
```

## Conclusion

In this post, you built an automated backup failure investigation pipeline that covers your entire AWS Organization in two steps:

1. **One-time:** register the delegated admin for StackSets (management account).
2. **Deploy:** run a single script that creates the Agent Space, webhook, infrastructure, and StackSet—with full verification.

By combining AWS Backup's cross-account management, EventBridge event-driven architecture, and Amazon DevOps Agent's autonomous investigation capabilities, you reduced the mean time to root cause from hours of manual investigation to minutes of automated analysis—delivered directly to your team's Slack channel.

The solution costs nothing when your backups are succeeding, automatically covers new accounts as they join your organization, and requires no manual intervention when failures occur.

To get started, clone the [repository on GitHub](https://github.com/kukkunuruanil/aws-backup-devops-agent-v6) and run `./deploy.sh`.

---

**About the author**

**Anil Kukkunur** is a Solutions Architect at AWS, focused on helping customers build resilient data protection strategies using AWS Backup and AWS Organizations.
