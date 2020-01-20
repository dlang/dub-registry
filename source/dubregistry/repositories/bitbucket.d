/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.bitbucket;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
import std.datetime: SysTime;
import std.string : format, startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;


class BitbucketRepository : Repository {
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
			return new BitbucketRepository(info.owner, info.project, user, password);
		}
		addRepositoryFactory("bitbucket", &factory);
	}

	this(string owner, string project, string auth_user, string auth_password)
	{
		m_owner = owner;
		m_project = project;
		m_authUser = auth_user;
		m_authPassword = auth_password;
	}

	package Json readPaginatedJson(string url, bool sanitize = false, bool cache_priority = false) @safe {
		Json merged = Json.emptyArray;
		string nextUrl = url;

		while(true) {
			Json page = readJson(nextUrl, sanitize, cache_priority);

			// foreach(Json value; page["values"] ) {
			//     merged ~= value;
			// }
			merged ~= page["values"];

			if("next" in page) {
				nextUrl = page["next"].get!string();
			} else {
				break;
			}
		}

		return merged;
	}

	package uint readPaginatedLength(string url, bool sanitize = false, bool cache_priority = false) @safe {
		Json page = readJson(url, sanitize, cache_priority);
		const uint length = page["size"].get!uint();
		return length;
	}

	RefInfo[] extractRefInfo(Json refListJson) {
		RefInfo[] ret;
		foreach(Json refJson; refListJson.byValue()) {
			string refname = refJson["name"].get!string();
			try {
				Json target = refJson["target"];
				string commit_hash = target["hash"].get!string();
				auto commit_date = SysTime.fromISOExtString(target["date"].get!string());
				ret ~= RefInfo(refname, commit_hash, commit_date);
				logDebug("Found ref for %s/%s: %s", m_owner, m_project, refname);
			} catch( Exception e ){
				throw new Exception("Failed to process ref "~refname~": "~e.msg);
			}
		}
		return ret;
	}

	RefInfo[] getTags()
	{
		Json tags;
		try tags = readPaginatedJson(getAPIURLPrefix ~ "/2.0/repositories/"~m_owner~"/"~m_project~"/refs/tags");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret = extractRefInfo(tags);
		return ret;
	}

	RefInfo[] getBranches()
	{
		Json branches = readPaginatedJson(getAPIURLPrefix ~ "/2.0/repositories/"~m_owner~"/"~m_project~"/refs/branches");
		RefInfo[] ret = extractRefInfo(branches);
		return ret;
	}

	RepositoryInfo getInfo()
	{
		Json nfo = readJson(getAPIURLPrefix ~ "/2.0/repositories/"~m_owner~"/"~m_project);
		RepositoryInfo ret;
		ret.isFork = nfo["is_fork"].opt!bool;
		ret.stats.watchers = readPaginatedLength(getAPIURLPrefix ~ "/2.0/repositories/" ~ m_owner ~ "/" ~ m_project ~ "/watchers");
		ret.stats.forks = readPaginatedLength(getAPIURLPrefix ~ "/2.0/repositories/" ~ m_owner ~ "/" ~ m_project ~ "/forks");
		return ret;
	}

	RepositoryFile[] listFiles(string commit_sha, InetPath path)
	{
		assert(path.absolute, "Passed relative path to listFiles.");
		auto url = getAPIURLPrefix ~ "/api/2.0/repositories/"~m_owner~"/"~m_project~"/src/"~commit_sha~path.toString()~"?pagelen=100";
		auto ls = readJson(url)["values"].get!(Json[]);
		RepositoryFile[] ret;
		ret.reserve(ls.length);
		foreach (entry; ls) {
			string type = entry["type"].get!string;
			RepositoryFile file;
			if (type == "commit_directory") {
				file.type = RepositoryFile.Type.directory;
			}
			else if (type == "commit_file") {
				file.type = RepositoryFile.Type.file;
				file.size = entry["size"].get!size_t;
			}
			else continue;
			file.commitSha = entry["commit"]["hash"].get!string;
			file.path = InetPath("/" ~ entry["path"].get!string);
			ret ~= file;
		}
		return ret;
	}

	void readFile(string commit_sha, InetPath path, scope void delegate(scope InputStream) @safe reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto url = getAPIURLPrefix ~ "/2.0/repositories/"~m_owner~"/"~m_project~"/src/"~commit_sha~path.toString();
		downloadCached(url, (scope input) @safe {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		import std.uri : encodeComponent;
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		auto venc = () @trusted { return encodeComponent(ver); } ();
		const url = "https://bitbucket.org/"~m_owner~"/"~m_project~"/get/"~venc~".zip";
		if (m_authUser.length) return "https://"~encodeComponent(m_authUser)~":"~encodeComponent(m_authPassword)~"@"~url["https://".length..$];
		return url;
	}

	void download(string ver, scope void delegate(scope InputStream) @safe del)
	{
		downloadCached(getDownloadUrl(ver), del);
	}

	private string getAPIURLPrefix()
	{
		import std.uri : encodeComponent;
		if (m_authUser.length) return "https://"~encodeComponent(m_authUser)~":"~encodeComponent(m_authPassword)~"@api.bitbucket.org";
		else return "https://api.bitbucket.org";
	}
}
