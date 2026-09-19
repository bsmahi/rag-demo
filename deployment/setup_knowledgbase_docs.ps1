# ============================================================
# Configuration
# ============================================================

$Region = "us-east-1"
$BucketPrefix = "kb-docs-bucket"
$VectorBucketPrefix = "kb-docs-vectors"
$IndexName = "kb-docs-index"
$RoleName = "kb-s3vectors-docs-role"
$KbName = "kb-demo"
$DataSourceName = "documents-source"
$EmbeddingModelId = "amazon.titan-embed-text-v2:0"
$EmbeddingDimension = 1024
$ChunkMaxTokens = 300
$ChunkOverlapPercentage = 20

# ============================================================
# Helper functions
# ============================================================

function Log($Message) {
    Write-Host "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Error-Exit($Message) {
    Write-Error "ERROR: $Message"
    exit 1
}

# ============================================================
# Step 0: AWS / Account information
# ============================================================

Log "Step 0: Getting AWS account information"

$AccountId = aws sts get-caller-identity --query Account --output text --no-cli-pager
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccountId)) {
    Error-Exit "Unable to determine AWS Account ID."
}

$Bucket = "${BucketPrefix}-${AccountId}"
$VectorBucket = "${VectorBucketPrefix}-${AccountId}"
$RoleArn = "arn:aws:iam::${AccountId}:role/${RoleName}"
$VectorBucketArn = "arn:aws:s3vectors:${Region}:${AccountId}:bucket/${VectorBucket}"
$IndexArn = "${VectorBucketArn}/index/${IndexName}"
$EmbeddingModelArn = "arn:aws:bedrock:${Region}::foundation-model/${EmbeddingModelId}"

Log "AWS configuration:"
Write-Host "  Account ID          : $AccountId"
Write-Host "  Region              : $Region"
Write-Host "  S3 Bucket           : $Bucket"
Write-Host "  Vector Bucket       : $VectorBucket"
Write-Host "  Vector Index        : $IndexName"
Write-Host "  Vector Index ARN    : $IndexArn"
Write-Host "  IAM Role            : $RoleName"
Write-Host "  Embedding Model     : $EmbeddingModelId"

# ============================================================
# Step 1: Validate local directory
# ============================================================

Log "Step 1: Validating local document directory"
$LocalDocsDir = Join-Path -Path (Get-Item $PSScriptRoot).Parent.FullName -ChildPath "docs"
if (-not (Test-Path -Path $LocalDocsDir)) {
    Error-Exit "Local document directory does not exist: $LocalDocsDir"
}

Set-Location -Path $LocalDocsDir

# ============================================================
# Step 2: Create S3 bucket
# ============================================================

Log "Step 2: Creating S3 bucket"

if (aws s3api head-bucket --bucket $Bucket --region $Region --no-cli-pager 2>$null) {
    Write-Host "S3 bucket already exists: $Bucket"
} else {
    aws s3 mb "s3://$Bucket" --region $Region --no-cli-pager
    Write-Host "Created S3 bucket: $Bucket"
}

# ============================================================
# Step 3: Clean existing S3 objects
# ============================================================

Log "Step 3: Cleaning existing S3 objects"

aws s3 rm "s3://$Bucket/" --recursive --region $Region --no-cli-pager | Out-Null

# ============================================================
# Step 4: Upload documents
# ============================================================

Log "Step 4: Uploading documents"

$Files = Get-ChildItem -File
$FoundDocuments = $false

foreach ($File in $Files) {
    if ($File.Extension -match '\.pdf|\.txt|\.md') {
        $FoundDocuments = $true
        Write-Host "Uploading: $($File.Name)"
        aws s3 cp "$($File.FullName)" "s3://$Bucket/$($File.Name)" --region $Region --no-cli-pager
    }
}

if (-not $FoundDocuments) {
    Error-Exit "No supported documents found in $LocalDocsDir"
}

Write-Host "`nDocuments uploaded successfully."
aws s3 ls "s3://$Bucket/" --region $Region --no-cli-pager

# ============================================================
# Step 5: Create S3 Vector bucket
# ============================================================

Log "Step 5: Creating S3 Vector bucket"

aws s3vectors create-vector-bucket --vector-bucket-name $VectorBucket --region $Region --no-cli-pager 2>$null | Out-Null
Write-Host "Vector bucket ready: $VectorBucket"

# ============================================================
# Step 6: Create S3 Vector index
# ============================================================

Log "Step 6: Creating S3 Vector index"

$MetadataConfig = '{
    "nonFilterableMetadataKeys": [
        "AMAZON_BEDROCK_TEXT",
        "AMAZON_BEDROCK_METADATA"
    ]
}'

aws s3vectors create-index `
    --vector-bucket-name $VectorBucket `
    --index-name $IndexName `
    --data-type float32 `
    --dimension $EmbeddingDimension `
    --distance-metric cosine `
    --metadata-configuration $MetadataConfig `
    --region $Region `
    --no-cli-pager 2>$null | Out-Null

Write-Host "Vector index ready: $IndexName"

# ============================================================
# Step 7: Verify S3 Vector index
# ============================================================

Log "Step 7: Verifying S3 Vector index"

aws s3vectors get-index --vector-bucket-name $VectorBucket --index-name $IndexName --region $Region --no-cli-pager

# ============================================================
# Step 8: Create IAM role
# ============================================================

Log "Step 8: Creating IAM role"

$TrustPolicy = @"
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
"@

$TrustPolicyFile = "trust-policy.json"
$TrustPolicy | Out-File -FilePath $TrustPolicyFile -Encoding utf8

