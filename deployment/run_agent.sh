#!/usr/bin/env bash
set -e

# Fetch Knowledge Base ID by name
KB_ID=$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='kb-demo'].knowledgeBaseId|[0]" \
  --output text \
  --no-cli-pager)

# Check if KB_ID was found
if [ -z "${KB_ID}" ] || [ "${KB_ID}" == "None" ]; then
  echo "Error: Knowledge Base 'kb-demo' not found."
  exit 1
fi

echo "KB: ${KB_ID}"

# Run the JBang script with the retrieved ID
SPRING_AI_VECTORSTORE_BEDROCK_KNOWLEDGE_BASE_KNOWLEDGE_BASE_ID="${KB_ID}" jbang ../KnowledgeAgent.java
