# Upstream Provenance

## Base Repository

**Upstream project:** rtk-ai/rtk ("Rust Token Killer")
**Upstream version:** 0.42.4
**Upstream URL:** https://github.com/rtk-ai/rtk

## Commit References

**Upstream base SHA:** `<UPSTREAM_BASE_SHA>`
Fill in at export time: the upstream `rtk-ai/rtk` commit that was current when
the enterprise source tree was produced (e.g., `git -C upstream/ rev-parse HEAD`).

**Dev-fork export SHA:** `<DEVFORK_EXPORT_SHA>`
Fill in at export time: the commit in `lucachitayat/rtk` (the private dev fork,
branch `develop`) from which this enterprise tree was exported (e.g.,
`git rev-parse HEAD` in the dev fork before running the clean-room export
procedure).

## Clean-Room Export Rationale

The enterprise repository does **not** import history from the dev fork or from
the upstream `rtk-ai/rtk` repository. It is produced as a single orphan/squashed
commit for the following reason:

The upstream git history contains string literals referencing the upstream
telemetry endpoints (`telemetry.rtk-ai.app/ping`, `api.rtk-ai.app/telemetry`)
in historical commits. Although those endpoints are never called in the enterprise
build (the telemetry subsystem is physically removed from the source tree), the
presence of those strings in `git log --all -p` output would surface in any
security grep of the repo's history and could trigger a false positive in
automated scanning tools. Squashing to an orphan commit eliminates the exposure.

The trade-off is that commit-level traceability to upstream is replaced by the
explicit SHA references above, which are recorded both here and in the
`PROVENANCE.txt` file included in the signed build bundle.

## License

Upstream `LICENSE` (MIT) is retained unchanged. The enterprise-hardening
technique (compile-time egress guard, deny-list structure) is re-authored from
`github.com/bmjcoding/rtk-enterprise` (Apache-2.0); that prior art is
acknowledged in the `deny.toml` header comment and in `NOTICE`.
