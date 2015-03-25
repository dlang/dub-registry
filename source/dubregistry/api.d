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
	@path(":name/stats")
	Json getStats(string _name);

	@path(":name/:version/stats")
	Json getStats(string _name, string _version);

	@path(":name/latest")
	Json getLatest(string _name);
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
	Json getStats(string _name) {
		return getStats(_name, null);
	}

	Json getStats(string _name, string _version){
		_name = rootOf(_name);
		auto stats = m_registry.getPackageStats(_name, _version);
		enforce(stats.type != Json.Type.null_, new HTTPStatusException(HTTPStatus.notFound, "Package/Version not found"));
		return stats;
	}

	Json getLatest(string _name) {
		_name = rootOf(_name);
		auto ver = m_registry.getLatestVersion(_name);
		enforce(ver.type != Json.Type.null_, new HTTPStatusException(HTTPStatus.notFound, "Package not found"));
		return ver;
	}
}

private:
	string rootOf(string pkg) {
		import std.algorithm: findSplitBefore;
		return pkg.urlDecode().findSplitBefore(":")[0];
	}
}
