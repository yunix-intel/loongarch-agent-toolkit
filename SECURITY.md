# Security policy

## Reporting

Report vulnerabilities privately through GitHub Security Advisories
("Report a vulnerability" in the **Security** tab). Do not open a public issue
containing tokens, private keys, internal hostnames/IPs, or exploit details.

## Supported versions

Only the latest published `agent-binaries` asset is supported. Older assets
remain downloadable for reproducibility but do not receive fixes.

## Supply chain and repository boundaries

- This repository is public and has no self-hosted runners.
- `loongarch-agent-builds` and `cc-switch-loongarch` are private build sources.
  Their self-hosted loong64 runners are not reachable from public forks.
- Reviewed binaries are mirrored into this repository's public
  `agent-binaries` release. Public installers never reference private assets.
- GitHub Actions are restricted to GitHub-owned actions and pinned to commit
  SHAs; `main` is protected (PR required, no force push/delete, admins
  enforced); secret scanning and push protection are enabled.
- Dependency alerts and security updates are enabled. Upstream-only blockers
  are recorded on the Dependabot alert instead of being silently ignored.

## Secrets

Tokens used by automation live only in GitHub Actions secrets
(`AUTO_ALIGN_TOKEN`, `CC_SWITCH_TAG_TOKEN`). They are never committed. Public
mirror downloads require no token. Do not paste a token into an issue, PR, log,
or command line.

`ccswitch-lite` uses a per-process capability token for its Web API. The token
is stored in a 0600 file next to `providers.json`; another local user cannot
call `/api/*` without it. `CCSWITCH_WEB_TOKEN` can supply a fixed token for
automation/tests (minimum 16 characters).

## Releases

Public release assets ship with `SHA256SUMS`, `SBOM.spdx.json` (component
summary), per-artifact SPDX dependency graphs (`SBOM-codex.spdx.json`,
`SBOM-zcode.spdx.json`, `SBOM-cc-switch.spdx.json`), and license/NOTICE files.
Release provenance is recorded in the release notes. The automatic chain is:

1. `mirror-upload.yml` (daily/manual) copies published assets from the private
   build repositories, verifies their SHA256SUMS, uploads them to
   `agent-binaries`, and refreshes the public `SHA256SUMS`;
2. successful mirror upload runs `sbom-generate.yml`, which derives the
   versions from the public assets and emits per-artifact SPDX dependency
   graphs;
3. successful SBOM generation (and mirror upload) runs `mirror-attest.yml`,
   which creates GitHub build-provenance attestations for the public assets.

Verify with `gh attestation verify <asset> --repo
yunix-intel/loongarch-agent-toolkit`. Verify `SHA256SUMS` before installing.
