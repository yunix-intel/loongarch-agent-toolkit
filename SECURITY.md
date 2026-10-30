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
- Private build releases are created as drafts; a human publishing the draft is
  the promotion gate. The current plan does not support required-reviewer
  environment rules, so this is the equivalent control.
- Personal-account private repositories cannot disable forking through the API
  (`allow_forking` is org-only). The three private repositories currently have
  zero forks, and private forks remain private.

## Historical commits

Before 2026-10-29 the public history contained `claude-desktop-repack/`
packaging scripts, including an old `claude-native-shim.js` that did not reject
`..` or absolute path segments. Those files were removed from `HEAD`
(`f0aa7e7`) and the remaining repack scripts were moved out (`be73389`), but
they remain reachable in old commits. They are not part of any current release
and must not be used. The maintained repack lives in the private Claude Desktop
repository. This is a documented, accepted residual rather than a claim that
the history was rewritten.

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
summary generated from the mirrored bytes), per-artifact SPDX dependency
graphs (`SBOM-codex.spdx.json`, `SBOM-zcode.spdx.json`,
`SBOM-cc-switch.spdx.json`), and license/NOTICE files. The per-artifact SBOMs
are generated inside the private build workflows, where the patched/overridden
source tree exists, and are copied here verbatim; the public `sbom-generate`
workflow only verifies them and the summary checksums. The automatic chain is:

1. `mirror-upload.yml` (daily/manual) copies published assets from the private
   build repositories, verifies their SHA256SUMS, uploads them to
   `agent-binaries`, and refreshes the public `SHA256SUMS`;
2. successful mirror upload runs `mirror-attest.yml`, which creates GitHub
   artifact attestations for the public assets;
3. successful mirror upload also runs `sbom-generate.yml` in verify-only mode.

The private release jobs create **draft** releases; `mirror-upload` only selects
`draft == false`, so a human publishing the draft is the promotion gate. The
`mirror-attest` attestation proves that the mirror workflow handled the exact
asset digest; it is **mirror integrity**, not proof that the binary was built
from the tagged source. Signed release manifests (private key signs
`SHA256SUMS`/`provenance.json`, public key verifies) carry the build-origin
claim.

Verify with `gh attestation verify <asset> --repo
yunix-intel/loongarch-agent-toolkit`. Verify `SHA256SUMS` before installing.

## Release signing

Private build releases sign a binary-only manifest (`BINARIES-SHA256SUMS`) and
a small `provenance.json` with the project key. The corresponding public key is
[`release-pubkey.pem`](release-pubkey.pem) (SHA-256 fingerprint
`b7095f523ce8d54ff0c599d11429de42ee62537b3a3937c0cebe8003cc260ddb`). The mirror
verifies both signatures before copying a release:

```sh
openssl dgst -sha256 -verify release-pubkey.pem \
  -signature BINARIES-SHA256SUMS.sig BINARIES-SHA256SUMS
openssl dgst -sha256 -verify release-pubkey.pem \
  -signature provenance.json.sig provenance.json
sha256sum -c BINARIES-SHA256SUMS
```

The public `SHA256SUMS` is a superset that also covers SBOMs, notices and the
signature files themselves.
