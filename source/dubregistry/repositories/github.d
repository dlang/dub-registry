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
import vibe.http.client : HTTPClientRequest;
import vibe.inet.url;


class GithubRepository : Repository {
@safe:
	private {
		string m_owner;
		string m_project;
		string m_authToken;
	}

	static void register(string token)
	{
		Repository factory(DbRepository info) @safe {
			return new GithubRepository(info.owner, info.project, token);
		}
		addRepositoryFactory("github", &factory);
	}

	this(string owner, string project, string auth_token)
	{
		m_owner = owner;
		m_project = project;
		m_authToken = auth_token;
	}

	RefInfo[] getTags()
	{
		import std.datetime.systime : SysTime;
		import std.conv: text;
		RefInfo[] ret;
		for (size_t page = 1; ; page++)
		{
			Json tags;
			try tags = readJsonFromRepo("/tags?per_page=100&page=" ~ page.text);
			catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
			size_t count;
			foreach_reverse (tag; tags) {
				try {
					count++;
					auto tagname = tag["name"].get!string;
					Json commit = readJsonFromRepo("/commits/"~tag["commit"]["sha"].get!string, true, true);
					ret ~= RefInfo(tagname, tag["commit"]["sha"].get!string, SysTime.fromISOExtString(commit["commit"]["committer"]["date"].get!string));
					logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
				} catch( Exception e ){
					throw new Exception("Failed to process tag "~tag["name"].get!string~": "~e.msg);
				}
			}
			if (count < 100)
				break;
		}
		return ret;
	}

	RefInfo[] getBranches()
	{
		import std.datetime.systime : SysTime;

		Json branches = readJsonFromRepo("/branches");
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch["name"].get!string;
			Json commit = readJsonFromRepo("/commits/"~branch["commit"]["sha"].get!string, true, true);
			ret ~= RefInfo(branchname, branch["commit"]["sha"].get!string, SysTime.fromISOExtString(commit["commit"]["committer"]["date"].get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		auto nfo = readJsonFromRepo("");
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
		auto url = "/contents"~path.toString()~"?ref="~commit_sha;
		auto ls = readJsonFromRepo(url).get!(Json[]);
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
		}, true, &addAuthentication);
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
		downloadCached(getDownloadUrl(ver), del, false, &addAuthentication);
	}

	private Json readJsonFromRepo(string api_path, bool sanitize = false, bool cache_priority = false)
	{
		return readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~api_path,
			sanitize, cache_priority, &addAuthentication);
	}

	private void addAuthentication(scope HTTPClientRequest req)
	{
		req.headers["Authorization"] = "token " ~ m_authToken;
	}

	private string getAPIURLPrefix()
	{
		return "https://api.github.com";
	}

	private string getContentURLPrefix()
	{
		return "https://raw.githubusercontent.com";
	}
}
