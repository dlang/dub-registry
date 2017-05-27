/**
	Support for GitLab repositories.

	Copyright: © 2015-2017 rejectedsoftware e.K.
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
import vibe.http.client : HTTPClientRequest;
import vibe.inet.url;
import vibe.textfilter.urlencode;


class GitLabRepository : Repository {
	private {
		string m_owner;
		string m_project;
		URL m_baseURL;
		string m_authToken;
	}

	static void register(string auth_token, string url)
	{
		Repository factory(DbRepository info){
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
		try tags = readJson!(r => addAuth(r))(getAPIURLPrefix()~"repository/tags");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag["name"].get!string;
				Json commit = readJson!(r => addAuth(r))(getAPIURLPrefix()~"repository/commits/"~tag["commit"]["id"].get!string, true, true);
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

		Json branches = readJson!(r => addAuth(r))(getAPIURLPrefix()~"repository/branches");
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch["name"].get!string;
			Json commit = readJson!(r => addAuth(r))(getAPIURLPrefix()~"repository/commits/"~branch["commit"]["id"].get!string, true, true);
			ret ~= RefInfo(branchname, branch["commit"]["id"].get!string, SysTime.fromISOExtString(commit["committed_date"].get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		RepositoryInfo ret;
		auto nfo = readJson!(r => addAuth(r))(getAPIURLPrefix());
		ret.isFork = false; // not reported by API
		//ret.stars = nfo["star_count"].opt!uint;
		//ret.forks = nfo["forks_count"].opt!uint;
		return ret;
	}

	void readFile(string commit_sha, Path path, scope void delegate(scope InputStream) reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto url = m_baseURL.toString() ~ (m_owner ~ "/" ~ m_project ~ "/raw/" ~ commit_sha) ~ path.toString();
		downloadCached!(r => addAuth(r))(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		return m_baseURL.toString()~m_owner~"/"~m_project~"/repository/archive.zip?ref="~ver;
	}

	void download(string ver, scope void delegate(scope InputStream) del)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		auto url = m_baseURL.toString()~m_owner~"/"~m_project~"/repository/archive.zip?ref="~ver;
		downloadCached!(r => addAuth(r))(url, del);
	}

	private string getAPIURLPrefix() {
		return m_baseURL.toString() ~ "api/v4/projects/" ~ (m_owner ~ "/" ~ m_project).urlEncode ~ "/";
	}

	private void addAuth(scope HTTPClientRequest req)
	{
		req.headers["PRIVATE-TOKEN"] = "Bearer "~m_authToken;
	}
}
