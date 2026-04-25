# cua-driver

Bundled `cua-driver` binary for the App Worker runtime.

- **Version:** 0.0.5
- **Source:** https://github.com/trycua/cua/releases/tag/cua-driver-v0.0.5
- **Artifact:** `cua-driver-0.0.5-darwin-arm64.tar.gz`
- **SHA256:** `77e8ca64f55d2b9a55cfc59a5815f973027507d360cf3b552c24698c24d2e3c5`
- **Architecture:** darwin-arm64

## Refresh procedure

1. Download `cua-driver-<version>-darwin-arm64.tar.gz` from the releases page.
2. Verify the SHA256 checksum.
3. Extract: `tar xzf cua-driver-<version>-darwin-arm64.tar.gz`
4. Replace the `cua-driver` wrapper script and `CuaDriver.app/` bundle in this directory.
5. Ensure executable bits: `chmod +x cua-driver CuaDriver.app/Contents/MacOS/cua-driver`
6. Update `CHECKSUM.txt` with the new hash.
7. Update `CuaDriverManager.expectedVersion` if applicable.
