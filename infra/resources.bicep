@minLength(3)
@maxLength(11)
param project string

@minLength(2)
@maxLength(6)
param environment string

param location string
param instanceMemoryMB int
param maximumInstanceCount int

var suffix = '${project}-${environment}'
var storageAccountName = 'st${project}${environment}'
var deploymentContainerName = 'deploymentpackage'

// Rol isimleri değişebilir, GUID'ler sabittir.
var roleIds = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
}

// Tek hesap üç amaca hizmet eder: uygulama verisi, deployment paketi ve
// Functions host'unun kendi state container/queue/table'ları.
resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource appContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = [
  for name in ['uploads', 'thumbnails']: {
    parent: blobService
    name: name
  }
]

// Flex Consumption uygulama paketini buraya yazar ve buradan çalıştırır.
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: deploymentContainerName
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-${suffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// FC1/FlexConsumption; Linux zorunlu (reserved). Plan başına tek app barındırılabilir.
resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'asp-${suffix}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

// Flex Consumption'da runtime ve deployment, app setting yerine functionAppConfig ile
// tanımlanır. Bu planda ŞUNLAR AYARLANMAZ: WEBSITE_RUN_FROM_PACKAGE,
// WEBSITE_CONTENTAZUREFILECONNECTIONSTRING, WEBSITE_CONTENTSHARE,
// FUNCTIONS_WORKER_RUNTIME, FUNCTIONS_EXTENSION_VERSION.
resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: 'func-${suffix}'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true

    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }

    siteConfig: {
      appSettings: [
        {
          // Identity-based connection: host, hesap adından servis URI'lerini türetip
          // Managed Identity ile bağlanır. Connection string kullanılmaz.
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
      ]
    }
  }
}

// Blob Data Owner: deployment paketi, uploads/thumbnails ve host state container'ları.
// Queue: poison queue. Table: singleton koordinasyonu.
// guid() deterministiktir — tekrar deploy yeni atama üretmez.
resource storageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in items(roleIds): {
    scope: storage
    name: guid(storage.id, functionApp.id, roleId.value)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId.value)
      principalId: functionApp.identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output functionAppName string = functionApp.name
output storageAccountName string = storage.name
