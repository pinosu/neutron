# Callbacks+ / Hooks IBC harness

Two chains — neutron (Hooks + Callbacks+ + Dedup) and wasmd (Callbacks+) — over an
IBC v1 transfer channel. 15 scenarios assert the Callbacks+/Hooks behaviour matrix.

## Run

    make all     # build, start, open channel, deploy probe, run all 15 scenarios

Individual steps: `make build up channel contract deploy test`.
`make clean` resets state; after a container restart re-run `make channel`.

## Requirements

- Docker (running), `python3`, `jq`, `xxd`; x86_64 Linux/WSL2.
- First build clones+builds wasmd at the commit pinned in `go.mod` (needs internet);
  no local wasmd checkout required.

Note: neutron has no Hooks source-side `ibc_callback` (removed upstream) — s13
exercises neutron's x/transfer module sudo instead.
