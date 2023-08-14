/**
	Copyright: © 2013-2016 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Colden Cullen
*/
module dubregistry.api;

import dubregistry.dbcontroller;
import dubregistry.registry;

import std.algorithm.iteration : map;
import std.array : array;
import std.exception : enforce;
import std.typecons : Flag, Yes, No;
import vibe.data.json : Json;
import vibe.http.router;
import vibe.inet.url;
import vibe.textfilter.urlencode;
import vibe.web.rest;


/** Registers the DUB registry REST API endpoints in the given router.
*/
void registerDubRegistryAPI(URLRouter router, DubRegistry registry)
{
	auto pkgs = new LocalDubRegistryAPI(registry);
	router.registerRestInterface(pkgs, "/api");
	router.get("/api/packages/dump", (req, res) @trusted => dumpPackages(req, res, registry));
}

/// Compatibility alias.
deprecated("Use registerDubRegistryAPI instead.")
alias registerDubRegistryWebApi = registerDubRegistryAPI;


private void dumpPackages(HTTPServerRequest req, HTTPServerResponse res, DubRegistry registry)
{
	import vibe.data.json : serializeToPrettyJson;
	import vibe.stream.wrapper : streamOutputRange;

	res.contentType = "application/json; charset=UTF-8";
	res.headers["Content-Encoding"] = "gzip"; // force GZIP compressed response
	auto dst = streamOutputRange(res.bodyWriter);
	dst.put('[');
	bool first = true;
	foreach (p; registry.getPackageDump()) {
		if (!first) dst.put(',');
		else first = false;
		serializeToPrettyJson(&dst, p);
	}
	dst.put(']');
}

/** Returns a REST client instance for communicating with a DUB registry's API.

	Params:
		url = URL of the DUB registry (e.g. "https://code.dlang.org/")
*/
DubRegistryAPI connectDubRegistryAPI(URL url)
{
	return new RestInterfaceClient!DubRegistryAPI(url);
}
/// ditto
DubRegistryAPI connectDubRegistry(string url)
{
	return connectDubRegistryAPI(URL(url));
}

interface DubRegistryAPI {
	@property IPackages packages();
}

struct SearchResult { string name, description, version_; }
struct DownloadStats { DbDownloadStats downloads; }
alias Version = string;

interface IPackages {
@safe:

	@method(HTTPMethod.GET)
	SearchResult[] search(string q = "");

	@path(":name/latest")
	string getLatestVersion(string _name);

	@path(":name/stats")
	DbPackageStats getStats(string _name);

	@path(":name/:version/stats")
	DownloadStats getStats(string _name, string _version);

	@path(":name/info")
	Json getInfo(string _name, bool minimize = false);

	@path(":name/:version/info")
	Json getInfo(string _name, string _version, bool minimize = false);

	Json[string] getInfos(string[] packages, bool include_dependencies = false, bool minimize = false);

	@path(":name/update")
	string postUpdate(string _name, string secret = "");

	@path(":name/update/github")
	@headerParam("event", "X-GitHub-Event")
	@queryParam("secret", "secret")
	string postUpdateGithub(string _name, string secret, string event, Json hook = Json.init);

	@path(":name/update/gitlab")
	@headerParam("secret", "X-Gitlab-Token")
	string postUpdateGitlab(string _name, string secret, string object_kind = "");
}

class LocalDubRegistryAPI : DubRegistryAPI {
	private {
		Packages m_packages;
	}

	this(DubRegistry registry)
	{
		m_packages = new Packages(registry);
	}

	@property Packages packages() { return m_packages; }
}

class Packages : IPackages {
	private {
		DubRegistry m_registry;
	}

