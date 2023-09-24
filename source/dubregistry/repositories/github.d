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


class GithubRepositoryProvider : RepositoryProvider {
	private {
		string m_token;
	}
@safe:

	private this(string token)
	{
		m_token = token;
	}

	static void register(string token)
	{
		auto h = new GithubRepositoryProvider(token);
		addRepositoryProvider("github", h);
	}

	Repository getRepository(DbRepository repo)
	@safe {
		return new GithubRepository(repo.owner, repo.project, m_token);
	}
}


class GithubRepository : Repository {
@safe:
	private {
		string m_owner;
		string m_project;
		string m_authToken;
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
		Json[] tags;
		try tags = readPagedListFromRepo("/tags?per_page=100");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag["name"].get!string;
				Json commit = readJsonFromRepo("/commits/"~tag["commit"]["sha"].get!string, true, true);
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

	private Json[] readPagedListFromRepo(string api_path, bool sanitize = false, bool cache_priority = false)
	{
		return readPagedList(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~api_path,
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

package Json[] readPagedList(string url, bool sanitize = false, bool cache_priority = false, RequestModifier request_modifier = null)
@safe {
	import dubregistry.internal.utils : black;
	import std.array : appender;
	import std.format : format;
	import vibe.stream.operations : readAllUTF8;

	auto ret = appender!(Json[]);
	Exception ex;
	string next = url;

	NextLoop: while (next.length) {
		logDiagnostic("Getting paged JSON response from %s", next.black);
		foreach (i; 0 .. 2) {
			try {
				downloadCached(next, (scope input, scope headers) {
					scope (failure) clearCacheEntry(url);
					next = getNextLink(headers);

					auto text = input.readAllUTF8(sanitize);
					ret ~= parseJsonString(text).get!(Json[]);
				}, ["Link"], cache_priority, request_modifier);
				continue NextLoop;
			} catch (FileNotFoundException e) {
				throw e;
			} catch (Exception e) {
				logDiagnostic("Failed to parse downloaded JSON document (attempt #%s): %s", i+1, e.msg);
				ex = e;
			}
		}
		throw new Exception(format("Failed to read JSON from %s: %s", url.black, ex.msg), __FILE__, __LINE__, ex);
	}

	return ret.data;
}

private string getNextLink(scope string[string] headers)
@safe {
	import uritemplate : expandTemplateURIString;
	import std.algorithm : endsWith, splitter, startsWith;

	static immutable string startPart = `<`;
	static immutable string endPart = `>; rel="next"`;

	if (auto link = "Link" in headers) {
		foreach (part; (*link).splitter(", ")) {
			if (part.startsWith(startPart) && part.endsWith(endPart)) {
				return expandTemplateURIString(part[startPart.length .. $ - endPart.length], null);
			}
		}
	}
	return null;
}
