#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

# Use the directory containing this script so documents are loaded from rag-demo
# regardless of the caller's current working directory.
LOCAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

REGION="us-east-1"

BUCKET_PREFIX="kb-docs-bucket"
VECTOR_BUCKET_PREFIX="kb-docs-vectors"

BUCKET=""
VECTOR_BUCKET=""

INDEX_NAME="kb-docs-index"
ROLE_NAME="kb-s3vectors-docs-role"
KB_NAME="kb-demo"
DATA_SOURCE_NAME="documents-source"

EMBEDDING_MODEL_ID="amazon.titan-embed-text-v2:0"

# Titan Embed Text V2 supports 1024-dimensional embeddings.
EMBEDDING_DIMENSION=1024

CHUNK_MAX_TOKENS=300
CHUNK_OVERLAP_PERCENTAGE=20

# ============================================================
# Helper functions
# ============================================================

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

# ============================================================
# Step 0: AWS / Account information
# ============================================================

log "Step 0: Getting AWS account information"

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text \
    --no-cli-pager)

if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
    error "Unable to determine AWS Account ID."
fi

BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}"
VECTOR_BUCKET="${VECTOR_BUCKET_PREFIX}-${ACCOUNT_ID}"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

VECTOR_BUCKET_ARN="arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}"

INDEX_ARN="${VECTOR_BUCKET_ARN}/index/${INDEX_NAME}"

EMBEDDING_MODEL_ARN="arn:aws:bedrock:${REGION}::foundation-model/${EMBEDDING_MODEL_ID}"

log "AWS configuration:"
echo "  Account ID          : ${ACCOUNT_ID}"
echo "  Region              : ${REGION}"
echo "  S3 Bucket           : ${BUCKET}"
echo "  Vector Bucket       : ${VECTOR_BUCKET}"
echo "  Vector Index        : ${INDEX_NAME}"
echo "  Vector Index ARN    : ${INDEX_ARN}"
echo "  IAM Role            : ${ROLE_NAME}"
echo "  Embedding Model     : ${EMBEDDING_MODEL_ID}"

# ============================================================
# Step 1: Validate local directory
# ============================================================

log "Step 1: Validating local document directory"

if [[ ! -d "${LOCAL_DIR}" ]]; then
    error "Local directory does not exist: ${LOCAL_DIR}"
fi

cd "${LOCAL_DIR}"

# ============================================================
# Step 2: Create S3 bucket
# ============================================================

log "Step 2: Creating S3 bucket"

if aws s3api head-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --no-cli-pager 2>/dev/null; then

    echo "S3 bucket already exists: ${BUCKET}"

else

    aws s3 mb "s3://${BUCKET}" \
        --region "${REGION}" \
        --no-cli-pager

    echo "Created S3 bucket: ${BUCKET}"

fi

# ============================================================
# Step 3: Clean existing S3 objects
# ============================================================

log "Step 3: Cleaning existing S3 objects"

aws s3 rm "s3://${BUCKET}/" \
    --recursive \
    --region "${REGION}" \
    --no-cli-pager || true

# ============================================================
# Step 4: Upload documents
# ============================================================

log "Step 4: Uploading documents"

FOUND_DOCUMENTS=false

for file in *; do

    if [[ -f "${file}" ]]; then

        case "${file}" in

            *.pdf|*.PDF|*.txt|*.TXT|*.md|*.MD)

                FOUND_DOCUMENTS=true

                echo "Uploading: ${file}"

                aws s3 cp \
                    "${file}" \
                    "s3://${BUCKET}/${file}" \
                    --region "${REGION}" \
                    --no-cli-pager

                ;;

        esac

    fi

done

if [[ "${FOUND_DOCUMENTS}" == false ]]; then
    error "No supported documents found in ${LOCAL_DIR}"
fi

echo
echo "Documents uploaded successfully."

aws s3 ls \
    "s3://${BUCKET}/" \
    --region "${REGION}" \
    --no-cli-pager

# ============================================================
# Step 5: Create S3 Vector bucket
# ============================================================

log "Step 5: Creating S3 Vector bucket"

aws s3vectors create-vector-bucket \
    --vector-bucket-name "${VECTOR_BUCKET}" \
    --region "${REGION}" \
    --no-cli-pager 2>/dev/null || true

echo "Vector bucket ready: ${VECTOR_BUCKET}"

# ============================================================
# Step 6: Create S3 Vector index
# ============================================================

log "Step 6: Creating S3 Vector index"

