# ============================================================
# Configuration
# ============================================================

$Region = "us-east-1"
$RoleName = "kb-s3vectors-docs-role"
$BucketPrefix = "kb-docs-bucket"
$VectorBucketPrefix = "kb-docs-vectors"
$IndexName = "kb-docs-index"
$KbName = "kb-demo"

# ============================================================
# Helper functions
# ============================================================

function Log($Message) {
    Write-Host "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# ============================================================
# Step 0: AWS / Account information
# ============================================================

Log "Step 0: Getting AWS account information"

$AccountId = aws sts get-caller-identity --query Account --output text --no-cli-pager
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccountId)) {
    Write-Error "Unable to determine AWS Account ID."
    exit 1
}

$Bucket = "${BucketPrefix}-${AccountId}"
$VectorBucket = "${VectorBucketPrefix}-${AccountId}"

# ============================================================
# Step 1: Delete Knowledge Base
# ============================================================

Log "Step 1: Finding and deleting Knowledge Base"

$KbId = aws bedrock-agent list-knowledge-bases `
    --query "knowledgeBaseSummaries[?name=='$KbName'].knowledgeBaseId|[0]" `
    --output text `
    --no-cli-pager

if (-not [string]::IsNullOrWhiteSpace($KbId) -and $KbId -ne "None") {
    Write-Host "Deleting Knowledge Base: $KbId"
    aws bedrock-agent delete-knowledge-base --knowledge-base-id $KbId --no-cli-pager 2>$null | Out-Null
}

# ============================================================
# Step 2: Delete S3 buckets
# ============================================================

Log "Step 2: Deleting S3 buckets"

Write-Host "Deleting S3 bucket: $Bucket"
aws s3 rb "s3://$Bucket" --force --region $Region --no-cli-pager 2>$null | Out-Null

# ============================================================
# Step 3: Delete S3 Vector index and bucket
# ============================================================

Log "Step 3: Deleting S3 Vector index and bucket"

Write-Host "Deleting S3 Vector index: $IndexName"
aws s3vectors delete-index `
    --vector-bucket-name $VectorBucket `
    --index-name $IndexName `
    --no-cli-pager 2>$null | Out-Null

Write-Host "Deleting S3 Vector bucket: $VectorBucket"
aws s3vectors delete-vector-bucket `
    --vector-bucket-name $VectorBucket `
    --no-cli-pager 2>$null | Out-Null

# ============================================================
# Step 4: Cleanup IAM role policies
# ============================================================

Log "Step 4: Cleanup IAM role policies"

Write-Host "Deleting IAM inline policy from role: $RoleName"
aws iam delete-role-policy `
    --role-name $RoleName `
    --policy-name S3VectorsKbPolicy `
    --no-cli-pager 2>$null | Out-Null

Write-Host "Detaching Managed Policies"
aws iam detach-role-policy `
    --role-name $RoleName `
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess `
    --no-cli-pager 2>$null | Out-Null

aws iam detach-role-policy `
    --role-name $RoleName `
    --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess `
    --no-cli-pager 2>$null | Out-Null

Log "Cleanup completed successfully."
