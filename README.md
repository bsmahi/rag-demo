## Purpose
This repository is a minimal Amazon Bedrock Knowledge Base demo. It loads documents into S3, creates a vector index with S3 Vectors, configures an IAM role and Bedrock Knowledge Base, and exposes a small Spring AI Java app that answers questions grounded in the indexed content.

## Repository layout
- `deployment/setup_knowledgbase_docs.sh` — full end-to-end setup for provisioning AWS resources and ingesting local docs.
- `deployment/setup_kb.sh` — older/alternate sample setup script for a smaller demo.
- `deployment/run_agent.sh` — resolves the Knowledge Base ID for `kb-demo` and starts the Java app.
- `KnowledgeAgent.java` — Spring Boot + Spring AI app exposing `POST /chat`.
- `index.html` — simple browser UI that calls the local `/chat` endpoint.
- PDF and text documents in the `docs/` folder are examples that can be uploaded to the knowledge base.

## Required tooling
- AWS CLI configured with valid credentials and access to the target account.
- `jbang` installed for running `KnowledgeAgent.java`.
- Region is expected to be `us-east-1` unless you intentionally modify scripts.

## Install jbang
If `jbang` is not already installed, install it before starting the Java app.

### macOS
```bash
# Homebrew
brew install jbang

# Or via SDKMAN
curl -s "https://get.sdkman.io" | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
sdk install java
sdk install jbang
```

### Linux
```bash
# Official installer
curl -Ls https://sh.jbang.dev | bash

# Or via SDKMAN
curl -s "https://get.sdkman.io" | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
sdk install java
sdk install jbang

# Debian/Ubuntu examples
sudo apt update
sudo apt install -y curl
curl -Ls https://sh.jbang.dev | bash
```

### Windows
PowerShell:
```powershell
# WinGet
winget install --id jbangdev.jbang -e

# Or Chocolatey
choco install jbang -y

# Or via SDKMAN (requires a Unix-like shell environment such as Git Bash or WSL)
curl -s "https://get.sdkman.io" | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
sdk install java
sdk install jbang
```

Then verify the installation:

```bash
jbang --version
```

## AWS resource conventions
This project assumes the following names unless changed explicitly:
- Knowledge Base name: `kb-demo`
- Role name: `kb-s3vectors-docs-role` in `setup_knowledgbase_docs.sh`
- Vector index name: `kb-docs-index`
- Data source name: `documents-source`
- Embedding model: `amazon.titan-embed-text-v2:0`

Important: `run_agent.sh` looks up the Bedrock Knowledge Base by the literal name `kb-demo`. If you rename the KB in setup scripts, update `run_agent.sh` too.

## Typical setup flow
1. Configure AWS credentials and ensure the CLI can access the account.
2. Run:
   ```bash
   # Linux/macOS
   bash deployment/setup_knowledgbase_docs.sh

   # Windows (CMD/PowerShell)
   deployment/setup_knowledgbase_docs.bat
   ```
   This script will:
   - create the S3 document bucket
   - upload supported files from the repo root (`.pdf`, `.txt`, `.md`)
   - create the S3 Vectors bucket and index
   - set IAM permissions for Bedrock + S3 vectors
   - create a Bedrock Knowledge Base and data source
   - start the ingestion job and wait for completion
3. Launch the Java app:
   ```bash
   bash deployment/run_agent.sh
   ```
   This resolves the Knowledge Base ID and runs:
   ```bash
   jbang KnowledgeAgent.java
   ```

4. To clean up created resources:
   ```bash
   # Linux/macOS
   bash deployment/cleanup_resources.sh

   # Windows (CMD/PowerShell)
   deployment/cleanup_resources.bat
   ```

## Local app behavior
- The application starts as a Spring Boot REST API on port `8080`.
- The endpoint:
  ```http
  POST /chat
  ```
  accepts a plain-text prompt and returns the model response grounded in the connected Knowledge Base.
- The browser UI in `index.html` sends POST requests to `http://localhost:8080/chat`.

## Architecture overview

![High-level architecture](./architecture-diagram.svg)

