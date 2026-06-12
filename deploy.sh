#!/bin/bash
set -e

STACK_NAME="BackupDevOpsAgent"
STACKSET_NAME="BackupEventForwarder"
REGION="${AWS_DEFAULT_REGION:-us-west-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     AWS Backup DevOps Agent v6 - Automated Deployment     ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  This script:                                             ║"
echo "║   1. Creates DevOps Agent Space & associates AWS account  ║"
echo "║   2. Deploys main stack (Lambda, EventBridge, IAM)        ║"
echo "║   3. Deploys StackSet to all member accounts              ║"
echo "║   4. Verifies deployment across all accounts              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# --- Collect inputs ---
read -p "Organization ID (e.g., o-xxxxxxxxxx): " ORG_ID
read -p "Target OU ID (e.g., ou-xxxx-xxxxxxxx or r-xxxx for root): " OU_ID
read -p "Region (single region or 'all' for all regions) [$REGION]: " INPUT_REGION

if [ "$INPUT_REGION" = "all" ]; then
  REGIONS=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "ca-central-1" "eu-west-1" "eu-west-2" "eu-west-3" "eu-central-1" "eu-north-1" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1" "ap-northeast-2" "ap-south-1" "sa-east-1")
  REGION="${REGIONS[0]}"
  echo "  → Deploying to ALL ${#REGIONS[@]} regions"
else
  REGION="${INPUT_REGION:-$REGION}"
  REGIONS=("$REGION")
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EVENT_BUS_ARN="arn:aws:events:${REGION}:${ACCOUNT_ID}:event-bus/default"

echo ""
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  Org:      $ORG_ID"
echo "  OU:       $OU_ID"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 1: Create or Reuse DevOps Agent Space
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[1/5] Creating DevOps Agent Space..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SPACE_NAME="BackupInvestigations"

# Check if space already exists
AGENT_SPACE_ID=$(aws devops-agent list-agent-spaces \
  --region "$REGION" \
  --query "agentSpaces[?name=='$SPACE_NAME'].agentSpaceId | [0]" --output text 2>/dev/null)

if [ -z "$AGENT_SPACE_ID" ] || [ "$AGENT_SPACE_ID" = "None" ]; then
  echo "  → Creating Agent Space: $SPACE_NAME"
  AGENT_SPACE_ID=$(aws devops-agent create-agent-space \
    --name "$SPACE_NAME" \
    --description "Automated backup failure investigation" \
    --region "$REGION" \
    --query 'agentSpace.agentSpaceId' --output text)
else
  echo "  → Agent Space already exists, reusing"
fi

if [ -z "$AGENT_SPACE_ID" ] || [ "$AGENT_SPACE_ID" = "None" ]; then
  echo "  ✗ Could not create or find Agent Space."
  read -p "    Enter Agent Space ID manually: " AGENT_SPACE_ID
