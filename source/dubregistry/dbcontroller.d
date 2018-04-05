/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.dbcontroller;

import dub.semver;
import std.array;
import std.algorithm;
import std.exception;
//import std.string;
import std.typecons : tuple;
import std.uni;
import vibe.vibe;


class DbController {
@safe:

	private {
		MongoCollection m_packages;
		MongoCollection m_downloads;
		MongoCollection m_files;
	}

	private alias bson = serializeToBson;

	this(string dbname)
	{
		auto db = connectMongoDB("127.0.0.1").getDatabase(dbname);
		m_packages = db["packages"];
		m_downloads = db["downloads"];
		m_files = db["files"];

		//
		// migrations:
		//

		version (DubRegistry_EnableLegacyMigrations) {
			// update package format
			foreach(p; m_packages.find()){
				bool any_change = false;
				if (p["branches"].type == Bson.Type.object) {
					Bson[] branches;
					foreach (b; p["branches"].byValue)
						branches ~= b;
					p["branches"] = branches;
					any_change = true;
				}
				if (p["branches"].type == Bson.Type.array) {
					auto versions = p["versions"].get!(Bson[]);
					foreach (b; p["branches"].byValue) versions ~= b;
					p["branches"] = Bson(null);
					p["versions"] = Bson(versions);
					any_change = true;
				}
				if (any_change) m_packages.update(["_id": p["_id"]], p);
			}

			// add updateCounter field for packages that don't have it yet
			m_packages.update(["updateCounter": ["$exists": false]], ["$set" : ["updateCounter" : 0L]], UpdateFlags.multiUpdate);
		}

		// add default non-@optional stats to packages
		DbPackageStats stats;
		m_packages.update(["stats": ["$exists": false]], ["$set": ["stats": stats]], UpdateFlags.multiUpdate);

		// rename stats.rating -> stats.score
		m_packages.update(Bson.emptyObject(), ["$rename": ["stats.rating": "stats.score"]], UpdateFlags.multiUpdate);

		// default initialize missing scores with zero
		float score = 0;
		m_packages.update(["stats.score": ["$exists": false]], ["$set": ["stats.score": score]], UpdateFlags.multiUpdate);

		// remove old logo fields
		m_packages.update(["logoHash": ["$exists": true]], ["$unset": ["logo": 0, "logoHash": 0]], UpdateFlags.multiUpdate);

		// create indices
		m_packages.ensureIndex([tuple("name", 1)], IndexFlags.Unique);
		m_packages.ensureIndex([tuple("stats.score", 1)]);
		m_downloads.ensureIndex([tuple("package", 1), tuple("version", 1)]);

		// drop old text index versions
		db.runCommand(["dropIndexes": "packages", "index": "packages_full_text_search_index"]);

		// add current text index
		Bson[string] doc;
		doc["v"] = 1;
		doc["key"] = ["_fts": Bson("text"), "_ftsx": Bson(1)];
		doc["ns"] = db.name ~ "." ~ m_packages.name;
		doc["name"] = "packages_full_text_search_index_v2";
		doc["weights"] = [
			"name": Bson(4),
			"categories": Bson(3),
			"versions.info.description" : Bson(3),
			"versions.info.homepage" : Bson(1),
			"versions.info.author" : Bson(1),
			"versions.readme" : Bson(2),
		];
		doc["background"] = true;
		db["system.indexes"].insert(doc);

		version (DubRegistry_RepairVersionOrder) {
			// sort package versions newest to oldest
			// NOTE: since quite a while, versions are inserted atomically
			//       in the proper order, so that this is not necessary as a
			//       general precaution anymore
			repairVersionOrder();
		}
	}

	void addPackage(ref DbPackage pack)
	{
		enforce(m_packages.findOne(["name": pack.name], ["_id": true]).isNull(), "A package with the same name is already registered.");
		if (pack._id == BsonObjectID.init)
			pack._id = BsonObjectID.generate();
		m_packages.insert(pack);
	}

