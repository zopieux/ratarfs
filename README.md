# ratarfs

Mounts a compressed archive as a writable filesystem with atomic snapshots.

This is useful to serve (r/w) a highly-compressible filesystem with a high read
load and the occasional writes, while saving on disk footprint.

The source archive is *overwritten* when creating new snapshots. If this is not
what you want, make a copy first, or use a CoW filesystem as the source.

This tool does not care about reliability: writes since the last snapshot will
be *lost* if the system crashes or loses power. The trade-off is therefore in
choosing between more regular snapshotting (CPU intensive) or a higher risk of
data loss, but fewer compression cycles.

## Usage

Using a Nix flake:

```bash
nix run 'github:zopieux/ratarfs' -- <archive.tar.zst> <mountpoint>
```

## License

GNU General Public License v3.0.
