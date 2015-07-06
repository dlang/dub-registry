/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Colden Cullen
*/
module dubregistry.api;

import dubregistry.dbcontroller;
import dubregistry.registry;

import vibe.d;

void registerDubRegistryWebApi(URLRouter router, DubRegistry registry)
{
	auto pkgs = new Packages(registry);
	router.registerRestInterface(pkgs, "/api/packages");
}

interface IPackages {
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

	@path("search")
	string[] querySimilarPackages(string name, uint maxResults=5);
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

	string[] querySimilarPackages(string name, uint maxResults){
		import std.range : take;
		return m_registry.searchPackages([name])
			.take(maxResults)
			.map!(a => a["name"].get!string)
			.array;
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
