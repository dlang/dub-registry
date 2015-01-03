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
import std.uni;
import vibe.vibe;


class DbController {
	private {
		MongoCollection m_packages;
		MongoCollection m_downloads;
	}

	this(string dbname)
	{
		auto db = connectMongoDB("127.0.0.1").getDatabase(dbname);
		m_packages = db["packages"];
		m_downloads = db["downloads"];

		// update package format
		foreach(p; m_packages.find()){
			if (p.branches.type == Bson.Type.object) {
				Bson[] branches;
				foreach( b; p.branches )
					branches ~= b;
				p.branches = branches;
			}
			if (p.branches.type == Bson.Type.array) {
				auto versions = p.versions.get!(Bson[]);
				foreach (b; p.branches) versions ~= b;
				p.branches = Bson(null);
				p.versions = Bson(versions);
			}
			m_packages.update(["_id": p._id], p);
		}

		repairVersionOrder();

		// create indices
		m_packages.ensureIndex(["name": 1], IndexFlags.Unique);
		m_packages.ensureIndex(["searchTerms": 1]);
		m_downloads.ensureIndex([tuple("package", 1), tuple("version", 1)]);
	}

	void addPackage(ref DbPackage pack)
	{
		enforce(m_packages.findOne(["name": pack.name], ["_id": true]).isNull(), "A package with the same name is already registered.");
		pack._id = BsonObjectID.generate();
		m_packages.insert(pack);
		updateKeywords(pack.name);
	}

	DbPackage getPackage(string packname)
	{
		auto bpack = m_packages.findOne(["name": packname]);
		enforce(!bpack.isNull(), "Unknown package name.");
		return deserializeBson!DbPackage(bpack);
	}

	auto getAllPackages()
	{
		return m_packages.find(Bson.emptyObject, ["name": 1]).map!(p => p.name.get!string)();
	}

	auto getUserPackages(BsonObjectID user_id)
	{
		return m_packages.find(["owner": user_id], ["name": 1]).map!(p => p.name.get!string)();
	}

	bool isUserPackage(BsonObjectID user_id, string package_name)
	{
		return !m_packages.findOne(["owner": Bson(user_id), "name": Bson(package_name)]).isNull();
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

	void setPackageRepository(string packname, Json repo)
	{
		m_packages.update(["name": packname], ["$set": ["repository": repo]]);
	}

	void addVersion(string packname, DbPackageVersion ver)
	{
		assert(ver.version_.startsWith("~") || ver.version_.isValidVersion());

		while (true) {
			auto versions = deserializeBson!(DbPackageVersion[])(m_packages.findOne(["name": packname], ["versions": true]).versions);
			auto new_versions = versions ~ ver;
			new_versions.sort!((a, b) => vcmp(a, b));

			auto res = m_packages.findAndModify(["name": Bson(packname), "versions": serializeToBson(versions)], ["$set": ["versions": new_versions]], ["_id": true]);
			if (!res.isNull) break;
		}

		updateKeywords(packname);
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
		updateKeywords(packname);
	}

	bool hasVersion(string packname, string ver)
	{
		auto packbson = Bson(packname);
		auto verbson = serializeToBson(["$elemMatch": ["version": ver]]);
		auto ret = m_packages.findOne(["name": packbson, "versions" : verbson], ["_id": true]);
		return !ret.isNull();
	}

	auto searchPackages(string[] keywords)
	{
		Appender!(string[]) barekeywords;
		foreach( kw; keywords ) {
			kw = kw.strip();
			//kw = kw.normalize(); // separate character from diacritics
			string[] parts = splitAlphaNumParts(kw.toLower());
			barekeywords ~= parts.filter!(p => p.count > 2).map!(p => p.toLower).array;
		}
		logInfo("search for %s %s", keywords, barekeywords.data);
		return m_packages.find(["searchTerms": ["$all": barekeywords.data]]).map!(b => deserializeBson!DbPackage(b))();
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

	auto getDownloadStats(BsonObjectID pack, string ver = null)
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
		match["package"] = Bson(pack);
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

	private void updateKeywords(string package_name)
	{
		auto p = getPackage(package_name);
		bool[string] keywords;
		void processString(string str) {
			if (str.length == 0) return;
			foreach (w; splitAlphaNumParts(str))
				if (w.count > 2)
					keywords[w.toLower()] = true;
		}
		void processVer(Json info) {
			if (auto pv = "description" in info) processString(pv.opt!string);
			if (auto pv = "authors" in info) processString(pv.opt!string);
			if (auto pv = "homepage" in info) processString(pv.opt!string);
		}

		processString(p.name);
		foreach (ver; p.versions) processVer(ver.info);

		Appender!(string[]) kwarray;
		foreach (kw; keywords.byKey) kwarray ~= kw;
		m_packages.update(["name": package_name], ["$set": ["searchTerms": kwarray.data]]);
	}

	private void repairVersionOrder()
	{
		foreach( bp; m_packages.find() ){
			logDebugV("pack %s", bp.toJson());
			auto p = deserializeBson!DbPackage(bp);
			p.versions = p.versions
				.filter!(v => v.version_.startsWith("~") || v.version_.isValidVersion)
				.array
				.sort!((a, b) => vcmp(a, b))
				.array;
			m_packages.update(["_id": p._id], ["$set": ["versions": p.versions]]);
		}
	}
}

struct DbPackage {
	BsonObjectID _id;
	BsonObjectID owner;
	string name;
	Json repository;
	DbPackageVersion[] versions;
	string[] errors;
	string[] categories;
	string[] searchTerms;
}

struct DbPackageVersion {
	BsonDate date;
	string version_;
	@optional string commitID;
	Json info;
	@optional string readme;
}

struct DbPackageDownload {
	BsonObjectID _id;
	BsonObjectID package_;
	string version_;
	SysTime time;
	string userAgent;
}

struct DbDownloadStats {
	uint total, monthly, weekly, daily;
}

bool vcmp(DbPackageVersion a, DbPackageVersion b)
{
	return vcmp(a.version_, b.version_);
}

bool vcmp(string va, string vb)
{
	import dub.dependency;
	return Version(va) < Version(vb);
}

private string[] splitAlphaNumParts(string str)
{
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
{
	return std.uni.isAlpha(ch) || std.uni.isNumber(ch);
}
