# Transport 4ca1d0db — LESSON-UX PART2 (PR #207)

- Target image: `ghcr.io/abolfazlprog/hanaso:4ca1d0db3e53c9af0e5fcc53628b03ce44ad5d76` (linux/amd64)
- Archive: `hanaso-image-4ca1d0db.docker.tar` — 361533440 bytes
- Archive sha256: `cb7d65e8655f4b2409e2c2c475dab9e648fcdb9385f2c26b7e9cce68a05d3c52`
- Reassemble: `cat chunk-* > hanaso-image-4ca1d0db.docker.tar`
- Verify: `sha256sum hanaso-image-4ca1d0db.docker.tar` == archive sha256 above; chunk sums in SHA256SUMS
- Load: `docker load -i hanaso-image-4ca1d0db.docker.tar`
- Reason: direct `docker pull` from VPS fails (TLS timeout to pkg-containers.githubusercontent.com) — same path as Part 1 deploy.
