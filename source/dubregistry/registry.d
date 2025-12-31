/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.registry;

import dubregistry.cache : FileNotFoundException;
import dubregistry.dbcontroller;
import dubregistry.internal.utils;
import dubregistry.internal.workqueue;
import dubregistry.repositories.repository;

import dub.semver;
import dub.package_ : packageInfoFilenames;
import std.algorithm : canFind, countUntil, filter, map, sort, swap, equal, startsWith, endsWith;
import std.array;
import std.conv;
import std.datetime : Clock, UTC, hours, SysTime;
import std.digest : toHexString;
import std.encoding : sanitize;
import std.exception : enforce;
import std.range : chain, walkLength;
import std.path : extension;
import std.string : format, toLower, representation;
import std.uni : sicmp;
import std.typecons;
import std.uni : asUpperCase;
import userman.db.controller;
import vibe.core.core;
import vibe.core.log;
import vibe.data.bson;
import vibe.data.json;
import vibe.stream.operations;

static import userman.api;


/// Settings to configure the package registry.
class DubRegistrySettings {
	string databaseName = "vpmreg";
	string[] administrators;
}

class DubRegistry {
@safe:

	private {
		DubRegistrySettings m_settings;
		DbController m_db;

		// list of package names to check for updates
		PackageWorkQueue m_updateQueue;
		// list of packages whose statistics need to be updated
		PackageWorkQueue m_updateStatsQueue;
		DbStatDistributions m_statDistributions;
	}

	this(DubRegistrySettings settings)
	{
		m_settings = settings;
		m_db = new DbController(settings.databaseName);

		// recompute scores on startup to pick up any algorithm changes
		m_statDistributions = m_db.getStatDistributions();
		recomputeScores(m_statDistributions);

		m_updateQueue = new PackageWorkQueue(&updatePackage);
		m_updateStatsQueue = new PackageWorkQueue((p) { updatePackageStats(p); });
	}

	@property DbController db() nothrow { return m_db; }

	@property auto availablePackages() { return m_db.getAllPackages(); }
	@property auto availablePackageIDs() { return m_db.getAllPackageIDs(); }

	auto getPackageDump()
	{
		return m_db.getPackageDump();
	}

	void triggerPackageUpdate(string pack_name)
	{
		m_updateQueue.putFront(pack_name);
	}

	bool isPackageScheduledForUpdate(string pack_name)
	{
		return m_updateQueue.isPending(pack_name);
	}

	/** Returns the current index of a given package in the update queue.

		An index of zero indicates that the package is currently being updated.
		A negative index is returned when the package is not in the update
		queue.
	*/
	sizediff_t getUpdateQueuePosition(string pack_name)
	{
		return m_updateQueue.getPosition(pack_name);
	}

	auto searchPackages(string query)
	{
		return m_db.searchPackages(query);
	}

	RepositoryInfo getRepositoryInfo(DbRepository repository)
	{
		auto rep = getRepository(repository);
		return rep.getInfo();
	}

	void addPackage(DbRepository repository, User.ID user)
	{
		auto pack_name = validateRepository(repository);

		DbPackage pack;
		pack.owner = user.bsonObjectIDValue;
		pack.name = pack_name;
		pack.repository = repository;
		m_db.addPackage(pack);

		triggerPackageUpdate(pack.name);
	}

	void addOrSetPackage(DbPackage pack)
	{
		m_db.addOrSetPackage(pack);
	}

	void addDownload(BsonObjectID pack_id, string ver, string agent)
	{
		m_db.addDownload(pack_id, ver, agent);
	}

	void removePackage(string packname, User.ID user)
	{
		logInfo("Package %s: removing package owned by %s", packname, user);
		m_db.removePackage(packname, user.bsonObjectIDValue);
	}

	auto getPackages(User.ID user)
	{
		return m_db.getUserPackages(user.bsonObjectIDValue);
	}

	auto getSharedPackages(User.ID user)
	{
		return m_db.getSharedPackages(user.bsonObjectIDValue);
	}

	bool isAdmin(userman.api.User user)
	{
		return m_settings.administrators.canFind(user.name);
	}

	bool isUserPackage(User.ID user, string package_name,
		DbPackage.Permissions permissions = DbPackage.Permissions.ownerOnly)
	{
		return m_db.isUserPackage(user.bsonObjectIDValue, package_name, permissions);
	}

