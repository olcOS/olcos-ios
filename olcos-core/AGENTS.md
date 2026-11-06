# olcos-core — technical contract

Read [docs/HANDOFF.md](docs/HANDOFF.md) before changing anything. It carries the
context, the target architecture, the milestone plan and the research
behind every design decision. Code and executable tests take precedence over
historical comments.

## Identity

- Shared Go core for olcOS clients. Repository: `Hotelk52339/olcos-core`
  (private until the owner authorizes publication).
- Engines: `olcrtc` (WebRTC carrier, upstream archived and vendored in
  olcos-ios) and `xray` (VLESS + REALITY + XTLS-Vision via xray-core).
- Companion app: [olcos-ios](https://github.com/Hotelk52339/olcos-ios); its
  `AGENTS.md` invariants (hero picture, mode preference, packet policy,
  L10n RU/EN/FR parity) still apply to any code that ends up in the app.

## Change discipline

- Factual Conventional Commits (`feat(xray): render server config`). Do not
  attribute commits to an AI, prompt, conversation or user request.
- Do not publish without authorization: no `git push`, tag, release,
  repository creation/deletion or public post without the owner's explicit
  confirmation for that specific action.
- Do not touch upstream `openlibrecommunity/olcrtc`: no fork, issue or PR.
- Keep MIT [LICENSE](LICENSE); when xray-core (MPL-2.0) is vendored or
  modified, keep its notices and file-level headers.

## Architecture invariants

- One Go runtime per process: everything bound for iOS/Android comes out of
  ONE `gomobile bind` (this module + upstream `mobile` + olcos-ios `tunstack`).
  Never link two gomobile frameworks.
- gobind surface lives only in `mobile/`: gobind-safe scalars, plain
  interfaces and the JSON `Invoke` channel. No slices of structs, maps or
  generics cross the boundary. Nothing may panic across the boundary.
- `engine/` is transport-neutral; engine-specific knobs go into
  `Profile.Params` and are documented in the engine package.
- iOS packet tunnel budget is ~50 MiB: apply `TuneForNetworkExtension`
  before starting any engine; no geodata and no xhttp in default profiles.
- HealthReason names mirror olcos-ios `docs/diagnostic-messages.md`; never
  rename.
- Server scripts in `server/xray/` are Podman-based like olcos-ios
  `scripts/srv.sh`; image tags are pinned; target/SNI is validated, not
  hard-coded.

## Verification

Report every check as `PASS`, `FAIL`, `NOT RUN` or `NOT APPLICABLE` with the
exact command. Missing toolchain is `NOT RUN`, never assumed.

| Check | Command |
|---|---|
| Format | `gofmt -l .` (must print nothing) |
| Vet | `go vet ./...` |
| Tests | `go test ./...` |
| Shell syntax | `bash -n server/xray/*.sh` |
| Shell lint | `shellcheck server/xray/*.sh` |
| gomobile bind | `scripts/bind.sh` (M2; NOT RUN without Xcode / Android NDK) |
