#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

LOCAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Target GCP Region & Location
REGION="us-central1"
LOCATION="global"  # Vertex Search Data Stores are usually created in 'global' or 'us' location

# Resource Names
BUCKET_PREFIX="rag-docs-bucket"
DATA_STORE_NAME="kb-docs-datastore"
ENGINE_NAME="kb-demo-engine"

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
# Step 0: Check Prerequisites & GCP Project ID
# ============================================================

log "Step 0: Checking GCP environment"

if ! command -v gcloud &> /dev/null; then
    error "gcloud CLI is not installed. Please install Google Cloud SDK."
fi

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    error "No GCP Project ID set. Run 'gcloud config set project <PROJECT_ID>'."
fi

BUCKET_NAME="${BUCKET_PREFIX}-${PROJECT_ID}"

log "GCP Configuration:"
echo "  Project ID     : ${PROJECT_ID}"
echo "  Region         : ${REGION}"
echo "  Location       : ${LOCATION}"
echo "  GCS Bucket     : gs://${BUCKET_NAME}"
echo "  Data Store     : ${DATA_STORE_NAME}"
echo "  Engine Name    : ${ENGINE_NAME}"

# Enable required APIs
log "Enabling required GCP APIs..."
gcloud services enable \
    storage.googleapis.com \
    discoveryengine.googleapis.com \
    aiplatform.googleapis.com \
    --project="${PROJECT_ID}"

# ============================================================
# Step 1: Validate local directory & Check Documents
# ============================================================

log "Step 1: Validating local document directory"

cd "${LOCAL_DIR}"

FOUND_DOCUMENTS=false
for file in *; do
    if [[ -f "${file}" ]]; then
        case "${file}" in
            *.pdf|*.PDF|*.txt|*.TXT|*.md|*.MD)
                FOUND_DOCUMENTS=true
                break
                ;;
        esac
    fi
done

if [[ "${FOUND_DOCUMENTS}" == false ]]; then
    error "No supported documents (.pdf, .txt, .md) found in ${LOCAL_DIR}"
fi

# ============================================================
# Step 2: Create GCS Storage Bucket
# ============================================================

log "Step 2: Creating GCS Bucket"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
    echo "GCS bucket already exists: gs://${BUCKET_NAME}"
else
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}"
    echo "Created GCS bucket: gs://${BUCKET_NAME}"
fi

# ============================================================
# Step 3: Sync local documents to GCS
# ============================================================

log "Step 3: Uploading documents to GCS"

gcloud storage rsync "${LOCAL_DIR}" "gs://${BUCKET_NAME}/" \
    --include-regex=".*\.(pdf|PDF|txt|TXT|md|MD)$" \
    --delete-unmatched-destination-objects

log "Current files in GCS:"
gcloud storage ls "gs://${BUCKET_NAME}/"

# ============================================================
# Step 4: Create Vertex AI Search Data Store
# ============================================================

log "Step 4: Creating Vertex AI Search Data Store"

# Check if data store exists
if ! gcloud discovery-engine data-stores describe "${DATA_STORE_NAME}" --location="${LOCATION}" &>/dev/null; then
    gcloud discovery-engine data-stores create "${DATA_STORE_NAME}" \
        --location="${LOCATION}" \
        --display-name="Knowledge Base Data Store" \
        --industry-vertical="GENERIC" \
        --solution-type="SOLUTION_TYPE_SEARCH" \
        --content-config="CONTENT_REQUIRED"
    echo "Data store creation initialized."
else
    echo "Data Store ${DATA_STORE_NAME} already exists."
fi

# ============================================================
# Step 5: Import Documents into Data Store (Triggers Indexing)
# ============================================================

log "Step 5: Ingesting documents from GCS into Data Store"

# Triggers document parsing, chunking, and auto-vectorization
gcloud discovery-engine data-stores import-documents "${DATA_STORE_NAME}" \
    --location="${LOCATION}" \
    --gcs-uri="gs://${BUCKET_NAME}/*" \
    --auto-generate-ids

log "Ingestion job submitted successfully."

# ============================================================
# Step 6: Create Search Engine connected to Data Store
# ============================================================

log "Step 6: Linking Data Store to a Search Engine"

if ! gcloud discovery-engine engines describe "${ENGINE_NAME}" --location="${LOCATION}" &>/dev/null; then
    gcloud discovery-engine engines create "${ENGINE_NAME}" \
        --location="${LOCATION}" \
        --collection-id="default_collection" \
        --data-store-ids="${DATA_STORE_NAME}" \
        --display-name="Knowledge Base Engine" \
        --engine-type="search"
    echo "Engine created successfully."
else
    echo "Engine ${ENGINE_NAME} already exists."
fi

echo
echo "=========================================="
echo "GCP Knowledge Base Setup Completed"
echo "=========================================="
echo "Project ID  : ${PROJECT_ID}"
echo "Data Store  : ${DATA_STORE_NAME}"
echo "Engine ID   : ${ENGINE_NAME}"
echo "GCS Bucket  : gs://${BUCKET_NAME}"
echo "=========================================="