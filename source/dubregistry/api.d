/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Colden Cullen
*/
module dubregistry.api;

import dubregistry.dbcontroller;
import dubregistry.registry;

import vibe.d;

DubRegistryWebApi registerDubRegistryWebApi(URLRouter router, DubRegistry registry)
{
	auto settings = new WebInterfaceSettings;
	settings.urlPrefix = "api";

	auto webapi = new DubRegistryWebApi(registry);
	router.registerWebInterface(webapi, settings);
	return webapi;
}

class DubRegistryWebApi {
	private {
		DubRegistry m_registry;
	}

	this(DubRegistry registry)
	{
		m_registry = registry;
	}

	@path("/packages/:packname/stats.json")
	void getPackageStats(HTTPServerRequest req, HTTPServerResponse res, string _packname)
	{
		import std.algorithm: findSplitBefore;

		auto rootPackName = _packname.urlDecode().findSplitBefore(":")[0];

		auto stats = m_registry.getPackageStats(rootPackName);
		res.writeJsonBody(stats.serializeToJson());
	}

	@path("/packages/:packname/:version/stats.json")
	void getPackageStats(HTTPServerRequest req, HTTPServerResponse res, string _packname, string _version)
	{
		import std.algorithm: findSplitBefore;

		auto rootPackName = _packname.urlDecode().findSplitBefore(":")[0];

		auto stats = m_registry.getPackageStats(rootPackName, _version);
		res.writeJsonBody(stats.serializeToJson());
	}
}
