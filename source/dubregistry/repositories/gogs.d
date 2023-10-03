/**
	Copyright: © 2013-2016 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.gogs;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
import std.string : startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;


class GogsRepository : Repository {
	private {
		string m_url;
		string m_owner;
		string m_project;
		string m_authToken;
	}

	static void register(string auth_token, string url)
	{
		Repository factory(DbRepository info){
			return new GogsRepository(url, info.owner, info.project, auth_token);
		}
		addRepositoryFactory("gogs", &factory);
	}

	this(string url, string owner, string project, string auth_token)
	{
		import std.algorithm.searching : endsWith;
		m_url = url;
		if (!m_url.endsWith('/')) m_url ~= '/';
		m_owner = owner;
		m_project = project;
		m_authToken = auth_token;
	}

	RefInfo[] getTags()
	{
		import std.datetime : SysTime;

		Json tags;
		try tags = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/tags?per_page=100&token="~m_authToken);
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag["name"].get!string;
				Json commit = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/commits/"~tag["commit"]["id"].get!string~"?token="~m_authToken, true, true);
				ret ~= RefInfo(tagname, tag["commit"]["id"].get!string, SysTime.fromISOExtString(commit["commit"]["committer"]["date"].get!string));
				logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag["name"].get!string~": "~e.msg);
			}
		}
		return ret;
	}

	RefInfo[] getBranches()
	{
		import std.datetime : SysTime;

		Json branches = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/branches?token="~m_authToken);
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch["name"].get!string;
			Json commit = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/commits/"~branch["commit"]["id"].get!string~"?token="~m_authToken, true, true);
			ret ~= RefInfo(branchname, branch["commit"]["id"].get!string, SysTime.fromISOExtString(commit["commit"]["committer"]["date"].get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		auto nfo = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"?token="~m_authToken);
		RepositoryInfo ret;
		ret.isFork = nfo["fork"].opt!bool;
		return ret;
	}

	void readFile(string commit_sha, Path path, scope void delegate(scope InputStream) reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto url = getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/"~commit_sha~path.toString()~"?token="~m_authToken;
		downloadCached(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		return m_url~"/repos/"~m_owner~"/"~m_project~"/archive/"~ver~".zip";
	}

	void download(string ver, scope void delegate(scope InputStream) del)
	{
		downloadCached(getDownloadUrl(ver), del);
	}

	private string getAPIURLPrefix() {
		return m_url~"api/v1";
	}
}