	/// get stats (including downloads of all version) for a package
	DbPackageStats getPackageStats(string packname)
	{
		auto cached = m_db.getPackageStats(packname);
		if (cached.updatedAt > Clock.currTime(UTC()) - 24.hours)
			return cached;
		return updatePackageStats(packname);
	}

	private DbPackageStats updatePackageStats(string packname)
	{
		logDiagnostic("Updating stats for %s", packname);

		DbPackageStats stats;
		DbPackage pack = m_db.getPackage(packname);
		stats.downloads = m_db.aggregateDownloadStats(pack._id);

		try {
			stats.repo = getRepositoryInfo(pack.repository).stats;
		} catch (FileNotFoundException e) {
			// repo no longer exists, rate it down to zero (#221)
			logInfo("Zero scoring %s because the repo no longer exists.", packname);
			stats.score = 0;
		} catch (Exception e) {
			logWarn("Failed to get repository info for %s: %s", packname, e.msg);
			return typeof(return).init;
		}

		if (auto pStatDist = pack.repository.kind in m_statDistributions.repos)
			stats.score = computeScore(stats, m_statDistributions.downloads, *pStatDist);
		else
			logError("Missing stat distribution for %s repositories.", pack.repository.kind);

		m_db.updatePackageStats(pack._id, stats);
		return stats;
	}

	/// get downloads for a package version
	DbDownloadStats getDownloadStats(string packname, string ver)
	{
		auto packid = m_db.getPackageID(packname);
		if (ver == "latest") ver = getLatestVersion(packname);
		enforce!RecordNotFound(m_db.hasVersion(packname, ver), "Unknown version for package.");
		return m_db.aggregateDownloadStats(packid, ver);
	}

	Json getPackageVersionInfo(string packname, string ver, PackageInfoFlags flags)
	{
		if (ver == "latest") ver = getLatestVersion(packname);
		if (!m_db.hasVersion(packname, ver)) return Json(null);
		auto ret = m_db.getVersionInfo(packname, ver).serializeToJson();
		if (flags & PackageInfoFlags.minimize) ret.remove("readme");
		return ret;
	}

	string getLatestVersion(string packname)
	{
		return m_db.getLatestVersion(packname);
	}

	PackageInfo getPackageInfo(string packname, PackageInfoFlags flags = PackageInfoFlags.none)
	{
		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch (RecordNotFound) return PackageInfo.init;
		catch (Exception e) {
			logError("Unexpected Exception when calling db.getPackage: %s", (() @trusted => e.toString())());
			return PackageInfo.init;
		}

		return getPackageInfo(pack, flags);
	}

	/** Gets information about multiple packages at once.

		The order and count of packages returned may not correspond to the list
		of supplied package names. Only those packages that actually reference
		an existing package will yield a result element.

		The consequence is that the caller must manually match the result to
		the supplied package names.

		This function requires only a single query to the database.

		Returns:
			An unordered input range of `PackageInfo` values is returned,
			corresponding to all or part of the packages of the given names.
	*/
	auto getPackageInfos(scope string[] pack_names, PackageInfoFlags flags = PackageInfoFlags.none)
	{
		return m_db.getPackages(pack_names)
			.map!(pack => getPackageInfo(pack, flags));
	}

	auto getPackageInfo(DbPackage pack, PackageInfoFlags flags = PackageInfoFlags.none)
	{
		auto rep = getRepository(pack.repository);

		PackageInfo ret;
		ret.versions = pack.versions.map!(v => getPackageVersionInfo(v, rep, flags)).array;
		ret.logo = pack.logo;

		Json nfo = Json.emptyObject;
		nfo["versions"] = Json(ret.versions.map!(v => v.info).array);
		if (!(flags & PackageInfoFlags.minimize))
		{
			nfo["name"] = pack.name;
			nfo["id"] = pack._id.toString();
			nfo["dateAdded"] = pack._id.timeStamp.toISOExtString();
			nfo["owner"] = pack.owner.toString();
			nfo["repository"] = serializeToJson(pack.repository);
			nfo["categories"] = serializeToJson(pack.categories);
			nfo["documentationURL"] = pack.documentationURL;
		}
		if (flags & PackageInfoFlags.includeErrors)
			nfo["errors"] = serializeToJson(pack.errors);
		ret.privateInfo.sharedUsers = pack.sharedUsers;

		ret.info = nfo;

		return ret;
	}

