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

struct SearchResult { string name, description, version_; }

interface IPackages {
	@method(HTTPMethod.GET)
	SearchResult[] search(string q);

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
