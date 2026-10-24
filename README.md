# Reel

A minimal, free and open-source screen recorder for macOS, in the spirit of Loom.
Native Swift app for macOS 26 and later. Shared videos live in your own Cloudflare account.

Work in progress. Working name.

## Build

```sh
./scripts/build-app.sh   # builds and signs dist/Reel.app
```

The signing identity defaults to a local self-signed certificate named `Reel Local Signing`
(set `REEL_SIGN_IDENTITY` to use another one).

## License

MIT
