# Native app OAuth (authorization code + PKCE)

The registry issues access tokens to local CLI/GUI tools so they can manage
packages without posting a password. This is OAuth 2.0 authorization code with
PKCE (RFC 7636) and loopback redirects (RFC 8252).

Website login with GitHub is separate: `GET /login/github` → GitHub →
`GET /login/github/callback`. It is enabled only when `github-oauth-client-id`
and `github-oauth-client-secret` are set.

## Public clients

No client registration. `client_id` is an optional label (`native`,
`dub-publish`, `dubx`, …). Every client is public: PKCE `S256` is required, and
`redirect_uri` must be `http://127.0.0.1`, `http://localhost`, or `http://[::1]`
(any port and path).

Scope: `packages` (manage packages for the logged-in user).

## `GET /oauth/authorize`

Query:

| Param | Required | Notes |
| --- | --- | --- |
| `response_type` | yes | `code` |
| `client_id` | no | default `native` |
| `redirect_uri` | yes | loopback HTTP URI |
| `state` | recommended | echoed back |
| `code_challenge` | yes | S256 |
| `code_challenge_method` | yes | `S256` |
| `scope` | no | default `packages` |

If the browser has no session, the user is sent to `/login?redirect=…` (password
and, when configured, GitHub). After login they see a consent page. Authorize
redirects to `redirect_uri?code=…&state=…`. Deny uses `error=access_denied`.

Invalid `redirect_uri` is **not** redirected (error page instead).

## `POST /oauth/token`

`application/x-www-form-urlencoded` or `application/json`:

| Field | Required |
| --- | --- |
| `grant_type` | `authorization_code` |
| `code` | from the callback |
| `redirect_uri` | exact match of the authorize request |
| `code_verifier` | PKCE verifier |
| `client_id` | same as authorize |

Success:

```json
{
  "access_token": "…",
  "token_type": "Bearer",
  "expires_in": 7776000,
  "scope": "packages"
}
```

Authorization codes are single-use and expire in 5 minutes. Access tokens expire
in 90 days. Codes and tokens are stored as SHA-256 hashes.

Errors use OAuth JSON: `{"error":"invalid_grant","error_description":"…"}`.

## `POST /oauth/revoke`

Form/JSON field `token`. Always returns 200 if the request is well-formed.

## Calling authenticated routes

Send the token on existing owner routes (register package, my_packages, …):

```
Authorization: Bearer <access_token>
```

Session cookies still work for the browser.

## CLI sketch

1. Listen on `http://127.0.0.1:<ephemeral>/callback`.
2. Create a PKCE verifier and S256 challenge.
3. Open `/oauth/authorize?response_type=code&client_id=dub-publish&redirect_uri=…&state=…&code_challenge=…&code_challenge_method=S256`.
4. On the callback, `POST /oauth/token` with the code and verifier.
5. Store the access token; send `Authorization: Bearer` on later requests.
