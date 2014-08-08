/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.registry;

import dubregistry.cache : FileNotFoundException;
import dubregistry.dbcontroller;
import dubregistry.repositories.repository;

import dub.semver;
import dub.package_ : packageInfoFilenames;
import std.algorithm : chain, countUntil, filter, map, sort, swap;
import std.array;
import std.datetime : Clock, UTC, hours, SysTime;
import std.encoding : sanitize;
import std.string : format, startsWith, toLower;
import std.typecons;
import vibe.data.bson;
import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.stream.operations;


/// Settings to configure the package registry.
class DubRegistrySettings {
	string databaseName = "vpmreg";
}

class DubRegistry {
	private {
		DubRegistrySettings m_settings;
		DbController m_db;
		Json[string] m_packageInfos;

		// list of package names to check for updates
		string[] m_updateQueue; // TODO: use a ring buffer
		string m_currentUpdatePackage;
		Task m_updateQueueTask;
		TaskMutex m_updateQueueMutex;
		TaskCondition m_updateQueueCondition;
		SysTime m_lastSignOfLifeOfUpdateTask;
	}

	this(DubRegistrySettings settings)
	{
		m_settings = settings;
		m_db = new DbController(settings.databaseName);
		m_updateQueueMutex = new TaskMutex;
		m_updateQueueCondition = new TaskCondition(m_updateQueueMutex);
		m_updateQueueTask = runTask(&processUpdateQueue);
	}

	@property auto availablePackages()
	{
		return m_db.getAllPackages();
	}

	void triggerPackageUpdate(string pack_name)
	{
		synchronized (m_updateQueueMutex) {
			if (!m_updateQueue.canFind(pack_name))
				m_updateQueue ~= pack_name;
		}

		// watchdog for update task
		if (Clock.currTime(UTC()) - m_lastSignOfLifeOfUpdateTask > 2.hours) {
			logError("Update task has hung. Trying to interrupt.");
			m_updateQueueTask.interrupt();
		}

		if (!m_updateQueueTask.running)
			m_updateQueueTask = runTask(&processUpdateQueue);
		m_updateQueueCondition.notifyAll();
	}

	bool isPackageScheduledForUpdate(string pack_name)
	{
		if (m_currentUpdatePackage == pack_name) return true;
		synchronized (m_updateQueueMutex)
			if (m_updateQueue.canFind(pack_name)) return true;
		return false;
	}

	auto searchPackages(string[] keywords)
	{
		return m_db.searchPackages(keywords).map!(p => getPackageInfo(p.name));
	}

	void addPackage(Json repository, BsonObjectID user)
	{
		auto pack_name = validateRepository(repository);

		DbPackage pack;
		pack.owner = user;
		pack.name = pack_name;
		pack.repository = repository;
		m_db.addPackage(pack);

		triggerPackageUpdate(pack.name);
	}

	void addDownload(BsonObjectID pack_id, string ver, string agent)
	{
		m_db.addDownload(pack_id, ver, agent);
	}

	void removePackage(string packname, BsonObjectID user)
	{
		logInfo("Removing package %s of %s", packname, user);
		m_db.removePackage(packname, user);
		if (packname in m_packageInfos) m_packageInfos.remove(packname);
	}

	auto getPackages(BsonObjectID user)
	{
		return m_db.getUserPackages(user);
	}

	bool isUserPackage(BsonObjectID user, string package_name)
	{
		return m_db.isUserPackage(user, package_name);
	}

	Json getPackageInfo(string packname, bool include_errors = false)
	{
		if (!include_errors) {
			if (auto ppi = packname in m_packageInfos)
				return *ppi;
		}

		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch(Exception) return Json(null);

		auto rep = getRepository(pack.repository);

		Json[] vers;
		foreach (v; pack.versions) {
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl(v.version_.startsWith("~") ? v.version_ : "v"~v.version_); // obsolete, will be removed in april 2013
			nfo.downloadUrl = nfo.url; // obsolete, will be removed in april 2013
			nfo.readme = v.readme;
			vers ~= nfo;
		}

		Json ret = Json.emptyObject;
		ret.id = pack._id.toString();
		ret.dateAdded = pack._id.timeStamp.toISOExtString();
		ret.owner = pack.owner.toString();
		ret.name = packname;
		ret.versions = Json(vers);
		ret.repository = pack.repository;
		ret.categories = serializeToJson(pack.categories);
		if( include_errors ) ret.errors = serializeToJson(pack.errors);
		else m_packageInfos[packname] = ret;
		return ret;
	}

	void setPackageCategories(string pack_name, string[] categories)
	{
		m_db.setPackageCategories(pack_name, categories);
		if (pack_name in m_packageInfos) m_packageInfos.remove(pack_name);
	}

	void setPackageRepository(string pack_name, Json repository)
	{
		auto new_name = validateRepository(repository);
		enforce(pack_name == new_name, "The package name of the new repository doesn't match the existing one: "~new_name);
		m_db.setPackageRepository(pack_name, repository);
		if (pack_name in m_packageInfos) m_packageInfos.remove(pack_name);
	}

	void checkForNewVersions()
	{
		logInfo("Triggering check for new versions...");
		foreach (packname; this.availablePackages)
			triggerPackageUpdate(packname);
	}

