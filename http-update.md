# Triggering version updates over HTTP

To queue an update of your package you can use the `POST /api/packages/:packageName/update` endpoint.

## `POST /api/packages/:packageName/update`

Queues an update for the specified package.

Query params:
`secret`: string (optional) provide the secret as query
`header`: string (optional) provide which header is used to check the secret (must start with X-)

Body params: (application/x-www-form-urlencoded, multipart/form-data or application/json)
`secret`: string (optional) provide the secret as body param

## `POST /api/packages/:packageName/update/github`

Queues an update for the specified package. Compatible with GitHub webhooks and only triggers on `create` events. Must pass secret as query param and not in GitHub webhook settings.

## `POST /api/packages/:packageName/update/gitlab`

Queues an update for the specified package. Compatible with GitLab webhooks and only triggers on `tag_push` events. The secret is specified in the GitLab control panel.

Calls `POST /api/packages/:packageName/update` with `header=X-Gitlab-Token` query param after hook parsing.
