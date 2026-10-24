# Reel

A minimal, free and open-source screen recorder for macOS, in the spirit of Loom.
Native Swift app for macOS 26 and later. Shared videos live in your own Cloudflare account.

Work in progress. Working name.

## Build

```sh
./scripts/build-app.sh   # builds and signs dist/Reel.app
```

The app is signed with the first valid code signing identity on the Mac, so macOS keeps its
permissions across rebuilds (set `REEL_SIGN_IDENTITY` to choose another one).

## License

MIT
