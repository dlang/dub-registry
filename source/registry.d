import vibe.vibe;

import repository;


/// Settings to configure the package registry.
class VpmRegistrySettings {
	/// Prefix used to acces the registry.
	string pathPrefix;
	/// location for the package.json files on the filesystem.
	Path metadataPath;
}

private struct DbPackage {
	BsonObjectID _id;
	BsonObjectID owner;
	string name;
	Bson repository;
	Bson[] versions;
	Bson[string] branches;
}

class VpmRegistry {
	private {
		MongoDB m_db;
		MongoCollection m_packages;
		VpmRegistrySettings m_settings;
	}

	this(MongoDB db, VpmRegistrySettings settings)
	{
		m_db = db;
		m_settings = settings;
		m_packages = db["vpmreg.packages"];

		repairVersionOrder();
	}

	void repairVersionOrder()
	{
		import std.algorithm;

		static int[] linearizeVersion(string ver)
		{
			import std.conv;
			static immutable prefixes = ["alpha", "beta", "rc"];
			auto parts = ver.split(".");
			int[] ret;
			foreach( p; parts ){
				ret ~= parse!int(p);

				bool gotprefix = false;
				foreach( i, prefix; prefixes ){
					if( p.startsWith(prefix) ){
						p = p[prefix.length .. $];
						if( p.length ) ret ~= i*10000 + to!int(p);
						else ret ~= i*10000;
						gotprefix = true;
						break;
					}
				}
				if( !gotprefix ) ret ~= int.max;
			}
			return ret;
		}

		static bool vcmp(Bson a, Bson b)
		{
			try {
				auto va = a["version"].get!string;
				auto vb = b["version"].get!string;
				auto aparts = linearizeVersion(va);
				auto bparts = linearizeVersion(vb);

				foreach( i; 0 .. min(aparts.length, bparts.length) )
					if( aparts[i] != bparts[i] )
						return aparts[i] < bparts[i];
				return aparts.length < bparts.length;
			} catch( Exception e ) return false;
		}

		foreach( bp; m_packages.find() ){
			auto p = deserializeBson!DbPackage(bp);
			sort!vcmp(p.versions);
			m_packages.update(["_id": p._id], ["$set": ["versions": p.versions]]);
		}
	}

	@property string[] availablePackages()
	{
		string[] all;
		foreach( p; m_packages.find(Bson.EmptyObject, ["name": 1]) )
			all ~= p.name.get!string;
		return all;
	}

	void addPackage(Json repository, BsonObjectID user)
	{
		auto rep = getRepository(repository);
		auto info = rep.getPackageInfo("~master");

		enforce(m_packages.findOne(["name": info.name], ["_id": true]).isNull(), "A package with the same name is already registered.");

		DbPackage pack;
		pack._id = BsonObjectID.generate();
		pack.owner = user;
		pack.name = info.name.get!string;
		pack.repository = serializeToBson(repository);
		pack.branches["master"] = serializeToBson(info);
		m_packages.insert(pack);
	}

	void removePackage(string packname, BsonObjectID user)
	{
		logInfo("Removing package %s of %s", packname, user);
		m_packages.remove(["name": Bson(packname), "owner": Bson(user)]);
	}

	string[] getPackages(BsonObjectID user)
	{
		string[] ret;
		foreach( p; m_packages.find(["owner": user], ["name": 1]) )
			ret ~= p.name.get!string;
		return ret;
	}

	Json getPackageInfo(string packname)
	{
		auto pack = m_packages.findOne(["name": packname]);
		if( pack.isNull() ) return Json(null);

		Json[] vers;
		if( !pack["branches"].isNull() )
			foreach( string k, v; pack.branches ){
				auto nfo = cast(Json)v;
				nfo["version"] = "~"~k;
				vers ~= nfo;
			}
		foreach( v; pack.versions.get!(Bson[]) )
			vers ~= v.toJson();

		Json ret = Json.EmptyObject;
		ret["name"] = packname;
		ret["versions"] = Json(vers);
		ret["repository"] = pack.repository.toJson();
		return ret;
	}

	void checkForNewVersions()
	{
		logInfo("Checking for new versions...");
		foreach( packname; this.availablePackages ){
			try {
				auto pack = getPackageInfo(packname);
				auto rep = getRepository(pack.repository);
				foreach( ver; rep.getVersions() ){
					if( !hasVersion(packname, ver) ){
						try {
							addVersion(packname, ver, rep.getPackageInfo(ver));
							logInfo("Added version %s for %s", ver, packname);
						} catch( Exception e ){
							logWarn("Error for version %s of %s: %s", ver, packname, e.msg);
							logDebug("%s", e.toString());
							// TODO: store error message for web frontend!
						}
					}
				}
				foreach( ver; rep.getBranches() ){
					if( !hasVersion(packname, ver) ){
						try {
							addVersion(packname, ver, rep.getPackageInfo(ver));
							logInfo("Added branch %s for %s", ver, packname);
						} catch( Exception e ){
							logWarn("Error for branch %s of %s: %s", ver, packname, e.msg);
							logDebug("%s", e.toString());
							// TODO: store error message for web frontend!
						}
					}
				}
			} catch( Exception e ){
				logWarn("Error processing package %s: %s", packname, e.toString());
				// TODO: store error message for web frontend!
			}
		}
	}

	bool hasVersion(string packname, string ver)
	{
		auto packbson = Bson(packname);
		auto verbson = serializeToBson(["$elemMatch": ["version": ver]]);
		auto ret = m_packages.findOne(["name": packbson, "versions" : verbson]);
		return !ret.isNull();
	}

	protected void addVersion(string packname, string ver, Json info)
	{
		enforce(info.name == packname, "Package name must match the original package name.");
		if( !ver.startsWith("~") ){
			enforce(!hasVersion(packname, info["version"].get!string), "Version already exists.");
			enforce(info["version"] == ver, "Version in package.json differs from git tag version.");
			m_packages.update(["name": packname], ["$push": ["versions": info]]);
		} else {
			m_packages.update(["name": packname], ["$set": ["branches."~ver[1 .. $]: info]]);
		}
	}
}


class VpmRegistryController {
	private {
		VpmRegistry m_registry;
		string m_prefix;
	}

	this(VpmRegistry reg)
	{
		m_registry = reg;
		m_prefix = reg.m_settings.pathPrefix;
	}

	void register(UrlRouter router)
	{
		router.get(m_prefix~"available", &showAvailable);
		router.get(m_prefix~"packages/:packname", &showPackage);
	}

	void showAvailable(HttpServerRequest req, HttpServerResponse res)
	{
		res.writeJsonBody(m_registry.availablePackages);
	}

	void showPackage(HttpServerRequest req, HttpServerResponse res)
	{
		string pname = req.params["packname"];
		if( pname.endsWith(".json") )
			pname = pname[0 .. $-5];
		auto info = m_registry.getPackageInfo(pname);
		if( info == null ) return;
		res.writeJsonBody(info);
	}
}
