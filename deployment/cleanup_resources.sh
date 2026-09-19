#!/usr/bin/env bash
set -e

# ============================================================
# Configuration
# ============================================================

REGION="us-east-1"
ROLE_NAME="kb-s3vectors-docs-role"
BUCKET_PREFIX="kb-docs-bucket"
VECTOR_BUCKET_PREFIX="kb-docs-vectors"
INDEX_NAME="kb-docs-index"
KB_NAME="kb-demo"

# ============================================================
# Helper functions
# ============================================================

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ============================================================
# Step 0: AWS / Account information
# ============================================================

log "Step 0: Getting AWS account information"

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text \
    --no-cli-pager)

BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}"
VECTOR_BUCKET="${VECTOR_BUCKET_PREFIX}-${ACCOUNT_ID}"

# ============================================================
# Step 1: Delete Knowledge Base
# ============================================================

log "Step 1: Finding and deleting Knowledge Base"

KB_ID=$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId|[0]" \
  --output text \
  --no-cli-pager)

if [ "${KB_ID}" != "None" ] && [ -n "${KB_ID}" ]; then
  echo "Deleting Knowledge Base: ${KB_ID}"

  aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "${KB_ID}" \
    --no-cli-pager 2>/dev/null || true
fi

# ============================================================
# Step 2: Delete S3 buckets
# ============================================================

log "Step 2: Deleting S3 buckets"

echo "Deleting S3 bucket: ${BUCKET}"

aws s3 rb "s3://${BUCKET}" \
  --force \
  --region "${REGION}" \
  --no-cli-pager 2>/dev/null || true

# ============================================================
# Step 3: Delete S3 Vector index and bucket
# ============================================================

log "Step 3: Deleting S3 Vector index and bucket"

echo "Deleting S3 Vector index: ${INDEX_NAME}"

aws s3vectors delete-index \
  --vector-bucket-name "${VECTOR_BUCKET}" \
  --index-name "${INDEX_NAME}" \
  --no-cli-pager 2>/dev/null || true

echo "Deleting S3 Vector bucket: ${VECTOR_BUCKET}"

aws s3vectors delete-vector-bucket \
  --vector-bucket-name "${VECTOR_BUCKET}" \
  --no-cli-pager 2>/dev/null || true

# ============================================================
# Step 4: Cleanup IAM role policies
# ============================================================

log "Step 4: Cleanup IAM role policies"

echo "Deleting IAM inline policy from role: ${ROLE_NAME}"

aws iam delete-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name S3VectorsKbPolicy \
  --no-cli-pager 2>/dev/null || true

echo "Detaching AmazonS3ReadOnlyAccess"

aws iam detach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --no-cli-pager 2>/dev/null || true

echo "Detaching AmazonBedrockFullAccess"

aws iam detach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess \
  --no-cli-pager 2>/dev/null || true

echo "Cleanup completed successfully."


