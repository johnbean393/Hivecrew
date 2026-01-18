# Uploading a New Golden Image

## 1. Compress

```bash
cd ~/Library/Application\ Support/Hivecrew/Templates
gtar --sparse -cvf - "golden-v{VERSION}" | zstd -T0 -10 -o /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v{VERSION}.tar.zst --progress
```

## 2. Upload

```bash
rclone copy /Users/bj/Desktop/Personal/Development/Images/macOS/golden-v{VERSION}.tar.zst cloudflare-r2:hivecrew-templates/ --progress
```

## 3. Update Manifest

Edit `manifest.json` and add the new template at the top:

```json
{
  "version": 1,
  "templates": [
    {
      "id": "golden-v{VERSION}",
      "name": "Hivecrew Golden Image",
      "version": "{VERSION}",
      "url": "https://templates.hivecrew.org/golden-v{VERSION}.tar.zst",
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
public static let goldenV{VERSION} = RemoteTemplate(
    id: "golden-v{VERSION}",
    ...
)

public static let all: [RemoteTemplate] = [goldenV{VERSION}, ...]
public static let `default` = goldenV{VERSION}
```
