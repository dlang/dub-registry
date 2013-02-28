module dubregistry.registry;

import dubregistry.repositories.repository;

import std.algorithm : sort;
import vibe.vibe;


/// Settings to configure the package registry.
class DubRegistrySettings {
	/// Prefix used to acces the registry.
	string pathPrefix;
	/// location for the package.json files on the filesystem.
	Path metadataPath;
}

private struct DbPackage {
	BsonObjectID _id;
	BsonObjectID owner;
	string name;
	Json repository;
	DbPackageVersion[] versions;
	DbPackageVersion[string] branches;
	string[] errors;
}

private struct DbPackageVersion {
	BsonDate date;
	string version_;
	Json info;
}

class DubRegistry {
	private {
		MongoClient m_db;
		MongoCollection m_packages;
		DubRegistrySettings m_settings;
	}

	this(DubRegistrySettings settings)
	{
		m_db = connectMongoDB("127.0.0.1");
		m_settings = settings;
		m_packages = m_db.getCollection("vpmreg.packages");

		repairVersionOrder();
	}

	void repairVersionOrder()
	{
		foreach( bp; m_packages.find() ){
			auto p = deserializeBson!DbPackage(bp);
			sort!((a, b) => vcmp(a, b))(p.versions);
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
		auto info = rep.getVersionInfo("~master");

		checkPackageName(info.info.name.get!string);
		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			checkPackageName(n);

		enforce(m_packages.findOne(["name": info.info.name], ["_id": true]).isNull(), "A package with the same name is already registered.");

		DbPackageVersion vi;
		vi.date = BsonDate(info.date);
		vi.version_ = info.version_;
		vi.info = info.info;

		DbPackage pack;
		pack._id = BsonObjectID.generate();
		pack.owner = user;
		pack.name = info.info.name.get!string;
		pack.repository = repository;
		pack.branches["master"] = vi;
		m_packages.insert(pack);

		runTask({ checkForNewVersions(pack.name); });
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

	Json getPackageInfo(string packname, bool include_errors = false)
	{
		auto bpack = m_packages.findOne(["name": packname]);
		if( bpack.isNull() ) return Json(null);

		auto pack = deserializeBson!DbPackage(bpack);

		auto rep = getRepository(pack.repository);

		Json[] vers;
		foreach( string k, v; pack.branches ){
			auto nfo = v.info;
			nfo["version"] = "~"~k;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl("~"~k);
			nfo.downloadUrl = nfo.url;
			vers ~= nfo;
		}
		foreach( v; pack.versions ){
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl(v.version_);
			nfo.downloadUrl = nfo.url;
			vers ~= nfo;
		}

		Json ret = Json.EmptyObject;
		ret.name = packname;
		ret.versions = Json(vers);
		ret.repository = pack.repository;
		if( include_errors ) ret.errors = serializeToJson(pack.errors);
		return ret;
	}

	void checkForNewVersions()
	{
		logInfo("Checking for new versions...");
		foreach( packname; this.availablePackages ){
			checkForNewVersions(packname);
		}
	}

	void checkForNewVersions(string packname)
	{
		import std.encoding;
		string[] errors;

		Json pack;
		try pack = getPackageInfo(packname);
		catch( Exception e ){
			errors ~= format("Error getting package info: %s", e.msg);
			logDebug("%s", sanitize(e.toString()));
			return;
		}

		Repository rep;
		try rep = getRepository(pack.repository);
		catch( Exception e ){
			errors ~= format("Error accessing repository: %s", e.msg);
			logDebug("%s", sanitize(e.toString()));
			return;
		}

		try {
			foreach( ver; rep.getVersions().sort!((a, b) => vcmp(a, b))() ){
				if( !hasVersion(packname, ver) ){
					try {
						addVersion(packname, ver, rep.getVersionInfo(ver));
						logInfo("Added version %s for %s", ver, packname);
					} catch( Exception e ){
						logDebug("version %s", sanitize(e.toString()));
						errors ~= format("Version %s: %s", ver, e.msg);
						// TODO: store error message for web frontend!
					}
				}
			}
			foreach( ver; rep.getBranches() ){
				if( !hasVersion(packname, ver) ){
					try {
						addVersion(packname, ver, rep.getVersionInfo(ver));
						logInfo("Added branch %s for %s", ver, packname);
					} catch( Exception e ){
						logDebug("%s", sanitize(e.toString()));
						// TODO: store error message for web frontend!
						errors ~= format("Branch %s: %s", ver, e.msg);
					}
				}
			}
		} catch( Exception e ){
			logDebug("%s", sanitize(e.toString()));
			// TODO: store error message for web frontend!
			errors ~= e.msg;
		}
		setPackageErrors(packname, errors);
	}

	bool hasVersion(string packname, string ver)
	{
		auto packbson = Bson(packname);
		auto verbson = serializeToBson(["$elemMatch": ["version": ver]]);
		auto ret = m_packages.findOne(["name": packbson, "versions" : verbson], ["_id": true]);
		return !ret.isNull();
	}

	protected void addVersion(string packname, string ver, PackageVersionInfo info)
	{
		enforce(info.info.name == packname, "Package name must match the original package name.");

		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			checkPackageName(n);

		DbPackageVersion dbver;
		dbver.date = BsonDate(info.date);
		dbver.version_ = info.version_;
		dbver.info = info.info;

		if( !ver.startsWith("~") ){
			enforce(!hasVersion(packname, info.version_), "Version already exists.");
			enforce(info.version_ == ver, "Version in package.json differs from git tag version.");
			m_packages.update(["name": packname], ["$push": ["versions": dbver]]);
		} else {
			m_packages.update(["name": packname], ["$set": ["branches."~ver[1 .. $]: dbver]]);
		}
	}

	protected void setPackageErrors(string pack, string[] error...)
	{
		m_packages.update(["name": pack], ["$set": ["errors": error]]);
	}
}

private void checkPackageName(string n){
	enforce(n.length > 0, "Package names may not be empty.");
	foreach( ch; n ){
		switch(ch){
			default:
				throw new Exception("Package names may only contain ASCII letters and numbers, as well as '_' and '-'.");
			case 'a': .. case 'z':
			case 'A': .. case 'Z':
			case '0': .. case '9':
			case '_', '-':
				break;
		}
	}
}


private int[] linearizeVersion(string ver)
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
				if( p.length ) ret ~= cast(int)i*10000 + to!int(p);
				else ret ~= cast(int)i*10000;
				gotprefix = true;
				break;
			}
		}
		if( !gotprefix ) ret ~= int.max;
	}
	return ret;
}

bool vcmp(DbPackageVersion a, DbPackageVersion b)
{
	return vcmp(a.version_, b.version_);
}

bool vcmp(string va, string vb)
{
	try {
		auto aparts = linearizeVersion(va);
		auto bparts = linearizeVersion(vb);

		foreach( i; 0 .. min(aparts.length, bparts.length) )
			if( aparts[i] != bparts[i] )
				return aparts[i] < bparts[i];
		return aparts.length < bparts.length;
	} catch( Exception e ) return false;
}

