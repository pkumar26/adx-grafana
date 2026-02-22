// ADX Schema Initialization — Kusto Database Script
// Creates tables, mappings, policies, and materialized views via a database script.
// This ensures the schema exists BEFORE the Event Grid data connection is created,
// preventing the "Table does not exist" validation error on the data connection.
// All KQL commands are idempotent (.create-merge, .create-or-alter, .create ifnotexists).

@description('Name of the ADX cluster')
param clusterName string

@description('Name of the ADX database')
param databaseName string

@description('Optional: Explicit version tag to force re-execution. Leave empty to auto-detect from KQL content hash.')
param schemaVersion string = ''

// Load KQL schema files (resolved at Bicep compile time)
var tablesKql = loadTextContent('../../kql/schema/tables.kql')
var policiesKql = loadTextContent('../../kql/schema/policies.kql')
var mappingsKql = loadTextContent('../../kql/schema/mappings.kql')
var viewsKql = loadTextContent('../../kql/schema/materialized-views.kql')

// Concatenate all schema commands in dependency order:
// 1. Tables (target, staging, dead-letter)
// 2. Policies (transform function, update policy, retention, batching)
// 3. Mappings (CSV, JSON ingestion mappings)
// 4. Materialized Views (DailySummary)
var fullSchemaScript = '${tablesKql}\n\n${policiesKql}\n\n${mappingsKql}\n\n${viewsKql}'

// Auto-version from content hash — script re-runs when KQL files change
var effectiveVersion = !empty(schemaVersion) ? schemaVersion : uniqueString(fullSchemaScript)

// Reference existing cluster and database (created by adx-cluster module or pre-existing)
resource cluster 'Microsoft.Kusto/clusters@2024-04-13' existing = {
  name: clusterName
}

resource database 'Microsoft.Kusto/clusters/databases@2024-04-13' existing = {
  parent: cluster
  name: databaseName
}

// Kusto database script — runs management commands sequentially against the database
resource schemaScript 'Microsoft.Kusto/clusters/databases/scripts@2024-04-13' = {
  parent: database
  name: 'init-schema'
  properties: {
    #disable-next-line use-secure-value-for-secure-inputs // scriptContent contains non-sensitive KQL schema DDL
    scriptContent: fullSchemaScript
    continueOnErrors: false
    forceUpdateTag: effectiveVersion
  }
}

@description('Schema script resource ID')
output schemaScriptId string = schemaScript.id
