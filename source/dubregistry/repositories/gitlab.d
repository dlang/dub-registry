/**
	Support for GitLab repositories.

	Copyright: © 2015-2016 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.gitlab;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
import std.string : startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;
import vibe.textfilter.urlencode;


class GitLabRepository : Repository {
@safe:

	private {
		string m_owner;
		string m_project;
		URL m_baseURL;
		string m_authToken;
	}

	static void register(string auth_token, string url)
	{
		Repository factory(DbRepository info) @safe {
			return new GitLabRepository(info.owner, info.project, auth_token, url.length ? URL(url) : URL("https://gitlab.com/"));
		}
		addRepositoryFactory("gitlab", &factory);
	}

	this(string owner, string project, string auth_token, URL base_url)
	{
		m_owner = owner;
		m_project = project;
		m_authToken = auth_token;
		m_baseURL = base_url;
	}

	RefInfo[] getTags()
	{
		import std.datetime : SysTime;

		Json tags;
		try tags = readJson(getAPIURLPrefix()~"repository/tags?private_token="~m_authToken);
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag["name"].get!string;
				Json commit = readJson(getAPIURLPrefix()~"repository/commits/"~tag["commit"]["id"].get!string~"?private_token="~m_authToken, true, true);
				ret ~= RefInfo(tagname, tag["commit"]["id"].get!string, SysTime.fromISOExtString(commit["committed_date"].get!string));
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

		Json branches = readJson(getAPIURLPrefix()~"repository/branches?private_token="~m_authToken);
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch["name"].get!string;
			Json commit = readJson(getAPIURLPrefix()~"repository/commits/"~branch["commit"]["id"].get!string~"?private_token="~m_authToken, true, true);
			ret ~= RefInfo(branchname, branch["commit"]["id"].get!string, SysTime.fromISOExtString(commit["committed_date"].get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		RepositoryInfo ret;
		auto nfo = readJson(getAPIURLPrefix()~"?private_token="~m_authToken);
		ret.isFork = false; // not reported by API
		ret.stats.stars = nfo["star_count"].opt!uint; // might mean watchers for Gitlab
		ret.stats.forks = nfo["forks_count"].opt!uint;
		ret.stats.issues = nfo["open_issues_count"].opt!uint;
		return ret;
	}

	RepositoryFile[] listFiles(string commit_sha, InetPath path)
	{
		import std.uri : encodeComponent;
		assert(path.absolute, "Passed relative path to listFiles.");
		auto penc = () @trusted { return encodeComponent(path.toString()[1..$]); } ();
		auto url = getAPIURLPrefix()~"/repository/tree?path="~penc~"&ref="~commit_sha;
		auto ls = readJson(url)["values"].get!(Json[]);
		RepositoryFile[] ret;
		ret.reserve(ls.length);
		foreach (entry; ls) {
			string type = entry["type"].get!string;
			RepositoryFile file;
			if (type == "tree") {
				file.type = RepositoryFile.Type.directory;
			}
			else if (type == "blob") {
				file.type = RepositoryFile.Type.file;
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
		auto url = m_baseURL.toString() ~ (m_owner ~ "/" ~ m_project ~ "/raw/" ~ commit_sha) ~ path.toString() ~ "?private_token="~m_authToken;
		downloadCached(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if (m_authToken.length > 0) return null; // public download URL doesn't work
		return getRawDownloadURL(ver);
	}

	void download(string ver, scope void delegate(scope InputStream) @safe del)
	{
		auto url = getRawDownloadURL(ver);
		url ~= "&private_token="~m_authToken;
		downloadCached(url, del);
	}

	private string getRawDownloadURL(string ver)
	{
		import std.uri : encodeComponent;
		if (ver.startsWith("~")) ver = ver[1 .. $];
		else ver = ver;
		auto venc = () @trusted { return encodeComponent(ver); } ();
		return m_baseURL.toString()~m_owner~"/"~m_project~"/repository/archive.zip?ref="~venc;
	}

	private string getAPIURLPrefix()
	{
		return m_baseURL.toString() ~ "api/v4/projects/" ~ (m_owner ~ "/" ~ m_project).urlEncode ~ "/";
	}
}
