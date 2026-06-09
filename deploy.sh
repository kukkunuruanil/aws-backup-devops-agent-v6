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
read -p "Region [$REGION]: " INPUT_REGION
REGION="${INPUT_REGION:-$REGION}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EVENT_BUS_ARN="arn:aws:events:${REGION}:${ACCOUNT_ID}:event-bus/default"

echo ""
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  Org:      $ORG_ID"
echo "  OU:       $OU_ID"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 1: Create DevOps Agent Space & Associate AWS Account
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[1/5] Creating DevOps Agent Space..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SPACE_NAME="BackupInvestigations"
echo "  → Creating Agent Space: $SPACE_NAME"

AGENT_SPACE_ID=$(aws devops-agent create-agent-space \
  --name "$SPACE_NAME" \
  --description "Automated backup failure investigation" \
  --region "$REGION" \
  --query 'agentSpace.agentSpaceId' --output text 2>/dev/null) || {
    echo "  ⚠ Space may already exist, looking up..."
    AGENT_SPACE_ID=$(aws devops-agent list-agent-spaces \
      --region "$REGION" \
      --query "agentSpaces[?name=='$SPACE_NAME'].agentSpaceId | [0]" --output text)
}

if [ -z "$AGENT_SPACE_ID" ] || [ "$AGENT_SPACE_ID" = "None" ]; then
  echo "  ✗ Could not create or find Agent Space."
  echo "    Please create it manually in the DevOps Agent console and provide the ID:"
  read -p "    Agent Space ID: " AGENT_SPACE_ID
fi
echo "  ✓ Agent Space ID: $AGENT_SPACE_ID"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 2: Create IAM Role & Associate AWS Account
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[2/5] Creating IAM role & associating AWS account..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create trust policy for DevOps Agent
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

# Create role (or skip if exists)
aws iam create-role \
  --role-name DevOpsAgentBackupRole \
  --assume-role-policy-document file:///tmp/devops-agent-trust-policy.json \
  >/dev/null 2>&1 && echo "  ✓ IAM role created" || echo "  ✓ IAM role already exists"

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
echo "  │ 2. Select Agent Space: $SPACE_NAME                     │"
echo "  │ 3. Go to Capabilities → Webhook → Configure            │"
echo "  │ 4. Click 'Generate webhook' (HMAC type)                │"
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

# Deploy instances
echo "  → Deploying to OU: $OU_ID in region $REGION..."
OPERATION_ID=$(aws cloudformation create-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --deployment-targets "OrganizationalUnitIds=$OU_ID" \
  --regions "$REGION" \
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
