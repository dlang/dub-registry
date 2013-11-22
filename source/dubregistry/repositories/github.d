/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.github;

import dubregistry.cache;
import dubregistry.repositories.repository;
import std.string : startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;


class GithubRepository : Repository {
	private {
		string m_owner;
		string m_project;
	}

	static void register()
	{
		Repository factory(Json info){
			return new GithubRepository(info.owner.get!string, info.project.get!string);
		}
		addRepositoryFactory("github", &factory);
	}

	this(string owner, string project)
	{
		m_owner = owner;
		m_project = project;
	}

	Tuple!(string, CommitInfo)[] getTags()
	{
		Json tags;
		try tags = readJson("https://api.github.com/repos/"~m_owner~"/"~m_project~"/tags");
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		Tuple!(string, CommitInfo)[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag.name.get!string;
				Json commit = readJson("https://api.github.com/repos/"~m_owner~"/"~m_project~"/commits/"~tag.commit.sha.get!string, true, true);
				ret ~= tuple(tagname, CommitInfo(tag.commit.sha.get!string, commit.commit.committer.date.get!string));
				logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag.name.get!string~": "~e.msg);
			}
		}
		return ret;
	}

	Tuple!(string, CommitInfo)[] getBranches()
	{
		Json branches = readJson("https://api.github.com/repos/"~m_owner~"/"~m_project~"/branches");
		Tuple!(string, CommitInfo)[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch.name.get!string;
			Json commit = readJson("https://api.github.com/repos/"~m_owner~"/"~m_project~"/commits/"~branch.commit.sha.get!string, true, true);
			ret ~= tuple(branchname, CommitInfo(branch.commit.sha.get!string, commit.commit.committer.date.get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	void readFile(string commit_sha, Path path, scope void delegate(scope InputStream) reader)
	{
		assert(path.absolute);
		auto url = "https://raw.github.com/"~m_owner~"/"~m_project~"/"~commit_sha~path.toString();
		downloadCached(url, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		return "https://github.com/"~m_owner~"/"~m_project~"/archive/"~ver~".zip";
	}
}