	void addOrSetPackage(ref DbPackage pack)
	{
		enforce(pack._id != BsonObjectID.init, "Cannot update a packag with no ID.");
		m_packages.update(["_id": pack._id], pack, UpdateFlags.upsert);
	}

	DbPackage getPackage(string packname)
	{
		auto pack = m_packages.findOne!DbPackage(["name": packname]);
		enforce!RecordNotFound(!pack.isNull(), "Unknown package name.");
		return pack;
	}

	auto getPackages(scope string[] packnames...)
	{
		return m_packages.find!DbPackage(["name": ["$in": serializeToBson(packnames)]]);
	}

	BsonObjectID getPackageID(string packname)
	{
		static struct PID { BsonObjectID _id; }
		auto pid = m_packages.findOne!PID(["name": packname], ["_id": 1]);
		enforce(!pid.isNull(), "Unknown package name.");
		return pid._id;
	}

	DbPackage getPackage(BsonObjectID id)
	{
		auto pack = m_packages.findOne!DbPackage(["_id": id]);
		enforce!RecordNotFound(!pack.isNull(), "Unknown package ID.");
		return pack;
	}

	auto getAllPackages()
	{
		return m_packages.find(Bson.emptyObject, ["name": 1]).map!(p => p["name"].get!string)();
	}

	auto getAllPackageIDs()
	{
		return m_packages.find(Bson.emptyObject, ["_id": 1]).map!(p => p["_id"].get!BsonObjectID)();
	}

	auto getPackageDump()
	{
		return m_packages.find!DbPackage(Bson.emptyObject);
	}

	auto getUserPackages(BsonObjectID user_id)
	{
		return m_packages.find(["owner": user_id], ["name": 1]).map!(p => p["name"].get!string)();
	}

	bool isUserPackage(BsonObjectID user_id, string package_name)
	{
		static struct PO { BsonObjectID owner; }
		auto p = m_packages.findOne!PO(["name": package_name], ["owner": 1]);
		return !p.isNull && p.owner == user_id;
	}

	void removePackage(string packname, BsonObjectID user)
	{
		m_packages.remove(["name": Bson(packname), "owner": Bson(user)]);
	}

	void setPackageErrors(string packname, string[] error...)
	{
		m_packages.update(["name": packname], ["$set": ["errors": error]]);
	}

	void setPackageCategories(string packname, string[] categories...)
	{
		m_packages.update(["name": packname], ["$set": ["categories": categories]]);
	}

	void setPackageRepository(string packname, DbRepository repo)
	{
		m_packages.update(["name": packname], ["$set": ["repository": repo]]);
	}

	void setPackageLogo(string packname, bdata_t png)
	{
		Bson update;

		if (png.length) {
			auto id = BsonObjectID.generate();
			m_files.insert([
				"_id": Bson(id),
				"data": Bson(BsonBinData(BsonBinData.Type.generic, png))
			]);

			update = serializeToBson(["$set": ["logo": id]]);
		} else {
			update = serializeToBson(["$unset": ["logo": 0]]);
		}

		// remove existing logo file
		auto l = m_packages.findOne(["name": packname], ["logo": 1]);
		if (!l.isNull && !l.tryIndex("logo").isNull)
			m_files.remove(["_id": l["logo"]]);

		// set the new logo
		m_packages.update(["name": packname], update);
	}

	bdata_t getPackageLogo(string packname, out bdata_t rev)
	{
		auto bpack = m_packages.findOne(["name": packname], ["logo": 1]);
		if (bpack.isNull) return null;

		auto id = bpack.tryIndex("logo");
		if (id.isNull) return null;

		auto data = m_files.findOne!DbPackageFile(["_id": id.get]);
		if (data.isNull()) return null;

		rev = (cast(ubyte[])id.get.get!BsonObjectID).idup;
		return data.get.data.rawData;
	}