	private PackageVersionInfo getPackageVersionInfo(DbPackageVersion v, Repository rep, PackageInfoFlags flags)
	{
		// JSON package version info as reported to the client
		Json[string] nfo;
		if (flags & PackageInfoFlags.minimize)
		{
			// only keep information relevant for dependency resolution
			static Json[string] keepDeps(in Json info)
			{
				Json[string] ret;
				ret["name"] = info["name"];
				ret["dependencies"] = info["dependencies"];
				auto cfgs = info["configurations"].opt!(Json[])
					.map!(cfg => Json(["name": cfg["name"], "dependencies": cfg["dependencies"]]));
				if (!cfgs.empty)
					ret["configurations"] = cfgs.array.Json;
				return ret;
			}
			nfo = keepDeps(v.info);
			auto subpkgs = v.info["subPackages"].opt!(Json[]).map!(subpkg => Json(keepDeps(subpkg)));
			if (!subpkgs.empty)
				nfo["subPackages"] = subpkgs.array.Json;
		}
		else
		{
			nfo = v.info.get!(Json[string]).dup;
			nfo["date"] = v.date.toISOExtString();
			nfo["readme"] = v.readme;
			nfo["commitID"] = v.commitID;
		}
		nfo["version"] = v.version_;

		PackageVersionInfo ret;
		ret.info = Json(nfo);
		ret.date = v.date;
		ret.sha = v.commitID;
		ret.version_ = v.version_;
		ret.downloadURL = rep.getDownloadUrl(v.version_.startsWith("~") ? v.version_ : "v"~v.version_);
		return ret;
	}

	PackageInfo[string] getPackageInfosRecursive(string[] packnames, PackageInfoFlags flags)
	{
		import dub.recipe.packagerecipe : getBasePackageName;

		PackageInfo[string] infos;
		void[0][string] visited;
		foreach (packname; packnames)
		{
			logDebug("getPackageInfosRecursive: %s", packname);
			getPackageInfosRecursive(packname, flags, infos, visited);
		}
		logDebug("getPackageInfosRecursive for %s returned %s", packnames, infos.byKey);
		return infos;
	}

	private void getPackageInfosRecursive(string packname, PackageInfoFlags flags, ref PackageInfo[string] infos, ref void[0][string] visited)
	{
		import dub.recipe.packagerecipe : getBasePackageName, getSubPackageName;
		import std.range : dropOne;
		import std.algorithm.searching : find;

		if (packname in visited)
			return;
		visited[packname] = typeof(visited[packname]).init;

		auto basepkg = getBasePackageName(packname);
		auto p = basepkg in infos;
		if (p is null)
			p = &(infos[basepkg] = getPackageInfo(basepkg, flags));

		if (!(flags & PackageInfoFlags.includeDependencies))
			return;

		void addDeps(Json info)
		{
			foreach (dep, _; info["dependencies"].opt!(Json[string]))
				getPackageInfosRecursive(dep, flags, infos, visited);
			foreach (cfg; info["configurations"].opt!(Json[]))
				foreach (dep, _; cfg["dependencies"].opt!(Json[string]))
					getPackageInfosRecursive(dep, flags, infos, visited);
		}

	Louter: foreach (v; p.versions)
		{
			import std.algorithm.iteration : splitter;
			auto info = v.info;
			foreach (subpkg; packname.splitter(":").dropOne)
			{
				auto sp = info["subPackages"].opt!(Json[]).find!(sp => sp["name"] == subpkg);
				if (sp.empty)
					continue Louter;
				info = sp.front;
			}
			addDeps(info);
		}
	}

	string getReadme(Json version_info, DbRepository repository)
	{
		auto readme = version_info["readme"].opt!string;

		// compat migration, read file from repo if README hasn't yet been stored in the db
		if (readme.length && readme.length < 256 && readme[0] == '/') {
			try {
				auto rep = getRepository(repository);
				logDebug("reading readme file for %s: %s", version_info["name"].get!string, readme);
				rep.readFile(version_info["commitID"].get!string, InetPath(readme), (scope data) {
					readme = data.readAllUTF8();
				});
			} catch (Exception e) {
				logDiagnostic("Failed to read README file (%s) for %s %s: %s",
					readme, version_info["name"].get!string,
					version_info["version"].get!string, e.msg);
			}
		}
		return readme;
	}

