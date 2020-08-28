/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.github;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
import std.string : startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;


class GithubRepository : Repository {
@safe:

	private {
		string m_owner;
		string m_project;
		string m_authUser;
		string m_authPassword;
	}

	static void register(string user, string password)
	{
		Repository factory(DbRepository info) @safe {
			return new GithubRepository(info.owner, info.project, user, password);
		}
		addRepositoryFactory("github", &factory);
	}

	this(string owner, string project, string auth_user, string auth_password)
	{
		m_owner = owner;
		m_project = project;
		m_authUser = auth_user;
		m_authPassword = auth_password;
	}

	RefInfo[] getTags()
	{
		import std.datetime : SysTime;

		Json tags;
		try tags = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/tags?per_page=1000");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag["name"].get!string;
				Json commit = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/commits/"~tag["commit"]["sha"].get!string, true, true);
				ret ~= RefInfo(tagname, tag["commit"]["sha"].get!string, SysTime.fromISOExtString(commit["commit"]["committer"]["date"].get!string));
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

		Json branches = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/branches");
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch["name"].get!string;
			Json commit = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/commits/"~branch["commit"]["sha"].get!string, true, true);
			ret ~= RefInfo(branchname, branch["commit"]["sha"].get!string, SysTime.fromISOExtString(commit["commit"]["committer"]["date"].get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		auto nfo = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project);
		RepositoryInfo ret;
		ret.isFork = nfo["fork"].opt!bool;
		ret.stats.stars = nfo["stargazers_count"].opt!uint;
		ret.stats.watchers = nfo["subscribers_count"].opt!uint;
		ret.stats.forks = nfo["forks_count"].opt!uint;
		ret.stats.issues = nfo["open_issues_count"].opt!uint; // conflates PRs and Issues
		return ret;
	}

	RepositoryFile[] listFiles(string commit_sha, InetPath path)
	{
		assert(path.absolute, "Passed relative path to listFiles.");
		auto url = getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/contents"~path.toString()~"?ref="~commit_sha;
		auto ls = readJson(url).get!(Json[]);
		RepositoryFile[] ret;
		ret.reserve(ls.length);
		foreach (entry; ls) {
			string type = entry["type"].get!string;
			RepositoryFile file;
			if (type == "dir") {
				file.type = RepositoryFile.Type.directory;
			}
			else if (type == "file") {
				file.type = RepositoryFile.Type.file;
				file.size = entry["size"].get!size_t;
			}
			else continue;
			file.commitSha = commit_sha;
			file.path = InetPath("/" ~ entry["path"].get!string);
			ret ~= file;
		}
		return ret;
	}

	void readFile(string commit_sha, InetPath path, scope void delegate(scope InputStream) @safe reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto url = getContentURLPrefix()~"/"~m_owner~"/"~m_project~"/"~commit_sha~path.toString();
		downloadCached(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		import std.uri : encodeComponent;
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		auto venc = () @trusted { return encodeComponent(ver); } ();
		return "https://github.com/"~m_owner~"/"~m_project~"/archive/"~venc~".zip";
	}

	void download(string ver, scope void delegate(scope InputStream) @safe del)
	{
		downloadCached(getDownloadUrl(ver), del);
	}

	private string getAPIURLPrefix()
	{
		import std.uri : encodeComponent;
		if (m_authUser.length) return "https://"~m_authUser~":"~m_authPassword~"@api.github.com";
		else return "https://api.github.com";
	}

	private string getContentURLPrefix()
	{
		return "https://raw.githubusercontent.com";
	}
}
