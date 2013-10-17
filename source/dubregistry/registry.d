/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.registry;

import dubregistry.dbcontroller;
import dubregistry.repositories.repository;

import std.algorithm : map, sort;
import std.array;
import vibe.vibe;


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
		auto rep = getRepository(repository);
		auto info = rep.getVersionInfo("~master");
		auto name = info.info.name.get!string;

		checkPackageName(name);
		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p);

		info.info.name = name.toLower();

		DbPackage pack;
		pack.owner = user;
		pack.name = info.info.name.get!string.toLower();
		pack.repository = repository;
		m_db.addPackage(pack);

		triggerPackageUpdate(pack.name);
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
		foreach( v; pack.branches ){
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl(v.version_); // obsolete, will be removed in april 2013
			nfo.downloadUrl = nfo.url; // obsolete, will be removed in april 2013
			vers ~= nfo;
		}
		foreach( v; pack.versions ){
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo.date = v.date.toSysTime().toISOExtString();
			nfo.url = rep.getDownloadUrl(v.version_); // obsolete, will be removed in april 2013
			nfo.downloadUrl = nfo.url; // obsolete, will be removed in april 2013
			vers ~= nfo;
		}

		Json ret = Json.emptyObject;
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
	}

	void checkForNewVersions()
	{
		logInfo("Triggering check for new versions...");
		foreach (packname; this.availablePackages)
			triggerPackageUpdate(packname);
	}

	protected bool addVersion(string packname, string ver, PackageVersionInfo info)
	{
		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		info.info.name = toLower(info.info.name.get!string());
		enforce(info.info.name == packname, "Package name must match the original package name.");

		enforce("description" in info.info && "license" in info.info,
			"Published packages must contain \"description\" and \"license\" fields.");

		foreach( string n, vspec; info.info.dependencies.opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p);

		DbPackageVersion dbver;
		dbver.date = BsonDate(info.date);
		dbver.version_ = ver;
		dbver.info = info.info;

		if( !ver.startsWith("~") ){
			if (m_db.hasVersion(packname, ver)) {
				m_db.updateVersion(packname, dbver);
				return false;
			}
			enforce(!m_db.hasVersion(packname, info.version_), "Version already exists.");
			enforce(info.version_ == ver, "Version in package.json differs from git tag version.");
			m_db.addVersion(packname, dbver);
		} else {
			if (m_db.hasBranch(packname, ver)) {
				m_db.updateBranch(packname, dbver);
				return false;
			}
			m_db.addBranch(packname, dbver);
		}
		return true;
	}

	private void processUpdateQueue()
	{
		while (true) {
			string pack;
			synchronized (m_updateQueueMutex) {
				while (m_updateQueue.empty)
					m_updateQueueCondition.wait();
				pack = m_updateQueue.front;
				m_updateQueue.popFront();
			}
			checkForNewVersions(pack);
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

		try {
			foreach( ver; rep.getVersions().sort!((a, b) => vcmp(a, b))() ){
				try {
					if (addVersion(packname, ver, rep.getVersionInfo(ver)))
						logInfo("Added version %s for %s", ver, packname);
				} catch( Exception e ){
					logDebug("version %s", sanitize(e.toString()));
					errors ~= format("Version %s: %s", ver, e.msg);
					// TODO: store error message for web frontend!
				}
			}
			foreach( ver; rep.getBranches() ){
				try {
					if (addVersion(packname, ver, rep.getVersionInfo(ver)))
						logInfo("Added branch %s for %s", ver, packname);
				} catch( Exception e ){
					logDebug("%s", sanitize(e.toString()));
					// TODO: store error message for web frontend!
					errors ~= format("Branch %s: %s", ver, e.msg);
				}
			}
		} catch( Exception e ){
			logDebug("%s", sanitize(e.toString()));
			// TODO: store error message for web frontend!
			errors ~= e.msg;
		}
		m_db.setPackageErrors(packname, errors);
	}
}

private void checkPackageName(string n){
	enforce(n.length > 0, "Package names may not be empty.");
	foreach( ch; n ){
		switch(ch){
			default:
				throw new Exception("Package names may only contain ASCII letters and numbers, as well as '_' and '-': "~n);
			case 'a': .. case 'z':
			case 'A': .. case 'Z':
			case '0': .. case '9':
			case '_', '-':
				break;
		}
	}
}

