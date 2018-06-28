/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.bitbucket;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
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

	RefInfo[] getTags()
	{
		Json tags;
		try tags = readJson(getAPIURLPrefix ~ "/1.0/repositories/"~m_owner~"/"~m_project~"/tags");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach (string tagname, tag; tags.byKeyValue) {
			try {
				auto commit_hash = tag["raw_node"].get!string();
				auto commit_date = bbToIsoDate(tag["utctimestamp"].get!string());
				ret ~= RefInfo(tagname, commit_hash, commit_date);
				logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag["name"].get!string~": "~e.msg);
			}
		}
		return ret;
	}

	RefInfo[] getBranches()
	{
		Json branches = readJson(getAPIURLPrefix ~ "/1.0/repositories/"~m_owner~"/"~m_project~"/branches");
		RefInfo[] ret;
		foreach (string branchname, branch; branches.byKeyValue) {
			auto commit_hash = branch["raw_node"].get!string();
			auto commit_date = bbToIsoDate(branch["utctimestamp"].get!string());
			ret ~= RefInfo(branchname, commit_hash, commit_date);
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		auto nfo = readJson(getAPIURLPrefix ~ "/1.0/repositories/"~m_owner~"/"~m_project);
		RepositoryInfo ret;
		ret.isFork = nfo["is_fork"].opt!bool;
		ret.stats.watchers = nfo["followers_count"].opt!uint;
		ret.stats.forks = nfo["forks_count"].opt!uint;
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
		auto url = getAPIURLPrefix ~ "/1.0/repositories/"~m_owner~"/"~m_project~"/raw/"~commit_sha~path.toString();
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

private auto bbToIsoDate(string bbdate)
@safe {
	import std.array, std.datetime : SysTime;
	auto ttz = bbdate.split("+");
	if( ttz.length < 2 ) ttz ~= "00:00";
	auto parts = ttz[0].split("-");
	parts = parts[0 .. $-1] ~ parts[$-1].split(" ");
	parts = parts[0 .. $-1] ~ parts[$-1].split(":");

	return SysTime.fromISOString(format("%s%s%sT%s%s%s+%s", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], ttz[1]));
}
