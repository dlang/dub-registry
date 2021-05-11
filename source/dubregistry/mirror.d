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
import std.datetime.systime : SysTime;
import std.encoding : sanitize;
import std.format : format;

void validateMirrorURL(ref string base_url)
{
	import std.exception : enforce;
	import std.algorithm.searching : endsWith;
	import vibe.core.file : existsFile;

	// Local JSON files are allowed
	if (NativePath(base_url).existsFile)
		return;

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

void mirrorRegistry(DubRegistry registry, string fileOrUrl)
nothrow {
	import vibe.core.file : existsFile, readFileUTF8;
	import vibe.stream.operations : readAllUTF8;

	logInfo("Polling '%s' for updates...", fileOrUrl);
	try {
		DbPackage[] packs;
		URL url;

		const path = NativePath(fileOrUrl);

		string source_text;

		if (path.existsFile) {
			logInfo("Using local file at %s", path);
			source_text = path.readFileUTF8;
		}
		else {
			url = URL(fileOrUrl);

			const uri = url ~ InetPath("api/packages/dump");

			logInfo("Downloading packages from %s", uri);

			source_text = requestHTTP(url ~ InetPath("api/packages/dump"))
				.bodyReader
				.readAllUTF8;
		}

		logInfo("Download complete. Begin deserializing");
		packs = source_text.deserializeJson!(DbPackage[]);

		logInfo("Deserialization complete");

		bool[BsonObjectID] current_packs;
		foreach (p; packs) current_packs[p._id] = true;

		// first, remove all packages that don't exist anymore to avoid possible name conflicts
		foreach (id; registry.availablePackageIDs)
			if (id !in current_packs) {
				try {
					auto pack = registry.db.getPackage(id);
					logInfo("Removing package '%s", pack.name);
					registry.removePackage(pack.name, User.ID(pack.owner));
				} catch (Exception e) {
					logError("Failed to remove package with ID '%s': %s", id, e.msg);
					logDiagnostic("Full error: %s", e.toString().sanitize);
				}
			}

		// then add/update all existing packages
		foreach (p; packs) {
			try {
				logDebug("Updating package '%s'", p.name);
				registry.addOrSetPackage(p);
			} catch (Exception e) {
				logError("Failed to add/update package '%s': %s", p.name, e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}

		logInfo("Updates for '%s' successfully processed.", fileOrUrl);
	} catch (Exception e) {
		logError("Fetching updated packages failed: %s", e.msg);
		logError("Full error: %s", e.toString().sanitize);
	}
}
