/**
*/
module dubregistry.mirror;

import dubregistry.registry;
import dubregistry.dbcontroller;
import userman.db.controller;
import vibe.core.log;
import vibe.data.bson;
import vibe.http.client;
import vibe.inet.url;
import std.array : array;
import std.datetime : SysTime;
import std.encoding : sanitize;
import std.format : format;

void validateMirrorURL(ref string base_url)
{
	import std.exception : enforce;
	import std.algorithm.searching : endsWith;

	// ensure the URL has a trailing slash
	if (!base_url.endsWith('/')) base_url ~= '/';

	// check two characteristic API endpoints
	enum urls = ["packages/index.json", "api/packages/search?q=foobar"];
	foreach (url; urls) {
		try {
			requestHTTP(base_url ~ url,
				(scope req) { req.method = HTTPMethod.HEAD; },
				(scope res) {
					enforce(res.statusCode < 400,
						format("Endpoint '%s' could not be accessed: %s", url, httpStatusText(res.statusCode)));
				}
			);
		} catch (Exception e) {
			throw new Exception("The provided mirror URL does not appear to point to a valid DUB registry root: "~e.msg);
		}
	}
}

void mirrorRegistry(DubRegistry registry, URL url)
nothrow {
	logInfo("Polling '%s' for updates...", url);
	try {
		bool[string] current_packs;
		auto packs = requestHTTP(url ~ Path("api/packages/dump")).readJson().deserializeJson!(DbPackage[]);
		foreach (p; packs) {
			current_packs[p.name] = true;
			try setPackage(registry, p);
			catch (Exception e) {
				logError("Failed to add/update package '%s': %s", p.name, e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}

		foreach (p; registry.availablePackages.array)
			if (p !in current_packs) {
				try removePackage(registry, p);
				catch (Exception e) {
					logError("Failed to remove package '%s': %s", p, e.msg);
					logDiagnostic("Full error: %s", e.toString().sanitize);
				}
			}

	} catch (Exception e) {
		logError("Fetching updated packages failed: %s", e.msg);
		logDiagnostic("Full error: %s", e.toString().sanitize);
	}
}

private void setPackage(DubRegistry registry, ref DbPackage pack)
{
	logInfo("Updating package '%s'", pack.name);
	registry.addOrSetPackage(pack);
}

private void removePackage(DubRegistry registry, string pack_name)
{
	logInfo("Removing package '%s", pack_name);
	auto uid = registry.db.getPackage(pack_name).owner;
	registry.removePackage(pack_name, User.ID(uid));
}
