# Uploading a New Golden Image

## 1. Compress

```bash
cd ~/Library/Application\ Support/Hivecrew/Templates; gtar --sparse -cvf - "golden-v0.0.12" | zstd -T0 -10 -o /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v0.0.12.tar.zst --progress
```

## 2. Upload

Try:
```bash
rclone copy /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v0.0.12.tar.zst cloudflare-r2:hivecrew-templates/ \
  --progress \
  --s3-chunk-size 200M \
  --s3-upload-concurrency 8 \
  --buffer-size 200M
```

```bash
rclone copy /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v0.0.12.tar.zst cloudflare-r2:hivecrew-templates/ --progress
```

## 3. Update Manifest

Edit `manifest.json` and add the new template at the top:

```json
{
  "version": 1,
  "templates": [
    {
      "id": "golden-v0.0.12",
      "name": "Hivecrew Golden Image",
      "version": "0.0.12",
      "url": "https://templates.hivecrew.org/golden-v0.0.12.tar.zst",
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
public static let goldenV0.0.12 = RemoteTemplate(
    id: "golden-v0.0.12",
    ...
)

public static let all: [RemoteTemplate] = [goldenV0.0.12, ...]
public static let `default` = goldenV0.0.12
```