aws iam create-role `
    --role-name $RoleName `
    --assume-role-policy-document "file://$TrustPolicyFile" `
    --description "IAM role for Amazon Bedrock Knowledge Base using S3 Vectors" `
    --no-cli-pager 2>$null | Out-Null

Remove-Item -Path $TrustPolicyFile
Write-Host "IAM role ready: $RoleName"

# ============================================================
# Step 9: Configure IAM permissions
# ============================================================

Log "Step 9: Configuring IAM permissions"

$RolePolicy = @"
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
                "arn:aws:s3:::$Bucket",
                "arn:aws:s3:::$Bucket/*"
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
            "Resource": "$IndexArn"
        },
        {
            "Sid": "BedrockEmbeddingModelAccess",
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel"
            ],
            "Resource": "$EmbeddingModelArn"
        }
    ]
}
"@

$RolePolicyFile = "role-policy.json"
$RolePolicy | Out-File -FilePath $RolePolicyFile -Encoding utf8

aws iam put-role-policy `
    --role-name $RoleName `
    --policy-name S3VectorsKbPolicy `
    --policy-document "file://$RolePolicyFile" `
    --no-cli-pager | Out-Null

Remove-Item -Path $RolePolicyFile
Write-Host "IAM policy configured."

# ============================================================
# Step 10: Verify IAM role and policy
# ============================================================

Log "Step 10: Verifying IAM role and policy"

aws iam get-role --role-name $RoleName --no-cli-pager
aws iam get-role-policy --role-name $RoleName --policy-name S3VectorsKbPolicy --no-cli-pager

# ============================================================
# Step 11: Wait for IAM propagation
# ============================================================

Log "Step 11: Waiting for IAM propagation"
Start-Sleep -Seconds 30

# ============================================================
# Step 12: Create Knowledge Base
# ============================================================

Log "Step 12: Creating Knowledge Base"

$KbConfig = @"
{
    "type": "VECTOR",
    "vectorKnowledgeBaseConfiguration": {
        "embeddingModelArn": "$EmbeddingModelArn"
    }
}
"@

$StorageConfig = @"
{
    "type": "S3_VECTORS",
    "s3VectorsConfiguration": {
        "vectorBucketArn": "$VectorBucketArn",
        "indexName": "$IndexName"
    }
}
"@

$KbConfigFile = "kb-config.json"
$StorageConfigFile = "storage-config.json"
$KbConfig | Out-File -FilePath $KbConfigFile -Encoding utf8
$StorageConfig | Out-File -FilePath $StorageConfigFile -Encoding utf8

$KbId = aws bedrock-agent create-knowledge-base `
    --name $KbName `
    --role-arn $RoleArn `
    --knowledge-base-configuration "file://$KbConfigFile" `
    --storage-configuration "file://$StorageConfigFile" `
    --region $Region `
    --no-cli-pager `
    --query 'knowledgeBase.knowledgeBaseId' `
    --output text

if ([string]::IsNullOrWhiteSpace($KbId) -or $KbId -eq "None") {
    Error-Exit "Knowledge Base creation failed."
}

Remove-Item -Path $KbConfigFile
Remove-Item -Path $StorageConfigFile

Write-Host "Knowledge Base created successfully."
Write-Host "KB_ID: $KbId"

# ============================================================
# Step 13: Wait before creating Data Source
# ============================================================

Log "Step 13: Waiting for Knowledge Base"
Start-Sleep -Seconds 10

# ============================================================
# Step 14: Create S3 Data Source
# ============================================================

Log "Step 14: Creating S3 Data Source"

$DataSourceConfig = @"
{
    "type": "S3",
    "s3Configuration": {
        "bucketArn": "arn:aws:s3:::$Bucket"
    }
}
"@

$DataSourceConfigFile = "datasource-config.json"
$DataSourceConfig | Out-File -FilePath $DataSourceConfigFile -Encoding utf8

$DataSourceId = aws bedrock-agent create-data-source `
    --knowledge-base-id $KbId `
    --name $DataSourceName `
    --data-source-configuration "file://$DataSourceConfigFile" `
    --region $Region `
    --no-cli-pager `
    --query 'dataSource.dataSourceId' `
    --output text

if ([string]::IsNullOrWhiteSpace($DataSourceId) -or $DataSourceId -eq "None") {
    Error-Exit "Data Source creation failed."
}

Remove-Item -Path $DataSourceConfigFile

Write-Host "Data Source created successfully."
Write-Host "Data Source ID: $DataSourceId"

# ============================================================
# Step 15: Start ingestion job
# ============================================================

Log "Step 15: Starting ingestion job"

$IngestionJobId = aws bedrock-agent start-ingestion-job `
    --knowledge-base-id $KbId `
    --data-source-id $DataSourceId `
    --region $Region `
    --no-cli-pager `
    --query 'ingestionJob.ingestionJobId' `
    --output text

if ([string]::IsNullOrWhiteSpace($IngestionJobId) -or $IngestionJobId -eq "None") {
    Error-Exit "Ingestion job failed to start."
}

Write-Host "Ingestion job started."
Write-Host "Ingestion Job ID: $IngestionJobId"

Log "Step 16: Waiting for ingestion job to complete"

while ($true) {
    $Status = aws bedrock-agent get-ingestion-job `
        --knowledge-base-id $KbId `
        --data-source-id $DataSourceId `
        --ingestion-job-id $IngestionJobId `
        --region $Region `
        --no-cli-pager `
        --query 'ingestionJob.status' `
        --output text

    Write-Host "Ingestion job status: $Status"

    if ($Status -eq "COMPLETE") {
        Write-Host "Ingestion complete."
        break
    } elseif ($Status -eq "FAILED") {
        Error-Exit "Ingestion job failed."
    }

    Start-Sleep -Seconds 30
}

Log "Setup complete."