	this(DubRegistry registry)
	{
		m_registry = registry;
	}

override {
	@method(HTTPMethod.GET)
	SearchResult[] search(string q) {
		return m_registry.searchPackages(q)
			.map!(p => SearchResult(p.name, p.info["description"].opt!string, p.version_))
			.array;
	}

	string getLatestVersion(string name) {
		return m_registry.getLatestVersion(rootOf(name))
			.check!(r => r.length)(HTTPStatus.notFound, "Package not found");
	}

	DbPackageStats getStats(string name) {
		try {
			auto stats = m_registry.getPackageStats(rootOf(name));
			return stats;
		} catch (RecordNotFound e) {
			throw new HTTPStatusException(HTTPStatus.notFound, "Package not found");
		}
	}

	DownloadStats getStats(string name, string ver) {
		try {
			return typeof(return)(m_registry.getDownloadStats(rootOf(name), ver));
		} catch (RecordNotFound e) {
			throw new HTTPStatusException(HTTPStatus.notFound, "Package or Version not found");
		}
	}

	Json getInfo(string name, bool minimize = false) {
		immutable flags = minimize ? PackageInfoFlags.minimize : PackageInfoFlags.none;
		return m_registry.getPackageInfo(rootOf(name), flags)
			.check!(r => r.info.type != Json.Type.undefined)(HTTPStatus.notFound, "Package/Version not found")
			.info;
	}

	Json getInfo(string name, string ver, bool minimize = false) {
		immutable flags = minimize ? PackageInfoFlags.minimize : PackageInfoFlags.none;
		return m_registry.getPackageVersionInfo(rootOf(name), ver, flags)
			.check!(r => r.type != Json.Type.null_)(HTTPStatus.notFound, "Package/Version not found");
	}

	Json[string] getInfos(string[] packages, bool include_dependencies = false, bool minimize = false)
	{
		import std.array : assocArray;
		import std.typecons : tuple;

		auto flags = minimize ? PackageInfoFlags.minimize : PackageInfoFlags.none;
		if (include_dependencies)
			flags |= PackageInfoFlags.includeDependencies;
		return m_registry.getPackageInfosRecursive(packages, flags)
			.check!(r => r !is null)(HTTPStatus.notFound, "None of the packages were found")
			.byKeyValue.map!(p => tuple(p.key, p.value.info)).assocArray;
	}

	@before!updateSecretReader("secret")
	string postUpdate(string _name, string secret = "")
	{
		if (!secret.length)
			return "No secret sent";

		string expected = m_registry.getPackageSecret(_name);
		if (!expected.length || secret != expected)
			return "Secret doesn't match";

		m_registry.triggerPackageUpdate(_name);
		return "Queued package update";
	}

	string postUpdateGithub(string _name, string secret, string event, Json hook = Json.init)
	{
		if (event == "create") {
			return postUpdate(_name, secret);
		} else if (event == "ping") {
			enforceBadRequest(hook.type == Json.Type.object, "hook is not of type json");
			auto eventsObj = *enforceBadRequest("events" in hook, "no events object sent in hook object");
			enforceBadRequest(eventsObj.type == Json.Type.array, "Hook events must be of type array");
			auto events = eventsObj.get!(Json[]);

			foreach (ev; events)
				if (ev.type == Json.Type.string && ev.get!string == "create")
					return "valid";

			string expected = m_registry.getPackageSecret(_name);
			if (expected.length && secret.length && secret == expected)
				m_registry.addPackageError(_name,
					"GitHub hook configuration is invalid. Hook is missing 'create' event. (Tags or branches)");

			return "invalid hook - create event missing";
		} else
			return "ignored event " ~ event;
	}

	string postUpdateGitlab(string _name, string secret, string object_kind)
	{
		if (object_kind != "tag_push")
			return "ignored event " ~ object_kind;

		return postUpdate(_name, secret);
	}
}

private:
	string rootOf(string pkg) @safe {
		import std.algorithm: findSplitBefore;
		// FIXME: urlDecode should not be necessary, as the REST paramters are
		//        already decoded.
		return pkg.urlDecode().findSplitBefore(":")[0];
	}
}

private string updateSecretReader(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
	string header = req.query.get("header", "");
	if (header.length)
		return req.headers.get(header);

	string ret = req.contentType == "application/json" ? req.json["secret"].get!string : req.form.get("secret", "");
	if (ret.length)
		return ret;

	return req.query.get("secret", "");
}

private	auto ref T check(alias cond, T)(auto ref T t, HTTPStatus status, string msg)
{
	enforce(cond(t), new HTTPStatusException(status, msg));
	return t;
}