	void downloadPackageZip(string packname, string vers, void delegate(scope InputStream) @safe del)
	{
		DbPackage pack = m_db.getPackage(packname);
		auto rep = getRepository(pack.repository);
		rep.download(vers, del);
	}

	void setPackageCategories(string pack_name, string[] categories)
	{
		m_db.setPackageCategories(pack_name, categories);
	}

	void setPackageRepository(string pack_name, DbRepository repository)
	{
		auto new_name = validateRepository(repository);
		enforce(pack_name == new_name, "The package name of the new repository doesn't match the existing one: "~new_name);
		m_db.setPackageRepository(pack_name, repository);
	}

	void setPackageLogo(string pack_name, NativePath path)
	{
		auto png = generateLogo(path);
		if (png.length)
			m_db.setPackageLogo(pack_name, png);
		else
			throw new Exception("Failed to generate logo");
	}

	void unsetPackageLogo(string pack_name)
	{
		m_db.setPackageLogo(pack_name, null);
	}

	void setDocumentationURL(string pack_name, string documentationURL)
	{
		m_db.setDocumentationURL(pack_name, documentationURL);
	}

	bdata_t getPackageLogo(string pack_name, out bdata_t rev)
	{
		return m_db.getPackageLogo(pack_name, rev);
	}

	void upsertSharedUser(string pack_name, User.ID id, DbPackage.Permissions permissions)
	{
		m_db.upsertSharedUser(pack_name, id.bsonObjectIDValue, permissions);
	}

	void removeSharedUser(string pack_name, User.ID id)
	{
		m_db.removeSharedUser(pack_name, id.bsonObjectIDValue);
	}

	void updatePackages()
	{
		import std.random : randomShuffle;

		logDiagnostic("Triggering package update...");
		// update stat distributions before score packages
		m_statDistributions = m_db.getStatDistributions();

		// shuffle the package list to ensure a uniform probability of each
		// package getting chosen over time, regardless of how long it takes
		// to process the whole list and whether the process gets restarted
		// in-between
		auto allpacks = this.availablePackages.array;
		randomShuffle(allpacks);
		foreach (packname; allpacks)
			if (!m_updateQueue.isPending(packname))
				triggerPackageUpdate(packname);
	}

	protected string validateRepository(DbRepository repository)
	{
		// find the packge info of ~master or any available branch
		PackageVersionInfo info;
		auto rep = getRepository(repository);
		auto branches = rep.getBranches();
		enforce(branches.length > 0, "The repository contains no branches.");
		auto idx = branches.countUntil!(b => b.name == "master");
		if (idx > 0) swap(branches[0], branches[idx]);
		string branch_errors;
		foreach (b; branches) {
			try {
				info = rep.getVersionInfo(b, null);
				enforce (info.info.type == Json.Type.object,
					"JSON package description must be a JSON object.");
				break;
			} catch (Exception e) {
				logDiagnostic("Error getting package info for %s", b);
				branch_errors ~= format("\n%s: %s", b.name, e.msg);
			}
		}
		enforce (info.info.type == Json.Type.object,
			"Failed to find a branch containing a valid package description file:" ~ branch_errors);

		// derive package name and perform various sanity checks
		auto name = info.info["name"].get!string;
		string package_desc_file = info.info["packageDescriptionFile"].get!string;
		string package_check_string = format(`Check your %s.`, package_desc_file);
		enforce(name.length <= 60,
			"Package names must not be longer than 60 characters: \""~name[0 .. 60]~"...\" - "~package_check_string);
		enforce(name == name.toLower(),
			"Package names must be all lower case, not \""~name~"\". "~package_check_string);
		enforce(info.info["license"].opt!string.length > 0,
			`A "license" field in the package description file is missing or empty. `~package_check_string);
		enforce(info.info["description"].opt!string.length > 0,
			`A "description" field in the package description file is missing or empty. `~package_check_string);
		checkPackageName(name, format(`Check the "name" field of your %s.`, package_desc_file));
		foreach (string n, vspec; info.info["dependencies"].opt!(Json[string])) {
			auto parts = n.split(":").array;
			// allow shortcut syntax ":subpack"
			if (parts.length > 1 && parts[0].length == 0) parts = parts[1 .. $];
			// verify all other parts of the package name
			foreach (p; parts)
				checkPackageName(p, format(`Check the "dependencies" field of your %s.`, package_desc_file));
		}

		// ensure that at least one tagged version is present
		auto tags = rep.getTags();
		enforce(tags.canFind!(t => t.name.startsWith("v") && t.name[1 .. $].isValidVersion),
			`The repository must have at least one tagged version (SemVer format with a "v" prefix, e.g. `
			~ `"v1.0.0" or "v0.0.1") to be published on the registry. Please add a proper tag using `
			~ `"git tag" or equivalent means and see http://semver.org for more information.`);

		return name;
	}

