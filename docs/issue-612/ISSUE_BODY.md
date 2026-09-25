## Summary

The GitHub update webhook (`POST /api/packages/:name/update/github`) currently only accepts `create` events (and validates that `create` is enabled on `ping`). All other events—including `release` and `delete`—return `ignored event …`.

That pushes package authors toward the **Branch or tag creation** event. Branch creation is noisy (feature branches), while tags alone miss GitHub **Releases** lifecycle events.

## Proposal

Accept these GitHub events and queue a normal package update (same as `create`):

1. **`release`** — covers created / edited / published / unpublished / deleted (and related actions). Preferable for release-driven workflows.
2. **`delete`** — branch or tag deletion. A full `updatePackage` already removes DB versions whose tags/branches are gone (`got_all_tags_and_branches` → `removeVersion`), so delete hooks can keep the registry in sync when tags are removed.

Also update `ping` validation: treat the hook as valid if it listens for **any** of `create`, `release`, or `delete` (not only `create`), and adjust the error message accordingly.

Keep accepting `create` for backward compatibility.

## Docs / UI

Update `api-docs/http-update.md` (and the my_packages hook blurb if needed) so authors know they can use Releases and/or delete, not only Create.

## Related

- #10 (push notifications / webhooks historically)
- #412 / #275 (webhook support landed via #603; this extends event coverage)

## Motivation

Using only Create means either:
- enabling branch creates (lots of non-release noise), or
- tags only (misses official Releases actions beyond tag create).

The Releases event is the better primary signal for published packages.

### Screenshots — GitHub webhook event picker

**Events section (start):** Branch or tag creation / deletion selected (current Dub guidance):

![GitHub webhook events — creation and deletion](https://raw.githubusercontent.com/AMDphreak/dub-registry/feature/github-webhook-release-delete-events/docs/issue-612/github-webhook-events-top.jpeg)

**Releases option:** preferred trigger — *Release created, edited, published, unpublished, or deleted*:

![GitHub webhook events — Releases](https://raw.githubusercontent.com/AMDphreak/dub-registry/feature/github-webhook-release-delete-events/docs/issue-612/github-webhook-releases-bottom.jpeg)
