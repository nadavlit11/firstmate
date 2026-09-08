# Codemagic build-status API verification

`docs/configuration.md` owns operator setup and behavior, while `bin/fm-procevent-codemagic.sh --help` owns command mechanics.

Verified on 2026-09-08 against Codemagic's current documentation:

- `https://docs.codemagic.io/rest-api/codemagic-rest-api/` identifies the `x-auth-token` header and **Account settings > API token** as the current authentication path.
- `https://docs.codemagic.io/integrations/jenkins-integration/#poll-build-status` specifies `GET https://codemagic.io/api/v3/builds/{buildId}` and the `data.status` response field.
- The same current page lists `initializing`, `queued`, `preparing`, `fetching`, `testing`, `building`, `publishing`, and `finishing` as in progress.
- The same current page lists `finished`, `failed`, `canceled`, `timeout`, and `skipped` as terminal, with only `finished` successful.
- The current OpenAPI document at `https://codemagic.io/api/v3/schema/openapi.json` defines `GET /api/v3/builds/{build_id}/actions`.
- Its action schema exposes `name`, `type`, `status`, `has_test_results`, `script`, `started_at`, and `finished_at`, with action statuses `success`, `failed`, `skipped`, and `canceled`.
- The build schema exposes artifact name, type, size, short-lived download URL, version code, and version name, plus `app_store_connect_status`.
- The documented build and action schemas expose no failure-reason text and no build-log URL.
- Therefore the current read API can identify which action failed and whether artifacts exist, but the documented schema cannot explain the failure beyond the failed action or retrieve its logs.

The exact schema inspection commands were:

```sh
curl -fsSL https://codemagic.io/api/v3/schema/openapi.json | jq '.paths["/api/v3/builds/{build_id}/actions"].get'
curl -fsSL https://codemagic.io/api/v3/schema/openapi.json | jq '.components.schemas.BuildActionSchema, .components.schemas.BuildActionStatus, .components.schemas.builds_schemas_BuildSchema'
```

The local behavioral verification command is:

```sh
tests/fm-procevent-codemagic.test.sh
```

Its expected final line is:

```text
# all fm-procevent-codemagic tests passed
```

A live-account verification still requires a valid Codemagic API key and a real build id.
Do not treat the mocked behavioral suite as evidence that live authentication or the deployed response works.

Live verification on 2026-09-08 used Travelaya build `6a9fadd89b3a3c5ac1c2c458` through the adapter's ordinary process-event registration.
The build endpoint returned HTTP 200 with raw `data.status` equal to `finished`, `data.app_store_connect_status` equal to `failed`, and one `Travelaya.ipa` artifact.
The actions endpoint returned HTTP 200 with `total_pages` equal to `1` and no action whose status was `failed`.
The adapter therefore reported `post-processing-failed`, retained `raw_status: finished`, identified `failed_action: app_store_connect`, published the durable wake, and retired the source.
The API proves that App Store Connect post-processing failed but exposes no failure reason or log URL through these documented schemas.

A request for the nonexistent build id `ffffffffffffffffffffffff` returned the Codemagic HTML application page with HTTP 200 rather than a documented JSON error.
The adapter recognizes that observed response as `not-found` instead of treating it as a successful build lookup.
An intentionally invalid token against the real build returned HTTP 401 and the adapter reported `auth-error` without exposing the token.