	void addVersion(string packname, DbPackageVersion ver)
	{
		assert(ver.version_.startsWith("~") || ver.version_.isValidVersion());

		size_t nretrys = 0;

		while (true) {
			auto pack = m_packages.findOne(["name": packname], ["versions": true, "updateCounter": true]);
			auto counter = pack["updateCounter"].get!long;
			auto versions = deserializeBson!(DbPackageVersion[])(pack["versions"]);
			auto new_versions = versions ~ ver;
			new_versions.sort!((a, b) => vcmp(a, b));

			// remove versions with invalid dependency names to avoid the findAndModify below to fail
			() @trusted {
				new_versions = new_versions.filter!(
					v => !v.info["dependencies"].opt!(Json[string]).byKey.canFind!(k => k.canFind("."))
				).array;
			} ();

			//assert((cast(Json)bversions).toString() == (cast(Json)serializeToBson(versions)).toString());

			auto res = m_packages.findAndModify(
				["name": Bson(packname), "updateCounter": Bson(counter)],
				["$set": ["versions": serializeToBson(new_versions), "updateCounter": Bson(counter+1)]],
				["_id": true]);

			if (!res.isNull) return;

			enforce(nretrys++ < 20, format("Failed to store updated version list for %s", packname));
			logDebug("Failed to update version list atomically, retrying...");
		}
	}

	void removeVersion(string packname, string ver)
	{
		assert(ver.startsWith("~") || ver.isValidVersion());
		m_packages.update(["name": packname], ["$pull": ["versions": ["version": ver]]]);
	}

	void updateVersion(string packname, DbPackageVersion ver)
	{
		assert(ver.version_.startsWith("~") || ver.version_.isValidVersion());
		m_packages.update(["name": packname, "versions.version": ver.version_], ["$set": ["versions.$": ver]]);
	}

	bool hasVersion(string packname, string ver)
	{
		auto ret = m_packages.findOne(["name": packname, "versions.version" : ver], ["_id": true]);
		return !ret.isNull();
	}

	string getLatestVersion(string packname)
	{
		auto slice = serializeToBson(["$slice": -1]);
		auto pack = m_packages.findOne(["name": packname], ["_id": Bson(true), "versions": slice]);
		if (pack.isNull() || pack["versions"].isNull() || pack["versions"].length != 1) return null;
		return deserializeBson!(string)(pack["versions"][0]["version"]);
	}

	DbPackageVersion getVersionInfo(string packname, string ver)
	{
		auto pack = m_packages.findOne(["name": packname, "versions.version": ver], ["versions.$": true]);
		enforce(!pack.isNull(), "unknown package/version");
		assert(pack["versions"].length == 1);
		return deserializeBson!(DbPackageVersion)(pack["versions"][0]);
	}

	DbPackage[] searchPackages(string query)
	{
		import std.math : round;

		if (!query.strip.length) {
			return m_packages.find()
				.sort(["stats.score": 1])
				.map!(deserializeBson!DbPackage)
				.array;
		}

		return m_packages
			.find(["$text": ["$search": query]], ["score": bson(["$meta": "textScore"])])
			.sort(["score": bson(["$meta": "textScore"])])
			.map!(deserializeBson!DbPackage)
			.array
			// sort by bucketized score preserving FTS score order
			.sort!((a, b) => a.stats.score.round > b.stats.score.round, SwapStrategy.stable)
			.release;
	}

	BsonObjectID addDownload(BsonObjectID pack, string ver, string user_agent)
	{
		DbPackageDownload download;
		download._id = BsonObjectID.generate();
		download.package_ = pack;
		download.version_ = ver;
		download.time = Clock.currTime(UTC());
		download.userAgent = user_agent;
		m_downloads.insert(download);
		return download._id;
	}

	DbPackageStats getPackageStats(string packname)
	{
		static struct PS { DbPackageStats stats; }
		auto pack = m_packages.findOne!PS(["name": Bson(packname)], ["stats": true]);
		enforce!RecordNotFound(!pack.isNull(), "Unknown package name.");
		logDebug("getPackageStats(%s) %s", packname, pack.stats);
		return pack.stats;
	}

