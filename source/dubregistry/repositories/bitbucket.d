/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.bitbucket;

import dubregistry.cache;
import dubregistry.repositories.repository;
import std.string : format, startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;


class BitbucketRepository : Repository {
	private {
		string m_owner;
		string m_project;
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

	RefInfo[] getTags()
	{
		Json tags;
		try tags = readJson("https://api.bitbucket.org/1.0/repositories/"~m_owner~"/"~m_project~"/tags");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach( string tagname, tag; tags ){
			try {
				auto commit_hash = tag.raw_node.get!string();
				auto commit_date = bbToIsoDate(tag.utctimestamp.get!string());
				ret ~= RefInfo(tagname, commit_hash, commit_date);
				logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag.name.get!string~": "~e.msg);
			}
		}
		return ret;
	}

	RefInfo[] getBranches()
	{
		Json branches = readJson("https://api.bitbucket.org/1.0/repositories/"~m_owner~"/"~m_project~"/branches");
		RefInfo[] ret;
		foreach( string branchname, branch; branches ){
			auto commit_hash = branch.raw_node.get!string();
			auto commit_date = bbToIsoDate(branch.utctimestamp.get!string());
			ret ~= RefInfo(branchname, commit_hash, commit_date);
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	void readFile(string commit_sha, Path path, scope void delegate(scope InputStream) reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto url = "https://bitbucket.org/api/1.0/repositories/"~m_owner~"/"~m_project~"/raw/"~commit_sha~path.toString();
		downloadCached(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		return "https://bitbucket.org/"~m_owner~"/"~m_project~"/get/"~ver~".zip";
	}
}

private auto bbToIsoDate(string bbdate)
{
	import std.array, std.datetime : SysTime;
	auto ttz = bbdate.split("+");
	if( ttz.length < 2 ) ttz ~= "00:00";
	auto parts = ttz[0].split("-");
	parts = parts[0 .. $-1] ~ parts[$-1].split(" ");
	parts = parts[0 .. $-1] ~ parts[$-1].split(":");

	return SysTime.fromISOString(format("%s%s%sT%s%s%s+%s", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], ttz[1]));
}
