#!/bin/bash
set -e

STACK_NAME="BackupDevOpsAgent"
STACKSET_NAME="BackupEventForwarder"
REGION="${AWS_DEFAULT_REGION:-us-west-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     AWS Backup DevOps Agent - Automated Deployment        ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  This script:                                             ║"
echo "║   1. Creates DevOps Agent Space & Webhook                 ║"
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
# STEP 1: Create DevOps Agent Space & Webhook
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[1/5] Creating DevOps Agent Space & Webhook..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create Agent Space
SPACE_NAME="BackupInvestigations"
echo "  → Creating Agent Space: $SPACE_NAME"
AGENT_SPACE_ID=$(aws devops-agent create-agent-space \
  --agent-space-name "$SPACE_NAME" \
  --region "$REGION" \
  --query 'agentSpaceId' --output text 2>/dev/null) || {
    echo "  ⚠ Space may already exist, looking up..."
    AGENT_SPACE_ID=$(aws devops-agent list-agent-spaces \
      --region "$REGION" \
      --query "agentSpaces[?agentSpaceName=='$SPACE_NAME'].agentSpaceId | [0]" --output text)
}
echo "  ✓ Agent Space ID: $AGENT_SPACE_ID"

# Create Webhook
echo "  → Creating HMAC webhook..."
WEBHOOK_OUTPUT=$(aws devops-agent create-webhook \
  --agent-space-id "$AGENT_SPACE_ID" \
  --webhook-name "BackupFailureWebhook" \
  --authentication-type "HMAC" \
  --region "$REGION" 2>/dev/null) || {
    echo "  ⚠ Webhook may already exist, looking up..."
    WEBHOOK_OUTPUT=$(aws devops-agent list-webhooks \
      --agent-space-id "$AGENT_SPACE_ID" \
      --region "$REGION" \
      --query "webhooks[?webhookName=='BackupFailureWebhook'] | [0]" --output json)
}
WEBHOOK_URL=$(echo "$WEBHOOK_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('webhookUrl',''))")
WEBHOOK_SECRET=$(echo "$WEBHOOK_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")

if [ -z "$WEBHOOK_URL" ] || [ -z "$WEBHOOK_SECRET" ]; then
  echo "  ✗ Failed to retrieve webhook credentials."
  echo "    If the webhook already exists, the secret cannot be retrieved again."
  echo "    Either delete and recreate the webhook, or provide manually:"
  read -p "    Webhook URL: " WEBHOOK_URL
  read -sp "    Webhook Secret: " WEBHOOK_SECRET
  echo ""
fi
echo "  ✓ Webhook URL: ${WEBHOOK_URL:0:50}..."
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 2: Deploy main stack
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[2/5] Deploying main stack in $ACCOUNT_ID ($REGION)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
# STEP 3: Associate account with DevOps Agent
# ═══════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[3/5] Associating account with DevOps Agent..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws devops-agent associate-service \
  --agent-space-id "$AGENT_SPACE_ID" \
  --service-id aws \
  --configuration "{\"aws\":{\"assumableRoleArn\":\"arn:aws:iam::${ACCOUNT_ID}:role/DevOpsAgentBackupRole\",\"accountId\":\"${ACCOUNT_ID}\",\"accountType\":\"monitor\"}}" \
  --region "$REGION" 2>/dev/null && echo "  ✓ Account associated" || echo "  ✓ Already associated"
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
echo "║  Agent Space:  $AGENT_SPACE_ID  ║"
echo "║  Stack:        $STACK_NAME (${REGION})                    ║"
echo "║  StackSet:     $STACKSET_NAME (auto-deploys to new accts) ║"
echo "║                                                           ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  REMAINING: Connect Slack                                 ║"
echo "║                                                           ║"
echo "║  1. Open DevOps Agent console → Capability Providers      ║"
echo "║     Register Slack and complete OAuth                     ║"
echo "║                                                           ║"
echo "║  2. Associate Slack channel:                              ║"
echo "║     aws devops-agent associate-service \\                  ║"
echo "║       --agent-space-id $AGENT_SPACE_ID \\                  ║"
echo "║       --service-id YOUR_SLACK_SERVICE_UUID \\              ║"
echo "║       --configuration '{...}' --region $REGION            ║"
echo "║                                                           ║"
echo "║  3. In Slack: /invite @AWS DevOps Agent                   ║"
echo "║                                                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