aws s3vectors create-index \
    --vector-bucket-name "${VECTOR_BUCKET}" \
    --index-name "${INDEX_NAME}" \
    --data-type float32 \
    --dimension "${EMBEDDING_DIMENSION}" \
    --distance-metric cosine \
    --metadata-configuration \
'{
    "nonFilterableMetadataKeys": [
        "AMAZON_BEDROCK_TEXT",
        "AMAZON_BEDROCK_METADATA"
    ]
}' \
    --region "${REGION}" \
    --no-cli-pager 2>/dev/null || true

echo "Vector index ready: ${INDEX_NAME}"

# ============================================================
# Step 7: Verify S3 Vector index
# ============================================================

log "Step 7: Verifying S3 Vector index"

aws s3vectors get-index \
    --vector-bucket-name "${VECTOR_BUCKET}" \
    --index-name "${INDEX_NAME}" \
    --region "${REGION}" \
    --no-cli-pager

# ============================================================
# Step 8: Create IAM role
# ============================================================

log "Step 8: Creating IAM role"

TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "bedrock.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "IAM role for Amazon Bedrock Knowledge Base using S3 Vectors" \
    --no-cli-pager 2>/dev/null || true

echo "IAM role ready: ${ROLE_NAME}"

# ============================================================
# Step 9: Configure IAM permissions
# ============================================================

log "Step 9: Configuring IAM permissions"

ROLE_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3DataSourceAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET}",
                "arn:aws:s3:::${BUCKET}/*"
            ]
        },
        {
            "Sid": "S3VectorAccess",
            "Effect": "Allow",
            "Action": [
                "s3vectors:PutVectors",
                "s3vectors:GetVectors",
                "s3vectors:DeleteVectors",
                "s3vectors:QueryVectors",
                "s3vectors:GetIndex"
            ],
            "Resource": "${INDEX_ARN}"
        },
        {
            "Sid": "BedrockEmbeddingModelAccess",
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel"
            ],
            "Resource": "${EMBEDDING_MODEL_ARN}"
        }
    ]
}
EOF
)

aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name S3VectorsKbPolicy \
    --policy-document "${ROLE_POLICY}" \
    --no-cli-pager

echo "IAM policy configured."

# ============================================================
# Step 10: Verify IAM role and policy
# ============================================================

log "Step 10: Verifying IAM role and policy"

aws iam get-role \
    --role-name "${ROLE_NAME}" \
    --no-cli-pager

aws iam get-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name S3VectorsKbPolicy \
    --no-cli-pager

# ============================================================
# IMPORTANT:
# No s3vectors put-vector-bucket-policy command here.
#
# The previous version failed with:
#
# ValidationException:
# Invalid principal in policy
#
# The Bedrock Knowledge Base role receives the required
# S3 Vectors permissions through the IAM identity policy above.
# ============================================================

log "Skipping S3 Vector bucket resource policy."

# ============================================================
# Step 11: Wait for IAM propagation
# ============================================================

log "Step 11: Waiting for IAM propagation"

sleep 30

aws iam get-role \
    --role-name "${ROLE_NAME}" \
    --no-cli-pager >/dev/null

echo "IAM role is available."

# ============================================================
# Step 12: Create Knowledge Base
# ============================================================

log "Step 12: Creating Knowledge Base"

KB_CONFIGURATION=$(cat <<EOF
{
    "type": "VECTOR",
    "vectorKnowledgeBaseConfiguration": {
        "embeddingModelArn": "${EMBEDDING_MODEL_ARN}"
    }
}
EOF
)

STORAGE_CONFIGURATION=$(cat <<EOF
{
    "type": "S3_VECTORS",
    "s3VectorsConfiguration": {
        "vectorBucketArn": "${VECTOR_BUCKET_ARN}",
        "indexName": "${INDEX_NAME}"
    }
}
EOF
)

KB_ID=$(aws bedrock-agent create-knowledge-base \
    --name "${KB_NAME}" \
    --role-arn "${ROLE_ARN}" \
    --knowledge-base-configuration "${KB_CONFIGURATION}" \
    --storage-configuration "${STORAGE_CONFIGURATION}" \
    --region "${REGION}" \
    --no-cli-pager \
    --query 'knowledgeBase.knowledgeBaseId' \
    --output text)

if [[ -z "${KB_ID}" || "${KB_ID}" == "None" ]]; then
    error "Knowledge Base creation failed."
fi

echo "Knowledge Base created successfully."
echo "KB_ID: ${KB_ID}"

