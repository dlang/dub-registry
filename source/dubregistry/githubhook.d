/**
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
*/
module dubregistry.githubhook;

/** GitHub webhook events that should queue a package update. */
bool githubUpdateEvent(string event) @safe pure
{
	return event == "create" || event == "release" || event == "delete";
}

/** True when a webhook ping lists at least one accepted event. */
bool githubPingListsUpdateEvent(string[] events) @safe pure
{
	foreach (ev; events)
		if (githubUpdateEvent(ev))
			return true;
	return false;
}

@safe unittest
{
	assert(githubUpdateEvent("create"));
	assert(githubUpdateEvent("release"));
	assert(githubUpdateEvent("delete"));
	assert(!githubUpdateEvent("push"));
	assert(!githubUpdateEvent("ping"));
	assert(!githubUpdateEvent(""));

	assert(githubPingListsUpdateEvent(["push", "release"]));
	assert(githubPingListsUpdateEvent(["delete"]));
	assert(!githubPingListsUpdateEvent(["push", "pull_request"]));
	assert(!githubPingListsUpdateEvent([]));
}
