# cloudflared Binary

Place the `cloudflared` macOS ARM64 binary in this directory.

## Download Instructions

1. Download the latest release from: https://github.com/cloudflare/cloudflared/releases
2. Get the `cloudflared-darwin-arm64.tgz` asset
3. Extract: `tar xzf cloudflared-darwin-arm64.tgz`
4. Move `cloudflared` to this directory
5. Ensure it's executable: `chmod +x cloudflared`

## Xcode Setup

After placing the binary:

1. In Xcode, drag the `cloudflared` binary into the project navigator under `Hivecrew/Resources/cloudflared/`
2. In the file inspector, ensure:
   - Target Membership: Hivecrew (checked)
   - Under Build Phases > Copy Bundle Resources, verify `cloudflared` is listed
3. Alternatively, add it under Build Phases > Copy Files with Destination: "Executables"

The `CloudflaredManager.swift` will locate the binary via `Bundle.main`.
