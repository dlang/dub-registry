/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.dbcontroller;

import dub.semver;

import vibe.core.log;
import vibe.db.mongo.collection;

import std.array;
import std.algorithm;
import std.conv;
import std.datetime.systime;
import std.datetime.timezone;
import std.exception;
import std.format;
import std.string;
import std.typecons : tuple;
import std.uni;

import core.time;


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
		import dubregistry.mongodb : getMongoClient;
		auto db = getMongoClient.getDatabase(dbname);
		m_packages = db["packages"];
		m_downloads = db["downloads"];
		m_files = db["files"];

		//
		// migrations:
		//

		// create indices
		IndexOptions opt;
		opt.unique = true;
		m_packages.createIndexes([
			IndexModel().add("name", 1).withOptions(opt),
			IndexModel().add("stats.score", 1)
		]);
		m_downloads.createIndex(IndexModel().add("package", 1).add("version", 1));

		// add current text index
 	immutable keyWeights = [
 		"name": 8,
 		"categories": 4,
 		"versions.info.subPackages.name": 4,
 		"versions.info.description": 2,
 		"versions.info.authors": 1
 	];
 	Bson[string] fts;
 	fts["key"] = Bson.emptyObject;
 	fts["weights"] = Bson.emptyObject;
 	foreach (k, w; keyWeights)
 	{
 		fts["key"][k] = Bson("text");
 		fts["weights"][k] = Bson(w);
 	}
 	fts["name"] = "packages_full_text_search_index_v4";
		fts["background"] = true;
		auto cmd = Bson.emptyObject;
		cmd["createIndexes"] = Bson("packages");
		cmd["indexes"] = [Bson(fts)];
		// Create search index
		db.runCommandChecked(cmd);
	}

	void addPackage(ref DbPackage pack)
	{
		enforce(m_packages.findOne(["name": pack.name], ["_id": true]).isNull(), "A package with the name \""~pack.name~"\" is already registered.");
		if (pack._id == BsonObjectID.init)
			pack._id = BsonObjectID.generate();
		m_packages.insertOne(pack);
	}

	void addOrSetPackage(ref DbPackage pack)
	{
		enforce(pack._id != BsonObjectID.init, "Cannot update a packag with no ID.");
		UpdateOptions opts;
		opts.upsert = true;
		m_packages.replaceOne(["_id": pack._id], pack, opts);
	}

	DbPackage getPackage(string packname)
	{
		auto pack = m_packages.findOne!DbPackage(["name": packname]);
		enforce!RecordNotFound(!pack.isNull(), "Unknown package name.");
		return pack.get;
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
		return pid.get._id;
	}

	DbPackage getPackage(BsonObjectID id)
	{
		auto pack = m_packages.findOne!DbPackage(["_id": id]);
		enforce!RecordNotFound(!pack.isNull(), "Unknown package ID.");
		return pack.get;
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

	auto getShallowPackageDump()
	{
		import std.typecons : nullable;

		static immutable fields = Bson([
			"owner": Bson(1),
			"name": Bson(1),
			"repository": Bson(1),
			"stats": Bson(1),
			"categories": Bson(1),
			"logo": Bson(1),
			"documentationURL": Bson(1),
			"textScore": Bson(1),
			"versions.version": Bson(1),
			"versions.date": Bson(1),
		]);

		Bson projection = fields;
		FindOptions options;
		options.projection = nullable(projection);

		return m_packages.find!DbShallowPackage(Bson.emptyObject, options);
	}

	auto getUserPackages(BsonObjectID user_id)
	{
		return m_packages.find(["owner": user_id], ["name": 1]).map!(p => p["name"].get!string)();
	}

	auto getSharedPackages(BsonObjectID user_id)
	{
		return m_packages.find(["sharedUsers.id": user_id], ["name": 1]).map!(p => p["name"].get!string)();
	}

	bool isUserPackage(BsonObjectID user_id, string package_name,
		DbPackage.Permissions permissions = DbPackage.Permissions.ownerOnly)
	{
		static struct PO {
			BsonObjectID owner;
			@optional DbPackage.SharedUser[] sharedUsers;
		}

		auto p = m_packages.findOne!PO(["name": package_name], ["owner": 1, "sharedUsers": 1]);
		if (p.isNull)
			return false;
		auto dummy = DbPackage(BsonObjectID.init, p.get.owner, p.get.sharedUsers);
		return dummy.hasPermissions(user_id, permissions);
	}

	void removePackage(string packname, BsonObjectID user)
	{
		m_packages.deleteOne(["name": Bson(packname), "owner": Bson(user)]);
	}

	void setPackageErrors(string packname, string[] error...)
	{
		m_packages.updateOne(["name": packname], ["$set": ["errors": error]]);
	}

	void setPackageCategories(string packname, string[] categories...)
	{
		m_packages.updateOne(["name": packname], ["$set": ["categories": categories]]);
	}

	void setPackageRepository(string packname, DbRepository repo)
	{
		m_packages.updateOne(["name": packname], ["$set": ["repository": repo]]);
	}

	void setPackageLogo(string packname, bdata_t png)
	{
		Bson update;

		if (png.length) {
			auto id = BsonObjectID.generate();
			m_files.insertOne([
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
			m_files.deleteOne(["_id": l["logo"]]);

		// set the new logo
		m_packages.updateOne(["name": packname], update);
	}

	void setDocumentationURL(string packname, string documentationURL)
	{
		m_packages.updateOne(["name": packname], ["$set": ["documentationURL": documentationURL]]);
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

	void upsertSharedUser(string packname, BsonObjectID sharedUser, DbPackage.Permissions permissions)
	{
		Bson obj = Bson([
			"id": Bson(sharedUser),
			"permissions": Bson(cast(uint) permissions)
		]);
		// bulk operation with updateImpl to make array upsert as close to atomic as we can
		Bson opts = Bson.emptyObject;
		opts["multi"] = Bson(false);
		auto query = ["name": Bson(packname)];
		m_packages.updateImpl([query, query], [
			["$pull": Bson(["sharedUsers": Bson(["id": Bson(sharedUser)])])],
			["$push": Bson(["sharedUsers": obj])]
		], [opts, opts]);
	}

	void removeSharedUser(string packname, BsonObjectID sharedUser)
	{
		m_packages.updateOne([
			"name": packname
		], [
			"$pull": ["sharedUsers": ["id": sharedUser]]
		]);
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
		m_packages.updateOne(["name": packname], ["$pull": ["versions": ["version": ver]]]);
	}

	void updateVersion(string packname, DbPackageVersion ver)
	{
		assert(ver.version_.startsWith("~") || ver.version_.isValidVersion());
		m_packages.updateOne(["name": packname, "versions.version": ver.version_], ["$set": ["versions.$": ver]]);
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

		auto pkgs = m_packages
			.find(["$text": ["$search": query]], ["textScore": bson(["$meta": "textScore"])])
			.sort(["textScore": bson(["$meta": "textScore"])]) // sort to only keep most relevant results
			.limit(50) // limit irrelevant sort results (fixes #341)
			.map!(deserializeBson!DbPackage)
			.array;

		// normalize textScore to same scale as package score
		immutable minMaxTS = pkgs.map!(p => p.textScore).fold!(min, max)(0.0f, 0.0f);
		immutable scale = (DbPackageStats.maxScore - DbPackageStats.minScore) / (minMaxTS[1] - minMaxTS[0]);
		foreach (ref pkg; pkgs)
			pkg.textScore = (pkg.textScore - minMaxTS[0]) * scale + DbPackageStats.minScore;

		// sort found packages by weighted textScore and package score
		return pkgs
			.sort!((a, b) => a.stats.score + 2 * a.textScore > b.stats.score + 2 * b.textScore)
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
		m_downloads.insertOne(download);
		return download._id;
	}

	DbPackageStats getPackageStats(string packname)
	{
		static struct PS { DbPackageStats stats; }
		auto pack = m_packages.findOne!PS(["name": Bson(packname)], ["stats": true]);
		enforce!RecordNotFound(!pack.isNull(), "Unknown package name.");
		logDebug("getPackageStats(%s) %s", packname, pack.get.stats);
		return pack.get.stats;
	}

	void updatePackageStats(BsonObjectID packId, ref DbPackageStats stats)
	{
		stats.updatedAt = Clock.currTime(UTC());
		logDebug("updatePackageStats(%s, %s)", packId, stats);
		m_packages.updateOne(["_id": packId], ["$set": ["stats": stats]]);
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
		auto res = () @trusted { return m_downloads.aggregate(
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
			} ();
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
			auto res = () @trusted {
					return m_packages.aggregate(["$group": group], ["$project": project]);
				} ();

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
				m_packages.updateOne(["_id": p._id], ["$set": ["versions": newversions]]);
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
	enum Permissions : uint {
		/// Can view metadata, included with all other permissions
		readonly = 0,
		/// Trigger updates
		update = 1u << 0,
		/// Change picture, documentation URL and categories
		metadata = 1u << 1,
		/// Transfer repository
		source = 1u << 2,
		/// Manage access of other shared owners + all other permissions.
		/// Note: when adding new permissions, admins don't get them by default,
		/// they would need to be reassigned by the owner.
		admin = 1u << 3,

		/// All other bits (triggers bad request when attempting to give)
		invalid = ~(admin | source | metadata | update),
		/// Not usable in DB, only for checks
		ownerOnly = uint.max
	}

	static bool isValidPermissions(uint permissions) {
		if (permissions & Permissions.invalid)
			return false;
		return true;
	}

	struct SharedUser {
		/// User ID
		BsonObjectID id;
		Permissions permissions;
		/// Set in web.d getMyPackagesPackage
		@ignore string name;
	}

	BsonObjectID _id;
	BsonObjectID owner;
	@optional SharedUser[] sharedUsers;
	string name;
	DbRepository repository;
	DbPackageVersion[] versions;
	DbPackageStats stats;
	string[] errors;
	string[] categories;
	long updateCounter = 0; // used to implement lockless read-modify-write cycles
	@optional BsonObjectID logo; // reference to m_files
	@optional string documentationURL;
	@optional float textScore = 0; // for FTS textScore in searchPackages

	bool hasPermissions(BsonObjectID user, Permissions permissions)
	const @safe pure nothrow @nogc {
		if (permissions == Permissions.ownerOnly)
			return user == owner;

		return user == owner // owner has all permissions
			|| sharedUsers.canFind!(o => o.id == user
				&& (o.permissions & permissions) == permissions);
	}
}

struct DbRepository {
	string kind;
	string owner;
	string project;
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

struct DbShallowPackage {
	BsonObjectID _id;
	BsonObjectID owner;
	string name;
	DbRepository repository;
	DBShallowPackageVersion[] versions;
	DbPackageStats stats;
	string[] categories;
	@optional BsonObjectID logo;
	@optional string documentationURL;
	@optional float textScore = 0;
}

struct DBShallowPackageVersion {
	SysTime date;
	string version_;
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