	protected string validateRepository(Json repository)
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
		auto name = info.info.name.get!string;
		string package_check_string = "Check "~info.info.packageDescriptionFile.get!string~".";
		enforce(name.length <= 60,
			"Package names must not be longer than 60 characters: \""~name[0 .. 60]~"...\" - "~package_check_string);
		enforce(name == name.toLower(),
			"Package names must be all lower case, not \""~name~"\". "~package_check_string);
		enforce(info.info.license.opt!string.length > 0,
			`A "license" field in the package description file is missing or empty. `~package_check_string);
		enforce(info.info.description.opt!string.length > 0,
			`A "description" field in the package description file is missing or empty. `~package_check_string);
		checkPackageName(name, package_check_string);
		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p, package_check_string);

		// ensure that at least one tagged version is present
		auto tags = rep.getTags();
		enforce(tags.canFind!(t => t.name.startsWith("v") && t.name[1 .. $].isValidVersion),
			`The repository must have at least one tagged version (SemVer format, e.g. `
			~ `"v1.0.0" or "v0.0.1") to be published on the registry. Please add a proper tag using `
			~ `"git tag" or equivalent means and see http://semver.org for more information.`);

		return name;
	}

	protected bool addVersion(string packname, string ver, Repository rep, RefInfo reference)
	{
		logDiagnostic("Adding new version info %s for %s", ver, packname);
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		auto dbpack = m_db.getPackage(packname);
		string deffile;
		foreach (t; dbpack.versions)
			if (t.version_ == ver) {
				deffile = t.info.packageDescriptionFile.opt!string;
				break;
			}
		auto info = getVersionInfo(rep, reference, deffile);

		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		//assert(info.info.name == info.info.name.get!string.toLower(), "Package names must be all lower case.");
		info.info.name = info.info.name.get!string.toLower();
		enforce(info.info.name == packname, "Package name must match the original package name.");

		if ("description" !in info.info || "license" !in info.info) {
		//enforce("description" in info.info && "license" in info.info,
			throw new Exception(
			"Published packages must contain \"description\" and \"license\" fields.");
		}

		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p, "Check "~info.info.packageDescriptionFile.get!string~".");

		DbPackageVersion dbver;
		dbver.date = BsonDate(info.date);
		dbver.version_ = ver;
		dbver.commitID = info.sha;
		dbver.info = info.info;

		try rep.readFile(reference.sha, Path("/README.md"), (scope input) { dbver.readme = input.readAllUTF8(); });
		catch (Exception e) { logDiagnostic("No README.md found for %s %s", packname, ver); }

		if (m_db.hasVersion(packname, ver)) {
			m_db.updateVersion(packname, dbver);
			return false;
		}

		//enforce(!m_db.hasVersion(packname, dbver.version_), "Version already exists.");
		if (auto pv = "version" in info.info)
			enforce(pv.get!string == ver, format("Package description contains obsolete \"version\" field and does not match tag %s: %s", ver, pv.get!string));
		m_db.addVersion(packname, dbver);
		return true;
	}

	protected void removeVersion(string packname, string ver)
	{
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		m_db.removeVersion(packname, ver);
	}

	private void processUpdateQueue()
	{
		scope (exit) logWarn("Update task was killed!");
		while (true) {
			m_lastSignOfLifeOfUpdateTask = Clock.currTime(UTC());
			logDiagnostic("Getting new package to be updated...");
			string pack;
			synchronized (m_updateQueueMutex) {
				while (m_updateQueue.empty) {
					logDiagnostic("Waiting for package to be updated...");
					m_updateQueueCondition.wait();
				}
				pack = m_updateQueue.front;
				m_updateQueue.popFront();
				m_currentUpdatePackage = pack;
			}
			scope(exit) m_currentUpdatePackage = null;
			logDiagnostic("Updating package %s.", pack);
			try checkForNewVersions(pack);
			catch (Exception e) {
				logWarn("Failed to check versions for %s: %s", pack, e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}
	}

	private void checkForNewVersions(string packname)
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
		foreach (tag; tags) {
			auto name = tag.name[1 .. $];
			existing[name] = true;
			try {
				if (addVersion(packname, name, rep, tag))
					logInfo("Added version %s for %s", name, packname);
			} catch( Exception e ){
				logDebug("version %s", sanitize(e.toString()));
				errors ~= format("Version %s: %s", name, e.msg);
			}
		}
		foreach (branch; branches) {
			auto name = "~" ~ branch.name;
			existing[name] = true;
			try {
				if (addVersion(packname, name, rep, branch))
					logInfo("Added branch %s for %s", name, packname);
			} catch( Exception e ){
				logDebug("%s", sanitize(e.toString()));
				errors ~= format("Branch %s: %s", name, e.msg);
			}
		}
		if (got_all_tags_and_branches) {
			foreach (v; pack.versions) {
				auto ver = v["version"].get!string;
				if (ver !in existing) {
					logInfo("Removing version %s as the branch/tag was removed.", ver);
					removeVersion(packname, ver);
				}
			}
		}
		m_db.setPackageErrors(packname, errors);
	}
}

private PackageVersionInfo getVersionInfo(Repository rep, RefInfo commit, string first_filename_try)
{
	PackageVersionInfo ret;
	ret.date = commit.date.toSysTime();
	ret.sha = commit.sha;
	foreach (filename; chain((&first_filename_try)[0 .. 1], packageInfoFilenames.filter!(f => f != first_filename_try))) {
		if (!filename.length) continue;
		try {
			ret.info = rep.readCachedJsonFile(commit.sha, Path("/" ~ filename));
			ret.info.packageDescriptionFile = filename;
		} catch (FileNotFoundException) { /* try another filename */ }
	}
	if (ret.info == Json.undefined)
		 throw new Exception("Found no package information file in the repository.");
	return ret;
}

private Json readCachedJsonFile(Repository rep, string commit_sha, Path path)
{
	Json ret;
	rep.readFile(commit_sha, path, (scope input) {
		auto text = input.readAllUTF8(false);
		ret = parseJsonString(text);
	});
	return ret;
}

private void checkPackageName(string n, string error_suffix)
{
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

private struct PackageVersionInfo {
	SysTime date;
	string sha;
	Json info;
}