	protected bool addVersion(const ref DbPackage dbpack, string ver, Repository rep, RefInfo reference)
	{
		logDiagnostic("Adding new version info %s for %s", ver, dbpack.name);
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		string deffile;
		foreach (t; dbpack.versions)
			if (t.version_ == ver) {
				deffile = t.info["packageDescriptionFile"].opt!string;
				break;
			}
		auto info = getVersionInfo(rep, reference, deffile);

		//assert(info.info.name == info.info.name.get!string.toLower(), "Package names must be all lower case.");
		info.info["name"] = info.info["name"].get!string.toLower();
		enforce(info.info["name"] == dbpack.name,
			format("Package name (%s) does not match the original package name (%s). Check %s.",
				info.info["name"].get!string, dbpack.name, info.info["packageDescriptionFile"].get!string));

		foreach( string n, vspec; info.info["dependencies"].opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p, "Check "~info.info["packageDescriptionFile"].get!string~".");

		DbPackageVersion dbver;
		dbver.date = info.date;
		dbver.version_ = ver;
		dbver.commitID = info.sha;
		dbver.info = info.info;

		try {
			auto files = rep.listFiles(reference.sha, InetPath("/"));
			// check exactly for readme.me
			ptrdiff_t readme;
			readme = files.countUntil!(a => a.type == RepositoryFile.Type.file && a.path.head.name.asUpperCase.equal("README.MD"));
			if (readme == -1) {
				// check exactly for readme
				readme = files.countUntil!(a => a.type == RepositoryFile.Type.file && a.path.head.name.asUpperCase.equal("README"));
			}
			if (readme == -1) {
				// check for all other readmes such as README.txt, README.jp.md, etc.
				readme = files.countUntil!(a => a.type == RepositoryFile.Type.file && a.path.head.name.asUpperCase.startsWith("README"));
			}

			if (readme != -1) {
				rep.readFile(reference.sha, files[readme].path, (scope input) {
					dbver.readme = input.readAllUTF8();
					auto ext = files[readme].path.head.extension;
					// endsWith doesn't like to work with asLowerCase
					dbver.readmeMarkdown = ext.sicmp(".md") == 0;
				});
			} else logDiagnostic("No README.md found for %s %s", dbpack.name, ver);

			// TODO: load in example(s), sample(s), test(s) and docs for the view package page here.
			// possibly also parsing the README.md file for a documentation link
		} catch (Exception e) { logDiagnostic("Failed to read README.md for %s %s: %s", dbpack.name, ver, e.msg); }

		if (m_db.hasVersion(dbpack.name, ver)) {
			logDebug("Updating existing version info.");
			m_db.updateVersion(dbpack.name, dbver);
			return false;
		}

		if ("description" !in info.info || "license" !in info.info) {
			throw new Exception(
			"Published packages must contain \"description\" and \"license\" fields.");
		}
		//enforce(!m_db.hasVersion(packname, dbver.version_), "Version already exists.");
		if (auto pv = "version" in info.info)
			enforce(pv.get!string == ver, format("Package description contains an obsolete \"version\" field and does not match tag %s: %s", ver, pv.get!string));
		logDebug("Adding new version info.");
		m_db.addVersion(dbpack.name, dbver);
		return true;
	}

	protected void removeVersion(string packname, string ver)
	{
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		m_db.removeVersion(packname, ver);
	}

