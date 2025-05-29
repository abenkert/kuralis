# CORS Setup for Direct Uploads

Direct uploads require CORS (Cross-Origin Resource Sharing) configuration on your cloud storage provider.

## AWS S3 CORS Configuration

Add this CORS policy to your S3 bucket:

```json
[
  {
    "AllowedHeaders": [
      "*"
    ],
    "AllowedMethods": [
      "PUT",
      "POST",
      "DELETE"
    ],
    "AllowedOrigins": [
      "https://yourdomain.com",
      "http://localhost:3000"
    ],
    "ExposeHeaders": [
      "Origin",
      "Content-Type",
      "Content-MD5",
      "Content-Disposition"
    ],
    "MaxAgeSeconds": 3600
  }
]
```

## Azure Blob Storage CORS

In Azure Portal, go to your Storage Account > Settings > CORS and add:

- **Allowed origins**: `https://yourdomain.com,http://localhost:3000`
- **Allowed methods**: `PUT,POST,DELETE`
- **Allowed headers**: `*`
- **Exposed headers**: `Content-Type,Content-MD5,x-ms-blob-content-disposition,x-ms-blob-type`
- **Max age**: `3600`

## Google Cloud Storage CORS

Create a `cors.json` file:

```json
[
  {
    "origin": ["https://yourdomain.com", "http://localhost:3000"],
    "method": ["PUT", "POST", "DELETE"],
    "responseHeader": ["Content-Type", "Content-MD5", "Content-Disposition"],
    "maxAgeSeconds": 3600
  }
]
```

Then apply it:
```bash
gsutil cors set cors.json gs://your-bucket-name
```

## Testing CORS

You can test CORS configuration using browser developer tools. Direct uploads will fail with CORS errors if not properly configured.

## Security Notes

- Always use HTTPS in production
- Limit allowed origins to your actual domains
- Consider using environment-specific buckets
- Monitor for unauthorized uploads 