ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager)
REGION="us-east-1"
BUCKET="kb-demo-${ACCOUNT_ID}"
VECTOR_BUCKET="kb-demo-vectors-${ACCOUNT_ID}"
INDEX_NAME="kb-demo-index"
ROLE_NAME="kb-demo-role"

# 1. Re-create Buckets & Index with Metadata Registration
aws s3 mb s3://"${BUCKET}" --region ${REGION} --no-cli-pager 2>/dev/null || true
aws s3vectors create-vector-bucket --vector-bucket-name "${VECTOR_BUCKET}" --region ${REGION} --no-cli-pager 2>/dev/null || true

aws s3vectors create-index --vector-bucket-name "${VECTOR_BUCKET}" --index-name ${INDEX_NAME} \
  --data-type float32 --dimension 1024 --distance-metric cosine \
  --metadata-configuration '{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_TEXT","AMAZON_BEDROCK_METADATA"]}' \
  --region ${REGION} --no-cli-pager 2>/dev/null || true

# 2. Upload Sample Documents
echo "Travel: Europe accommodation €130/night. Manager approval required." | aws s3 cp - s3://"${BUCKET}"/travel.txt --no-cli-pager
echo "IT: Home office budget \$500/year. VPN required for remote work." | aws s3 cp - s3://"${BUCKET}"/it.txt --no-cli-pager

# 3. Create IAM Role with Fixed Permissions
aws iam create-role --role-name ${ROLE_NAME} --no-cli-pager \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

aws iam put-role-policy --role-name ${ROLE_NAME} --policy-name FullKbPolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
        \"Resource\": [\"arn:aws:s3:::${BUCKET}\", \"arn:aws:s3:::${BUCKET}/*\"]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3vectors:*\"],
        \"Resource\": [\"*\"]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"bedrock:InvokeModel\"],
        \"Resource\": [\"arn:aws:bedrock:${REGION}::foundation-model/amazon.titan-embed-text-v2:0\"]
      }
    ]
  }" --no-cli-pager

# 4. Attach Bucket Resource Policy
aws s3vectors put-vector-bucket-policy --vector-bucket-name "${VECTOR_BUCKET}" \
  --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"${ROLE_ARN}\"},\"Action\":\"s3vectors:*\",\"Resource\":\"arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}\"}]}" \
  --region ${REGION} --no-cli-pager 2>/dev/null || true

sleep 15

# 5. Create Knowledge Base & Data Source
KB_ID=$(aws bedrock-agent create-knowledge-base --name kb-demo --role-arn "${ROLE_ARN}" \
  --knowledge-base-configuration '{"type":"VECTOR","vectorKnowledgeBaseConfiguration":{"embeddingModelArn":"arn:aws:bedrock:'"${REGION}"'::foundation-model/amazon.titan-embed-text-v2:0"}}' \
  --storage-configuration "{\"type\":\"S3_VECTORS\",\"s3VectorsConfiguration\":{\"vectorBucketArn\":\"arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}\",\"indexName\":\"${INDEX_NAME}\"}}" \
  --region ${REGION} --no-cli-pager --query 'knowledgeBase.knowledgeBaseId' --output text)

sleep 10

DS_ID=$(aws bedrock-agent create-data-source --knowledge-base-id "${KB_ID}" --name policies \
  --data-source-configuration "{\"type\":\"S3\",\"s3Configuration\":{\"bucketArn\":\"arn:aws:s3:::${BUCKET}\"}}" \
  --region ${REGION} --no-cli-pager --query 'dataSource.dataSourceId' --output text)

# 6. Trigger and Monitor Ingestion Job
JOB_ID=$(aws bedrock-agent start-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" \
  --region ${REGION} --query 'ingestionJob.ingestionJobId' --output text --no-cli-pager)

echo "Ingestion Job Started: ${JOB_ID}"
sleep 20

aws bedrock-agent get-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --ingestion-job-id "${JOB_ID}" --region ${REGION} --no-cli-pager

echo "KB_ID: ${KB_ID}"
echo "DS_ID: ${DS_ID}"
echo "JOB_ID: ${JOB_ID}"