This architecture follows a simple RAG flow:
- user prompt enters via the browser UI
- `kbAgent.java` calls the Bedrock-backed knowledge base retrieval layer
- source documents are stored in S3 and ingested into S3 Vector storage
- the embedding model creates vector representations for semantic search
- the app returns a grounded answer using the indexed knowledge

## RAG architecture details

This repository demonstrates a classic retrieval-augmented generation pattern for grounded question answering. In a typical enterprise RAG workflow, the system does the following:

1. Ingest documents into a searchable store.
   - Source files live in the repo and are uploaded to S3.
   - The ingestion process chunks and embeds the content so it can be found semantically.
2. Embed documents and store vectors.
   - The embedding model converts text into vector representations.
   - These vectors are stored in S3 Vectors and indexed for similarity search.
3. Retrieve relevant context at runtime.
   - When a user submits a prompt, the app retrieves the most relevant passages from the knowledge base.
   - This retrieval step is based on semantic similarity between the user question and the indexed content.
4. Generate a grounded answer.
   - The retrieved chunks are passed to the language model alongside the prompt.
   - The model answers using the retrieved context, reducing hallucination and improving factual grounding.

### Common RAG patterns in Amazon Bedrock

A production RAG architecture can vary depending on the use case, but the most common patterns are:

- Basic RAG:
  - Documents are chunked, embedded, and stored in a vector database.
  - At runtime, a retriever fetches the top-k passages and the model generates the answer.
  - This is the pattern used in this demo.

- Metadata-aware RAG:
  - Documents are enriched with metadata such as document type, date, owner, or category.
  - Retrieval can filter by metadata before or after vector search.
  - Useful for enterprise knowledge bases with multiple content sources.

- Hybrid search RAG:
  - Combines semantic vector search with keyword-based search.
  - Helpful when exact terms matter, such as product names, APIs, or compliance references.

- Agentic RAG:
  - The model decides when to retrieve, re-rank, or use tools before answering.
  - This is common for multistep research, action-taking workflows, and orchestration across systems.

- Grounded multi-hop RAG:
  - The model performs multiple retrieval stages to answer questions that require combining information from multiple documents.

### Why this repository uses Bedrock Knowledge Bases

Amazon Bedrock Knowledge Bases simplify the operational parts of RAG by providing a managed experience for:

- document ingestion
- chunking and embeddings
- vector storage and retrieval
- model grounding with knowledge source results
- integration with foundation models in Bedrock

This repository focuses on the essential flow: store knowledge in S3, index it for semantic retrieval, and ask questions through a small Java app.

## Amazon Bedrock reference links

Use the following official AWS documentation as the primary reference points for Bedrock Knowledge Bases and RAG:

- Amazon Bedrock overview: https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html
- Amazon Bedrock Knowledge Bases: https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-bases.html
- Creating and managing a knowledge base: https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-create.html
- Ingestion, parsing, and data source setup: https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-ingest.html
- Bedrock Agents overview: https://docs.aws.amazon.com/bedrock/latest/userguide/agents.html
- Amazon S3 Vectors overview: https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-vectors.html
- Bedrock model access and foundation model docs: https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html
- Bedrock Guardrails: https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html

## Development guidance for agents
- Keep AWS resource naming consistent across scripts unless the change is intentional and fully propagated.
- Prefer targeted edits to the existing scripts and Java app rather than introducing a new framework or architecture.
- If document ingestion or KB setup changes, update both the setup scripts and the runtime assumptions.
- Validate changes with the smallest relevant command:
  - shell syntax checks for scripts
  - local startup of `jbang KbAgent.java`
  - a quick `curl` check against `/chat` when the app is running
- Do not commit or expose AWS credentials or account details.

## Quick verification commands
```bash
bash -n deployment/setup_knowledgbase_docs.sh
bash -n deployment/run_agent.sh
jbang KnowledgeAgent.java
```

When the app is running, verify the endpoint with:
```bash
curl -X POST http://localhost:8080/chat \
  -H 'Content-Type: text/plain' \
  --data 'What documents are available in this knowledge base?'
```

