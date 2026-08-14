// Uygulama kodu deploy EDİLDİKTEN SONRA çalıştırılmalıdır: event subscription'ın hedefi
// .../functions/ResizeImage kaynağıdır ve bu kaynak ancak kod deploy edilince oluşur.
// Erken çalıştırılırsa: "Endpoint validation: Destination endpoint not found".

@minLength(3)
@maxLength(11)
param project string = 'imgresizer'

@minLength(2)
@maxLength(6)
param environment string = 'dev'

param location string = resourceGroup().location

@description('C# tarafındaki [Function(nameof(...))] ile birebir aynı olmalıdır.')
param functionName string = 'ResizeImage'

param sourceContainer string = 'uploads'

var suffix = '${project}-${environment}'

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: 'st${project}${environment}'
}

resource functionApp 'Microsoft.Web/sites@2024-11-01' existing = {
  name: 'func-${suffix}'
}

resource systemTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' = {
  name: 'egst-${suffix}'
  location: location
  properties: {
    source: storage.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: systemTopic
  name: 'sub-${sourceContainer}-to-${toLower(functionName)}'
  properties: {
    destination: {
      // Event Grid'in 'AzureFunction' hedefi yalnızca [EventGridTrigger] fonksiyonlarını
      // kabul eder. [BlobTrigger] + Source=EventGrid ise runtime'ın blob uzantı
      // webhook'una bağlanır; 'Host.Functions.' öneki zorunludur.
      //
      // code: blobs_extension system key'i — storage anahtarı değildir, yalnızca
      // webhook'u yetkisiz çağrıya karşı korur. Deploy anında okunur, kodda saklanmaz.
      endpointType: 'WebHook'
      properties: {
        endpointUrl: 'https://${functionApp.properties.defaultHostName}/runtime/webhooks/blobs?functionName=Host.Functions.${functionName}&code=${listKeys('${functionApp.id}/host/default', '2024-11-01').systemKeys.blobs_extension}'
        maxEventsPerBatch: 1
      }
    }

    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      // Fonksiyon thumbnails/ container'ına yazıyor; filtre olmadan kendi çıktısı
      // tekrar tetikleyip sonsuz döngü oluştururdu.
      subjectBeginsWith: '/blobServices/default/containers/${sourceContainer}/'
    }

    eventDeliverySchema: 'EventGridSchema'

    // Dead-letter yapılandırılmamıştır: teslim edilemeyen olaylar bu süre sonunda düşer.
    retryPolicy: {
      maxDeliveryAttempts: 3
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output systemTopicName string = systemTopic.name
output eventSubscriptionName string = eventSubscription.name