	private void updatePackage(string packname)
	{
		import std.encoding;
		string[] errors;

		scope (exit) m_db.setPackageErrors(packname, errors);

		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch (Exception e) {
			errors ~= format("Error getting package info: %s", e.msg);
			logException!(LogLevel.diagnostic)(e, "Failed to get package info for " ~ packname);
			return;
		}

		Repository rep;
		try rep = getRepository(pack.repository);
		catch (Exception e) {
			errors ~= format("Error accessing repository: %s", e.msg);
			logException!(LogLevel.diagnostic)(e, "Failed to get package info for " ~ packname);
			return;
		}

		bool[string] existing;
		RefInfo[] tags, branches;
		bool got_all_tags_and_branches = false;
		try {
			tags = rep.getTags()
				.filter!(a => a.name.startsWith("v") && a.name[1 .. $].isValidVersion)
				.array
				.sort!((a, b) => compareVersions(a.name[1 .. $], b.name[1 .. $]) < 0)
				.array;
			branches = rep.getBranches();
			got_all_tags_and_branches = true;
		} catch (Exception e) {
			errors ~= format("Failed to get GIT tags/branches: %s", e.msg);
		}
		logDiagnostic("Updating tags for %s: %s", packname, tags.map!(t => t.name).array);
		foreach (tag; tags) {
			auto name = tag.name[1 .. $];
			existing[name] = true;
			try {
				if (addVersion(pack, name, rep, tag))
					logInfo("Package %s: added version %s", packname, name);
			} catch( Exception e ){
				logDiagnostic("Error for version %s of %s: %s", name, packname, e.msg);
				() @trusted  { logDebug("Full error: %s", sanitize(e.toString())); } ();
				errors ~= format("Version %s: %s", name, e.msg);
			}
		}
		logDiagnostic("Updating branches for %s: %s", packname, branches.map!(t => t.name).array);
		foreach (branch; branches) {
			auto name = "~" ~ branch.name;
			existing[name] = true;
			try {
				if (addVersion(pack, name, rep, branch))
					logInfo("Package %s: added branch %s", packname, name);
			} catch( Exception e ){
				logDiagnostic("Error for branch %s of %s: %s", name, packname, e.msg);
				() @trusted { logDebug("Full error: %s", sanitize(e.toString())); } ();
				if (branch.name != "gh-pages") // ignore errors on the special GitHub website branch
					errors ~= format("Branch %s: %s", name, e.msg);
			}
		}
		if (got_all_tags_and_branches) {
			foreach (ref v; pack.versions) {
				auto ver = v.version_;
				if (ver !in existing) {
					logInfo("Package %s: removing version %s as the branch/tag was removed.", packname, ver);
					removeVersion(packname, ver);
				}
			}
		}

		m_updateStatsQueue.put(packname);
	}

	/// recompute all scores based on cached stats, e.g. after updating algorithm
	private void recomputeScores(DbStatDistributions dists)
	{
		foreach (pack; this.getPackageDump()) {
			auto stats = pack.stats;
			stats.score = computeScore(stats, dists.downloads, dists.repos[pack.repository.kind]);
			if (stats.score != pack.stats.score)
				m_db.updatePackageStats(pack._id, stats);
		}
	}
}

private PackageVersionInfo getVersionInfo(Repository rep, RefInfo commit, string first_filename_try, InetPath sub_path = InetPath("/"))
@safe {
	import dub.recipe.io;
	import dub.recipe.json;

	PackageVersionInfo ret;
	ret.date = commit.date.toSysTime();
	ret.sha = commit.sha;
	string[1] first_try;
	first_try[0] = first_filename_try;
	auto all_filenames = () @trusted { return packageInfoFilenames(); } ();
	foreach (filename; chain(first_try[], all_filenames.filter!(f => f != first_filename_try))) {
		if (!filename.length) continue;
		try {
			rep.readFile(commit.sha, sub_path ~ filename, (scope input) @safe {
				auto text = input.readAllUTF8(false);
				auto recipe = () @trusted { return parsePackageRecipe(text, filename); } ();
				ret.info = () @trusted { return recipe.toJson(); } ();
			});

			ret.info["packageDescriptionFile"] = filename;
			logDebug("Found package description file %s.", filename);

			foreach (ref sp; ret.info["subPackages"].opt!(Json[])) {
				if (sp.type == Json.Type.string) {
					auto path = sp.get!string;
					logDebug("Fetching path based sub package at %s", sub_path ~ path);
					auto subpack = getVersionInfo(rep, commit, first_filename_try, sub_path ~ path);
					sp = subpack.info;
					sp["path"] = path;
				}
			}

			break;
		} catch (FileNotFoundException) {
			logDebug("Package description file %s not found...", filename);
		}
	}
	if (ret.info.type == Json.Type.undefined)
		 throw new Exception("Found no package description file in the repository.");
	return ret;
}

