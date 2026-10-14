# Infrastructure as Code

This directory contains the Bicep infrastructure definition for the
Azure Event-Driven Data Pipeline.

## Architecture

The infrastructure consists of:

- Azure Storage Account
  - Private `raw-data` blob container
- Azure Event Grid
  - Listens for `BlobCreated` events
- Azure Function
  - Python
  - Flex Consumption
  - System-assigned Managed Identity
- Azure Cosmos DB for NoSQL
  - Serverless
  - Database: `pipeline-db`
  - Container: `results`
  - Partition key: `/source_file`
- Application Insights
- Log Analytics Workspace

## Identity and RBAC

The Function App uses a system-assigned Managed Identity instead of
credentials stored in source code.

The identity receives:

- Storage Blob Data Owner
- Storage Queue Data Contributor
- Cosmos DB Built-in Data Contributor

Azure Storage permissions use Azure RBAC.

Cosmos DB document access uses Cosmos DB native data-plane RBAC.

## Event Grid

The Storage Account is configured as an Event Grid source.

Only `Microsoft.Storage.BlobCreated` events for the `raw-data`
container are relevant to the processing pipeline.

The deployed project uses the Azure Functions blob webhook endpoint
for Event Grid delivery.

The webhook requires a Functions system key. This secret is
intentionally not stored in the Bicep template or repository.

## Deployment

The Bicep template can be validated locally with:

```powershell
az bicep build --file infrastructure/main.bicep
```

Resource names such as the Storage Account and Cosmos DB account are
parameters because these names must be globally unique.

## Security

Secrets and local configuration files are excluded from source control.

The application uses Managed Identity and RBAC for access to Azure
resources rather than storing Cosmos DB credentials in application
code.