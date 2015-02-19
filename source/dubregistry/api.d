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
	settings.urlPrefix = "/api";

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
	void getPackageStats(HTTPServerResponse res, string _packname)
	{
		return getPackageStats(res, _packname, null);
	}

	@path("/packages/:packname/:version/stats.json")
	void getPackageStats(HTTPServerResponse res, string _packname, string _version)
	{
		import std.algorithm: findSplitBefore;

		auto rootPackName = _packname.urlDecode().findSplitBefore(":")[0];
		auto stats = m_registry.getPackageStats(rootPackName, _version);
		if (stats.type != Json.Type.null_) res.writeJsonBody(stats);
		else res.writeJsonBody(["message": "Package/Version not found"], HTTPStatus.notFound);
	}

    // searches for a package
    void querySearch(HTTPServerRequest req, HTTPServerResponse res){
        string* q = "q" in req.query;
        
        if(q == null) 
        {
            res.statusCode = 400;
            res.writeJsonBody("Error: Must pass query parameter");
            logDiagnostic("Error: no query in search string");
            return;
        }

        string[] queryStrings = (*q).split(",");

        if(queryStrings.length == 0)
        {
            res.statusCode = 400;
            res.writeJsonBody("Error: Must pass search text");
            logDiagnostic("Error: no query parameters in search string");
            return;
        }
        // limit the number of items can search for, to limit possibility for attacks
        // should maybe pick a better number here, 15 is arbitrary limit I chose
        if(queryStrings.length > 15)
        {
            res.statusCode = 400;
            res.writeJsonBody("Error: Search for <= 15 packages at a time");
            logDiagnostic(format("Error: too many parameters in search string : %s", queryStrings));
            return;
        }
 
        // do the search, putting the results into a json object
        Json json = Json.emptyObject;
        foreach(str; queryStrings){
            json[str] = m_registry.searchPackages([str])
                .map!( a => a["name"] ).array;  // pull the name field out of the package json data
        }
        res.statusCode = 200;
        res.writeJsonBody(json);
    }
}
