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


void mirrorRegistry(DubRegistry registry, URL url)
nothrow {
	logInfo("Polling '%s' for updates...", url);
	try {
		bool[string] current_packs;
		auto packs = requestHTTP(url ~ Path("packages/index.json")).readJson();
		foreach (p; packs) {
			auto pname = p.get!string;
			current_packs[pname] = true;
			try setPackage(registry, url, pname);
			catch (Exception e) {
				logError("Failed to add/update package '%s': %s", p, e.msg);
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

private void setPackage(DubRegistry registry, URL src_reg, string pack_name)
{
	auto db = registry.db;

	auto info = requestHTTP(src_reg ~ Path("packages/"~pack_name~".json")).readJson();

	DbPackage pack;
	pack._id = BsonObjectID.fromString(info["id"].get!string);
	pack.name = info["name"].get!string;
	pack.owner = BsonObjectID.fromString(info["owner"].get!string);
	pack.repository = info["repository"];
	foreach (jv; info["versions"]) {
		DbPackageVersion v;
		v.version_ = jv["version"].get!string;
		v.readme = jv["readme"].opt!string;
		v.date = SysTime.fromISOExtString(jv["date"].get!string);

		auto info = jv.get!(Json[string]).dup;
		info.remove("readme");
		info.remove("url");
		info.remove("date");
		v.info = Json(info);
		pack.versions ~= v;
	}
	logInfo("Updating package '%s'", pack_name);
	db.addOrSetPackage(pack);
}

private void removePackage(DubRegistry registry, string pack_name)
{
	logInfo("Removing package '%s", pack_name);
	auto uid = registry.db.getPackage(pack_name).owner;
	registry.removePackage(pack_name, User.ID(uid));
}