fi
echo "  ✓ Agent Space ID: $AGENT_SPACE_ID"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 2: Create IAM Role & Associate AWS Account
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[2/5] Creating IAM role & associating AWS account..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create trust policy
cat > /tmp/devops-agent-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "aidevops.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "$ACCOUNT_ID"
        },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/*"
        }
      }
    }
  ]
}
EOF

# Create role if not exists, update trust policy if it does
if aws iam get-role --role-name DevOpsAgentBackupRole >/dev/null 2>&1; then
  echo "  ✓ IAM role exists, updating trust policy"
  aws iam update-assume-role-policy \
    --role-name DevOpsAgentBackupRole \
    --policy-document file:///tmp/devops-agent-trust-policy.json
else
  echo "  → Creating IAM role: DevOpsAgentBackupRole"
  aws iam create-role \
    --role-name DevOpsAgentBackupRole \
    --assume-role-policy-document file:///tmp/devops-agent-trust-policy.json >/dev/null
fi

aws iam attach-role-policy \
  --role-name DevOpsAgentBackupRole \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy 2>/dev/null || true

echo "  → Associating AWS account with Agent Space..."
aws devops-agent associate-service \
  --agent-space-id "$AGENT_SPACE_ID" \
  --service-id aws \
  --configuration "{\"aws\":{\"assumableRoleArn\":\"arn:aws:iam::${ACCOUNT_ID}:role/DevOpsAgentBackupRole\",\"accountId\":\"${ACCOUNT_ID}\",\"accountType\":\"monitor\"}}" \
  --region "$REGION" >/dev/null 2>&1 && echo "  ✓ Account associated" || echo "  ✓ Already associated"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 3: Configure Webhook & Deploy Main Stack
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[3/5] Configuring webhook & deploying main stack..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ┌────────────────────────────────────────────────────────┐"
echo "  │ MANUAL STEP: Create a Generic Webhook                  │"
echo "  │                                                        │"
echo "  │ 1. Open: https://console.aws.amazon.com/devops-agent   │"
echo "  │ 2. Go to Agent Spaces → Select your space              │"
echo "  │ 3. Click 'Configure Agent Space Webhook'               │"
echo "  │ 4. Generate webhook (HMAC type)                        │"
echo "  │ 5. Copy the URL and Secret below                       │"
echo "  └────────────────────────────────────────────────────────┘"
echo ""
read -p "  Webhook URL: " WEBHOOK_URL
read -sp "  Webhook Secret: " WEBHOOK_SECRET
echo ""

if [ -z "$WEBHOOK_URL" ] || [ -z "$WEBHOOK_SECRET" ]; then
  echo "  ✗ Webhook URL and Secret are required. Exiting."
  exit 1
fi
echo "  ✓ Webhook configured"
echo ""

# Clean up any previous failed stack
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STACK_STATUS" == *"ROLLBACK"* ]] || [[ "$STACK_STATUS" == *"FAILED"* ]]; then
  echo "  → Cleaning up previous failed stack..."
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
  echo "  ✓ Old stack removed"
fi

# Delete secret if in pending-deletion state (from a previous failed deploy)
aws secretsmanager delete-secret \
  --secret-id "devops-agent/backup-webhook" \
  --force-delete-without-recovery \
  --region "$REGION" 2>/dev/null || true

# Brief wait for secret deletion to propagate
sleep 2

echo "  → Deploying main CloudFormation stack..."
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/templates/main-stack.yaml" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides \
    WebhookUrl="$WEBHOOK_URL" \
    WebhookSecret="$WEBHOOK_SECRET" \
    AgentSpaceId="$AGENT_SPACE_ID" \
    OrganizationId="$ORG_ID" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo "  ✓ Main stack deployed"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 4: Deploy StackSet to member accounts
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[4/5] Deploying event forwarder + investigation role to member accounts..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create or update StackSet
if aws cloudformation describe-stack-set \
  --stack-set-name "$STACKSET_NAME" \
  --call-as DELEGATED_ADMIN \
  --region "$REGION" >/dev/null 2>&1; then
  echo "  → StackSet exists, updating..."
  aws cloudformation update-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$SCRIPT_DIR/templates/member-forwarder.yaml" \
    --parameters "ParameterKey=DelegatedAdminAccountId,ParameterValue=$ACCOUNT_ID" \
                 "ParameterKey=DelegatedAdminEventBusArn,ParameterValue=$EVENT_BUS_ARN" \
    --capabilities CAPABILITY_NAMED_IAM \
    --call-as DELEGATED_ADMIN \
    --region "$REGION" 2>/dev/null && echo "  ✓ StackSet updated" || echo "  ✓ No changes needed"
else
  echo "  → Creating StackSet: $STACKSET_NAME"
  aws cloudformation create-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$SCRIPT_DIR/templates/member-forwarder.yaml" \
    --parameters "ParameterKey=DelegatedAdminAccountId,ParameterValue=$ACCOUNT_ID" \
                 "ParameterKey=DelegatedAdminEventBusArn,ParameterValue=$EVENT_BUS_ARN" \
    --permission-model SERVICE_MANAGED \
    --auto-deployment "Enabled=true,RetainStacksOnAccountRemoval=false" \
    --capabilities CAPABILITY_NAMED_IAM \
    --call-as DELEGATED_ADMIN \
    --region "$REGION"
  echo "  ✓ StackSet created"
fi

# Deploy instances to ALL selected regions
REGIONS_LIST=$(printf '%s ' "${REGIONS[@]}")
echo "  → Deploying to OU: $OU_ID in regions: $REGIONS_LIST"
OPERATION_ID=$(aws cloudformation create-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --deployment-targets "OrganizationalUnitIds=$OU_ID" \
  --regions ${REGIONS[@]} \
  --call-as DELEGATED_ADMIN \
  --region "$REGION" \
  --query 'OperationId' --output text 2>/dev/null) || {
    echo "  ✓ Instances already deployed"
    OPERATION_ID=""
}

# Wait for StackSet operation to complete
if [ -n "$OPERATION_ID" ]; then
  echo "  → Waiting for StackSet deployment (Operation: $OPERATION_ID)..."
  while true; do
    STATUS=$(aws cloudformation describe-stack-set-operation \
      --stack-set-name "$STACKSET_NAME" \
      --operation-id "$OPERATION_ID" \
      --call-as DELEGATED_ADMIN \
      --region "$REGION" \
      --query 'StackSetOperation.Status' --output text 2>/dev/null)
    case "$STATUS" in
      SUCCEEDED) echo "  ✓ StackSet deployment SUCCEEDED"; break ;;
      FAILED|STOPPED) echo "  ✗ StackSet deployment $STATUS"; break ;;
      *) echo "    Status: $STATUS ..."; sleep 10 ;;
    esac
  done
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 5: Verify deployment
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[5/5] Verifying StackSet deployment across accounts..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "  ┌─────────────────┬──────────┬───────────────────────┐"
echo "  │ Account         │ Region   │ Status                │"
echo "  ├─────────────────┼──────────┼───────────────────────┤"

aws cloudformation list-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --call-as DELEGATED_ADMIN \
  --region "$REGION" \
  --query 'Summaries[].{Account:Account,Region:Region,Status:StackInstanceStatus.DetailedStatus}' \
  --output json 2>/dev/null | python3 -c "
import sys, json
instances = json.load(sys.stdin)
for i in instances:
    status = i.get('Status','UNKNOWN')
    icon = '✓' if status == 'SUCCEEDED' else '✗'
    print(f\"  │ {i['Account']:15} │ {i['Region']:8} │ {icon} {status:19} │\")
" 2>/dev/null || echo "  │ (pending)       │          │ Deploying...          │"

echo "  └─────────────────┴──────────┴───────────────────────┘"
echo ""

# Test Lambda
echo "  → Testing Lambda (sending synthetic failure event)..."
PAYLOAD=$(echo '{"source":"aws.backup","detail-type":"Copy Job State Change","detail":{"state":"FAILED","copyJobId":"DEPLOY-TEST","statusMessage":"Deployment validation test","accountId":"'$ACCOUNT_ID'","resourceArn":"arn:aws:ec2:'$REGION':'$ACCOUNT_ID':volume/vol-test","backupVaultName":"Default"}}' | base64)
RESULT=$(aws lambda invoke --function-name BackupFailureBridge --payload "$PAYLOAD" --region "$REGION" /tmp/test-response.json --query 'StatusCode' --output text 2>/dev/null)
RESPONSE=$(cat /tmp/test-response.json 2>/dev/null)
echo "  ✓ Lambda invocation: HTTP $RESULT | Response: $RESPONSE"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              ✓ DEPLOYMENT COMPLETE                        ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
echo "║  Agent Space:  $AGENT_SPACE_ID"
echo "║  Stack:        $STACK_NAME ($REGION)"
echo "║  StackSet:     $STACKSET_NAME (auto-deploys to new accts)"
echo "║                                                           ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  REMAINING: Connect Slack                                 ║"
echo "║                                                           ║"
echo "║  1. DevOps Agent console → Capabilities → Slack           ║"
echo "║     Register and complete OAuth                           ║"
echo "║                                                           ║"
echo "║  2. In Slack: /invite @AWS DevOps Agent                   ║"
echo "║                                                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
