/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.bitbucket;

import dubregistry.cache;
import dubregistry.repositories.repository;
import std.array;
import std.string;
import vibe.vibe;


class BitbucketRepository : Repository {
	private {
		string m_owner;
		string m_project;
		CommitInfo[string] m_versions;
		CommitInfo[string] m_branches;
		string[] m_versionList;
		string[] m_branchList;
		bool m_gotVersions = false;
		bool m_gotBranches = false;
	}

	static void register()
	{
		Repository factory(Json info){
			return new BitbucketRepository(info.owner.get!string, info.project.get!string);
		}
		addRepositoryFactory("bitbucket", &factory);
	}

	this(string owner, string project)
	{
		m_owner = owner;
		m_project = project;
	}

	string[] getTags()
	{
		m_gotVersions = true;

		Json tags;
		try tags = readJson("https://api.bitbucket.org/1.0/repositories/"~m_owner~"/"~m_project~"/tags");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		m_versionList.length = 0;
		foreach( string tagname, tag; tags ){
			try {
				auto commit_hash = tag.raw_node.get!string();
				auto commit_date = bbToIsoDate(tag.utctimestamp.get!string());
				m_versions[tagname] = CommitInfo(commit_hash, commit_date);
				m_versionList ~= tagname;
				logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag.name.get!string~": "~e.msg);
			}
		}
		return m_versionList;
	}

	string[] getBranches()
	{
		Json branches = readJson("https://api.bitbucket.org/1.0/repositories/"~m_owner~"/"~m_project~"/branches");
		m_branchList.length = 0;
		foreach( string branchname, branch; branches ){
			auto commit_hash = branch.raw_node.get!string();
			auto commit_date = bbToIsoDate(branch.utctimestamp.get!string());
			m_branches[branchname] = CommitInfo(commit_hash, commit_date);
			m_branchList ~= "~"~branchname;
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return m_branchList;
	}

	PackageVersionInfo getVersionInfo(string ver)
	{
		PackageVersionInfo ret;
		string url;
		bool cache_priority = false;
		if (ver.startsWith("~")) {
			if (!m_gotBranches) getBranches();
			auto pc = ver[1 .. $] in m_branches;
			url = "https://bitbucket.org/api/1.0/repositories/"~m_owner~"/"~m_project~"/raw/"~ver[1 .. $]~"/package.json";
			if (pc) {
				ret.date = pc.date.toSysTime();
				ret.sha = pc.sha;
			}
		} else {
			if( !m_gotVersions ) getTags();
			auto pc = ver in m_versions;
			enforce(pc !is null, "Invalid version identifier.");
			url = "https://bitbucket.org/api/1.0/repositories/"~m_owner~"/"~m_project~"/raw/"~(pc.sha)~"/package.json";
			ret.date = pc.date.toSysTime();
			ret.sha = pc.sha;
			cache_priority = true;
		}

		ret.info = readJson(url, false, cache_priority);
		return ret;
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		return "https://bitbucket.org/"~m_owner~"/"~m_project~"/get/"~ver~".zip";
	}
}

private string bbToIsoDate(string bbdate)
{
	auto ttz = bbdate.split("+");
	if( ttz.length < 2 ) ttz ~= "00:00";
	auto parts = ttz[0].split("-");
	parts = parts[0 .. $-1] ~ parts[$-1].split(" ");
	parts = parts[0 .. $-1] ~ parts[$-1].split(":");

	return SysTime.fromISOString(format("%s%s%sT%s%s%s+%s", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], ttz[1])).toISOExtString();
}