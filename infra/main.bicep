// Resource Group dahil tüm altyapı buradan yönetilir. RG-seviyesi kaynaklar
// resources.bicep modülüne devredilir; Bicep'te bir dosya tek scope'ta çalışır.

targetScope = 'subscription'

// Uzunluk sınırları, 'st{project}{environment}' storage adının Azure'un
// 3-24 karakter kuralını her kombinasyonda karşılamasını garanti eder.
@description('Proje kısa adı; kaynak isimlendirmesinde kullanılır.')
@minLength(3)
@maxLength(11)
param project string = 'imgresizer'

@description('Ortam adı; yalnızca isimlendirmede kullanılır.')
@minLength(2)
@maxLength(6)
param environment string = 'dev'

@description('Flex Consumption desteklemelidir: az functionapp list-flexconsumption-locations')
param location string = 'westeurope'

@description('512 = 0.25 vCPU. Thumbnail üretimi için yeterli; OutOfMemoryException görülürse artırın.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 512

@description('Scale-out tavanı. Rezervasyon değildir; hatalı döngülerde blast radius sınırlar.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 5

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${project}-${environment}'
  location: location
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    project: project
    environment: environment
    location: location
    instanceMemoryMB: instanceMemoryMB
    maximumInstanceCount: maximumInstanceCount
  }
}

output resourceGroupName string = rg.name
output functionAppName string = resources.outputs.functionAppName
output storageAccountName string = resources.outputs.storageAccountName
