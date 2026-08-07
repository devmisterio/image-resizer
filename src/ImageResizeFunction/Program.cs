using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services.AddSingleton<BlobServiceClient>(sp =>
{
    var connectionString = Environment.GetEnvironmentVariable("AzureWebJobsStorage");
    if (!string.IsNullOrEmpty(connectionString))
    {
        return new BlobServiceClient(connectionString);
    }

    var accountName = Environment.GetEnvironmentVariable("AzureWebJobsStorage__accountName")
        ?? throw new InvalidOperationException(
            "Storage bağlantısı kurulamadı. " +
            "Development: 'AzureWebJobsStorage' connection string bekleniyor. " +
            "Production: 'AzureWebJobsStorage__accountName' bekleniyor.");

    return new BlobServiceClient(
        new Uri($"https://{accountName}.blob.core.windows.net"),
        new DefaultAzureCredential());
});

var openTelemetryBuilder = builder.Services.AddOpenTelemetry().UseFunctionsWorkerDefaults();

if (!builder.Environment.IsDevelopment())
{
    openTelemetryBuilder.UseAzureMonitorExporter();
}

builder.Build().Run();