private void checkPackageName(string n, string error_suffix)
@safe {
	enforce(n.length > 0, "Package names may not be empty. "~error_suffix);
	foreach( ch; n ){
		switch(ch){
			default:
				throw new Exception("Package names may only contain ASCII letters and numbers, as well as '_' and '-': "~n~" - "~error_suffix);
			case 'a': .. case 'z':
			case 'A': .. case 'Z':
			case '0': .. case '9':
			case '_', '-':
				break;
		}
	}
}

struct PackageVersionInfo {
	string version_;
	SysTime date;
	string sha;
	string downloadURL;
	Json info; /// JSON version information, as reported to the client
}

struct PackageInfo {
	struct Private {
		DbPackage.SharedUser[] sharedUsers;
	}

	PackageVersionInfo[] versions;
	BsonObjectID logo;
	Json info; /// JSON package information, as reported to the client
	Private privateInfo; /// Extra info that's not reported to the client, such as detailed ownership info

	bool hasPermissions(BsonObjectID user, DbPackage.Permissions permissions)
	const @safe {
		assert(user != BsonObjectID.init);
		assert("owner" in info, "can't check permissions with minimized PackageInfo");

		const dummy = const(DbPackage)(
			BsonObjectID.init,
			BsonObjectID.fromString(info["owner"].get!string),
			privateInfo.sharedUsers
		);
		return dummy.hasPermissions(user, permissions);
	}
}

/// flags to customize getPackageInfo* methods
enum PackageInfoFlags
{
	none,
	includeDependencies = 1 << 0, /// include package info of dependencies
	includeErrors = 1 << 1, /// include package errors
	minimize = 1 << 2, /// return only minimal information (for dependency resolver)
}

/// Computes a package score from given package stats and global distributions of those stats.
private float computeScore(DownDist, RepoDist)(const ref DbPackageStats stats, DownDist downDist, RepoDist repoDist)
@safe {
	import std.algorithm.comparison : max;
	import std.math : log1p, round, tanh;

    if (!downDist.total.sum) // no stat distribution yet
        return 0;

	/// Using monthly downloads to penalize stale packages, logarithm to
	/// offset exponential distribution, and tanh as smooth limiter to [0..1].
	immutable downloadScore = tanh(log1p(stats.downloads.monthly / (downDist.monthly.mean + double.min_normal)));
	logDebug("downloadScore %s %s %s", downloadScore, stats.downloads.monthly, downDist.monthly.mean);

	// Compute score for repo
	float sum=0, wsum=0;
	void add(T)(float weight, float value, T dist)
	{
		if (dist.sum == 0)
			return; // ignore metrics missing for that repository kind
		sum += weight * log1p(value / dist.mean);
		wsum += weight;
	}
	with (stats.repo)
	{
		alias d = repoDist;
		// all of those values are highly correlated
		add(1.0f, stars, d.stars);
		add(1.0f, watchers, d.watchers);
		add(1.0f, forks, d.forks);
		add(-1.0f, issues, d.issues); // penalize many open issues/PRs
	}

	immutable repoScore = max(0.0, tanh(sum / wsum));
	logDebug("repoScore: %s %s %s", repoScore, sum, wsum);

	// average scores
	immutable avgScore = (repoScore + downloadScore) / 2;
	assert(0 <= avgScore && avgScore <= 1.0, "%s %s".format(repoScore, downloadScore));
	immutable scaled = stats.minScore + avgScore * (stats.maxScore - stats.minScore);
	logDebug("score: %s %s %s %s %s %s", stats.downloads.monthly, downDist.monthly.mean, downloadScore, repoScore, avgScore, scaled);

	return scaled;
}
