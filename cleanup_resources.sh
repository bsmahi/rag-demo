#!/usr/bin/env bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text \
  --no-cli-pager)

KB_ID=$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='kb-demo'].knowledgeBaseId|[0]" \
  --output text \
  --no-cli-pager)

if [ "${KB_ID}" != "None" ] && [ -n "${KB_ID}" ]; then
  echo "Deleting Knowledge Base: ${KB_ID}"

  aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "${KB_ID}" \
    --no-cli-pager 2>/dev/null || true
fi

echo "Deleting S3 bucket: kb-demo-${ACCOUNT_ID}"

aws s3 rb "s3://kb-demo-${ACCOUNT_ID}" \
  --force \
  --no-cli-pager 2>/dev/null || true

echo "Deleting S3 Vector index"

aws s3vectors delete-index \
  --vector-bucket-name "kb-demo-vectors-${ACCOUNT_ID}" \
  --index-name "kb-demo-index" \
  --no-cli-pager 2>/dev/null || true

echo "Deleting S3 Vector bucket"

aws s3vectors delete-vector-bucket \
  --vector-bucket-name "kb-demo-vectors-${ACCOUNT_ID}" \
  --no-cli-pager 2>/dev/null || true

echo "Deleting IAM inline policy"

aws iam delete-role-policy \
  --role-name kb-demo-role \
  --policy-name s3vectors \
  --no-cli-pager 2>/dev/null || true

echo "Detaching AmazonS3ReadOnlyAccess"

aws iam detach-role-policy \
  --role-name kb-demo-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --no-cli-pager 2>/dev/null || true

echo "Detaching AmazonBedrockFullAccess"

aws iam detach-role-policy \
  --role-name kb-demo-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess \
  --no-cli-pager 2>/dev/null || true

echo "Cleanup completed successfully."