# ============================================================
# Step 13: Wait before creating Data Source
# ============================================================

log "Step 13: Waiting for Knowledge Base"

sleep 10

# ============================================================
# Step 14: Create S3 Data Source
# ============================================================

log "Step 14: Creating S3 Data Source"

DATA_SOURCE_CONFIGURATION=$(cat <<EOF
{
    "type": "S3",
    "s3Configuration": {
        "bucketArn": "arn:aws:s3:::${BUCKET}"
    }
}
EOF
)

INGESTION_CONFIGURATION=$(cat <<EOF
{
    "chunkingConfiguration": {
        "chunkingStrategy": "FIXED_SIZE",
        "fixedSizeChunkingConfiguration": {
            "maxTokens": ${CHUNK_MAX_TOKENS},
            "overlapPercentage": ${CHUNK_OVERLAP_PERCENTAGE}
        }
    }
}
EOF
)

DS_ID=$(aws bedrock-agent create-data-source \
    --knowledge-base-id "${KB_ID}" \
    --name "${DATA_SOURCE_NAME}" \
    --data-source-configuration "${DATA_SOURCE_CONFIGURATION}" \
    --vector-ingestion-configuration "${INGESTION_CONFIGURATION}" \
    --region "${REGION}" \
    --no-cli-pager \
    --query 'dataSource.dataSourceId' \
    --output text)

if [[ -z "${DS_ID}" || "${DS_ID}" == "None" ]]; then
    error "Data Source creation failed."
fi

echo "Data Source created successfully."
echo "DS_ID: ${DS_ID}"

# ============================================================
# Step 15: Start ingestion
# ============================================================

log "Step 15: Starting ingestion job"

JOB_ID=$(aws bedrock-agent start-ingestion-job \
    --knowledge-base-id "${KB_ID}" \
    --data-source-id "${DS_ID}" \
    --region "${REGION}" \
    --query 'ingestionJob.ingestionJobId' \
    --output text \
    --no-cli-pager)

if [[ -z "${JOB_ID}" || "${JOB_ID}" == "None" ]]; then
    error "Unable to start ingestion job."
fi

echo "Ingestion job started successfully."
echo "JOB_ID: ${JOB_ID}"

# ============================================================
# Step 16: Monitor ingestion
# ============================================================

log "Step 16: Monitoring ingestion job"

while true; do

    JOB_DETAILS=$(aws bedrock-agent get-ingestion-job \
        --knowledge-base-id "${KB_ID}" \
        --data-source-id "${DS_ID}" \
        --ingestion-job-id "${JOB_ID}" \
        --region "${REGION}" \
        --no-cli-pager)

    STATUS=$(echo "${JOB_DETAILS}" | \
        python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["ingestionJob"]["status"])
')

    echo "Ingestion status: ${STATUS}"

    case "${STATUS}" in

        COMPLETE)

            echo
            echo "=========================================="
            echo "SUCCESS"
            echo "=========================================="
            echo "Document ingestion completed successfully."
            echo "=========================================="

            break
            ;;

        FAILED)

            echo
            echo "=========================================="
            echo "INGESTION FAILED"
            echo "=========================================="

            echo "${JOB_DETAILS}"

            echo "=========================================="
            echo "Failure reasons:"
            echo "=========================================="

            echo "${JOB_DETAILS}" | \
                python3 -c '
import json
import sys

data = json.load(sys.stdin)

job = data.get("ingestionJob", {})

reasons = job.get("failureReasons", [])

if reasons:
    for reason in reasons:
        print(reason)
else:
    print("No failureReasons returned.")
'

            exit 1
            ;;

        STOPPED)

            error "Ingestion job was stopped."

            ;;

        STARTING|IN_PROGRESS)

            sleep 10
            ;;

        *)

            echo "Unknown ingestion status: ${STATUS}"
            sleep 10
            ;;

    esac

done

# ============================================================
# Step 17: Final output
# ============================================================

echo
echo "=========================================="
echo "Knowledge Base Setup Completed"
echo "=========================================="
echo
echo "AWS Account : ${ACCOUNT_ID}"
echo "Region      : ${REGION}"
echo
echo "S3 Bucket   : ${BUCKET}"
echo "Vector Bucket: ${VECTOR_BUCKET}"
echo "Index       : ${INDEX_NAME}"
echo
echo "Knowledge Base ID : ${KB_ID}"
echo "Data Source ID    : ${DS_ID}"
echo "Ingestion Job ID  : ${JOB_ID}"
echo
echo "=========================================="