	void updatePackageStats(BsonObjectID packId, ref DbPackageStats stats)
	{
		stats.updatedAt = Clock.currTime(UTC());
		logDebug("updatePackageStats(%s, %s)", packId, stats);
		m_packages.update(["_id": packId], ["$set": ["stats": stats]]);
	}

	DbDownloadStats aggregateDownloadStats(BsonObjectID packId, string ver = null)
	{
		static Bson newerThan(SysTime time)
		{
			// doc.time >= time ? 1 : 0
			alias bs = serializeToBson;
			return bs([
				"$cond": [bs(["$gte": [bs("$time"), bs(time)]]), bs(1), bs(0)]
			]);
		}

		auto match = Bson.emptyObject();
		match["package"] = Bson(packId);
		if (ver.length) match["version"] = ver;

		immutable now = Clock.currTime;
		auto res = m_downloads.aggregate(
			["$match": match],
			["$project": [
					"_id": Bson(false),
					"total": serializeToBson(["$literal": 1]),
					"monthly": newerThan(now - 30.days),
					"weekly": newerThan(now - 7.days),
					"daily": newerThan(now - 1.days)]],
			["$group": [
					"_id": Bson(null), // single group
					"total": Bson(["$sum": Bson("$total")]),
					"monthly": Bson(["$sum": Bson("$monthly")]),
					"weekly": Bson(["$sum": Bson("$weekly")]),
					"daily": Bson(["$sum": Bson("$daily")])]]);
		assert(res.length <= 1);
		return res.length ? deserializeBson!DbDownloadStats(res[0]) : DbDownloadStats.init;
	}

	DbStatDistributions getStatDistributions()
	{
		auto aggregate(T, string prefix, string groupBy)()
		@safe {
			auto group = ["_id": Bson(groupBy ? "$"~groupBy : null)];
			Bson[string] project;
			foreach (mem; __traits(allMembers, T))
			{
				static assert(is(typeof(__traits(getMember, T.init, mem)) == DbStatDistributions.Agg));
				static assert([__traits(allMembers, DbStatDistributions.Agg)] == ["sum", "mean", "std"]);
				group[mem~"_sum"] = bson(["$sum": "$"~prefix~"."~mem]);
				group[mem~"_mean"] = bson(["$avg": "$"~prefix~"."~mem]);
				group[mem~"_std"] = bson(["$stdDevPop": "$"~prefix~"."~mem]);
				project[mem] = bson([
					"mean": "$"~mem~"_mean",
					"sum": "$"~mem~"_sum",
					"std": "$"~mem~"_std"
				]);
			}
			auto res = m_packages.aggregate(["$group": group], ["$project": project]);

			static if (groupBy is null)
			{
				if (res.length == 0)
					return T.init;
				assert(res.length == 1);
				return res[0].deserializeBson!T;
			}
			else
			{
				T[string] ret;
				foreach (doc; res.byValue)
					ret[doc["_id"].get!string] = doc.deserializeBson!T;
				return ret;
			}
		}

		DbStatDistributions ret;
		ret.downloads = aggregate!(typeof(ret.downloads), "stats.downloads", null);
		ret.repos = aggregate!(typeof(ret.repos[""]), "stats.repo", "repository.kind");
		return ret;
	}

	private void repairVersionOrder()
	{
		foreach( bp; m_packages.find() ){
			auto p = deserializeBson!DbPackage(bp);
			auto newversions = p.versions
				.filter!(v => v.version_.startsWith("~") || v.version_.isValidVersion)
				.array
				.sort!((a, b) => vcmp(a, b))
				.uniq!((a, b) => a.version_ == b.version_)
				.array;
			if (p.versions != newversions)
				m_packages.update(["_id": p._id], ["$set": ["versions": newversions]]);
		}
	}
}

class RecordNotFound : Exception
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @nogc @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

