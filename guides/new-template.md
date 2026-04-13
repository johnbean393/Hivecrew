# Uploading a New Golden Image

## 1. Compress

```bash
cd ~/Library/Application\ Support/Hivecrew/Templates; gtar --sparse -cvf - "golden-v0.0.19" | zstd -T0 -10 -o /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v0.0.19.tar.zst --progress
```

## 2. Upload

Fastest command tested so far for large archives on the `cloudflare-r2` remote:
```bash
rclone copyto /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v0.0.19.tar.zst cloudflare-r2:hivecrew-templates/golden-v0.0.19.tar.zst \
  --s3-chunk-size 256M \
  --s3-upload-concurrency 32 \
  --s3-upload-cutoff 256M \
  --buffer-size 64M \
  --transfers 1 \
  --checkers 1 \
  --s3-disable-checksum \
  --s3-no-check-bucket \
  --no-check-dest \
  --no-traverse \
  --retries 10 \
  --low-level-retries 20 \
  --stats 30s
```

Measured against a `2 GiB` sample cut from `golden-v0.0.19.tar.zst`:

- `64M` chunks / `32` concurrency: `100.41s`
- `128M` chunks / `64` concurrency: `99.13s`
- `256M` chunks / `32` concurrency: `87.41s`

The `256M` / `32` setting was the fastest stable result in the sample benchmark.

Actual result from uploading `golden-v0.0.19.tar.zst` (`28,951,572,029` bytes): `446.07s` total, or about `7m 26s`, well below the prior `20-25 minute` baseline.

Fallback:
```bash
rclone copy /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v0.0.19.tar.zst cloudflare-r2:hivecrew-templates/ --progress
```

## 3. Update Manifest

Edit `manifest.json` and add the new template at the top:

```json
{
  "version": 1,
  "templates": [
    {
      "id": "golden-v0.0.19",
      "name": "Hivecrew Golden Image",
      "version": "0.0.19",
      "url": "https://templates.hivecrew.org/golden-v0.0.19.tar.zst",
      "minimumAppVersion": "{MIN_APP_VERSION}"
    }
  ]
}
```

Upload:

```bash
rclone copy /Users/bj/Desktop/Personal/Development/Images/macOS/manifest.json cloudflare-r2:hivecrew-templates/ --progress
```

**Existing users** will see the update automatically via the manifest.

## 4. Update App (Optional)

Only needed to change the **fallback default for new users** before they fetch the manifest.

In `TemplateDownloadService.swift`:

```swift
public static let goldenv0.0.19 = RemoteTemplate(
    id: "golden-v0.0.19",
    ...
)

public static let all: [RemoteTemplate] = [goldenV0.0.14, ...]
public static let `default` = goldenV0.0.14
```
