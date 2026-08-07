using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Processing;
using Azure.Storage.Blobs;

namespace ImageResizeFunction;

public sealed class ResizeImage(ILogger<ResizeImage> logger, BlobServiceClient blobServiceClient)
{
    [Function(nameof(ResizeImage))]
    public async Task Run(
        [BlobTrigger("uploads/{name}", Connection = "AzureWebJobsStorage")] Stream incomingBlob,
        string name,
        FunctionContext context)
    {
        logger.LogInformation("Görsel işleniyor: {ImageName}", name);

        using var image = await Image.LoadAsync(incomingBlob);

        image.Mutate(x => x.Resize(new ResizeOptions
        {
            Size = new Size(150, 150),
            Mode = ResizeMode.Max
        }));

        using var outputStream = new MemoryStream();
        await image.SaveAsJpegAsync(outputStream);
        outputStream.Position = 0;

        var outputClient = blobServiceClient
            .GetBlobContainerClient("thumbnails")
            .GetBlobClient(name);

        await outputClient.UploadAsync(outputStream, overwrite: true);

        logger.LogInformation("{ImageName} için thumbnail başarıyla oluşturuldu.", name);
    }
}