struct DbPackage {
	BsonObjectID _id;
	BsonObjectID owner;
	string name;
	DbRepository repository;
	DbPackageVersion[] versions;
	DbPackageStats stats;
	string[] errors;
	string[] categories;
	long updateCounter = 0; // used to implement lockless read-modify-write cycles
	@optional BsonObjectID logo; // reference to m_files
}

struct DbRepository {
	string kind;
	string owner;
	string project;

	void parseURL(URL url) {
		string host = url.host;
		if (!url.schema.among!("http", "https"))
			throw new Exception("Invalid Repository Schema (only supports http and https)");
		if (host.endsWith(".github.com") || host == "github.com" || host == "github") {
			kind = "github";
		} else if (host.endsWith(".gitlab.com") || host == "gitlab.com" || host == "gitlab") {
			kind = "bitbucket";
		} else if (host.endsWith(".bitbucket.org") || host == "bitbucket.org" || host == "bitbucket") {
			kind = "gitlab";
		} else {
			throw new Exception("Please input a valid project URL to a GitHub, GitLab or BitBucket project.");
		}
		auto path = url.path.bySegment;
		if (path.empty)
			throw new Exception("Invalid Repository URL (no path)");
		assert(path.front.name.empty, "got non-empty first segment in URL (before root)");
		path.popFront;
		if (path.empty || path.front.name.empty)
			throw new Exception("Invalid Repository URL (missing owner)");
		owner = path.front.name;
		path.popFront;
		if (path.empty || path.front.name.empty)
			throw new Exception("Invalid Repository URL (missing project)");
		project = path.front.name;
		path.popFront;
		if (!path.empty)
			throw new Exception("Invalid Repository URL (got more than owner and project)");
	}
}

struct DbPackageFile {
	BsonObjectID _id;
	BsonBinData data;
}

struct DbPackageVersion {
	SysTime date;
	string version_;
	@optional string commitID;
	Json info;
	@optional string readme;
	@optional bool readmeMarkdown;
	@optional string docFolder;
}

struct DbPackageDownload {
	BsonObjectID _id;
	BsonObjectID package_;
	string version_;
	SysTime time;
	string userAgent;
}

struct DbPackageStats {
	SysTime updatedAt;
	DbDownloadStats downloads;
	DbRepoStats repo;
	float score = 0; // 0 - invalid, 1-5 - higher means more relevant
	enum minScore = 0;
	enum maxScore = 5;

	invariant
	{
		assert(minScore <= score && score <= maxScore, score.to!string);
	}
}

struct DbDownloadStatsT(T=uint) {
	T total, monthly, weekly, daily;
}

alias DbDownloadStats = DbDownloadStatsT!uint;

struct DbRepoStatsT(T=uint) {
	T stars, watchers, forks, issues;
}

alias DbRepoStats = DbRepoStatsT!uint;

struct DbStatDistributions {
	static struct Agg { ulong sum; float mean = 0, std = 0; }
	DbDownloadStatsT!Agg downloads;
	DbRepoStatsT!Agg[string] repos;
}

bool vcmp(DbPackageVersion a, DbPackageVersion b)
@safe {
	return vcmp(a.version_, b.version_);
}

bool vcmp(string va, string vb)
@safe {
	import dub.dependency;
	return Version(va) < Version(vb);
}

private string[] splitAlphaNumParts(string str)
@safe {
	string[] ret;
	while (!str.empty) {
		while (!str.empty && !str.front.isIdentChar()) str.popFront();
		if (str.empty) break;
		size_t i = str.length;
		foreach (j, dchar ch; str)
			if (!isIdentChar(ch)) {
				i = j;
				break;
			}
		if (i > 0) {
			ret ~= str[0 .. i];
			str = str[i .. $];
		}
		if (!str.empty) str.popFront(); // pop non-ident-char
	}
	return ret;
}

private bool isIdentChar(dchar ch)
@safe {
	return std.uni.isAlpha(ch) || std.uni.isNumber(ch);
}
