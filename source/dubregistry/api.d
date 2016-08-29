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
}

/// Compatibility alias.
deprecated("Use registerDubRegistryAPI instead.")
alias registerDubRegistryWebApi = registerDubRegistryAPI;


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

interface IPackages {
	@method(HTTPMethod.GET)
	SearchResult[] search(string q = "");

	@path(":name/latest")
	string getLatestVersion(string _name);

	@path(":name/stats")
	Json getStats(string _name);

	@path(":name/:version/stats")
	Json getStats(string _name, string _version);

	@path(":name/info")
	Json getInfo(string _name);

	@path(":name/:version/info")
	Json getInfo(string _name, string _version);
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

	Json getStats(string name) {
		return m_registry.getPackageStats(rootOf(name))
			.check!(r => r.type != Json.Type.null_)(HTTPStatus.notFound, "Package not found");
	}

	Json getStats(string name, string ver) {
		return m_registry.getPackageStats(rootOf(name), ver)
			.check!(r => r.type != Json.Type.null_)(HTTPStatus.notFound, "Package/Version not found");
	}

	Json getInfo(string name) {
		return m_registry.getPackageInfo(rootOf(name))
			.check!(r => r.type != Json.Type.null_)(HTTPStatus.notFound, "Package/Version not found");
	}

	Json getInfo(string name, string ver) {
		return m_registry.getPackageVersionInfo(rootOf(name), ver)
			.check!(r => r.type != Json.Type.null_)(HTTPStatus.notFound, "Package/Version not found");
	}
}

private:
	string rootOf(string pkg) {
		import std.algorithm: findSplitBefore;
		return pkg.urlDecode().findSplitBefore(":")[0];
	}
}


private	auto ref T check(alias cond, T)(auto ref T t, HTTPStatus status, string msg)
{
	enforce(cond(t), new HTTPStatusException(status, msg));
	return t;
}
