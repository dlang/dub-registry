module github;

import cache;
import repository;
import vibe.vibe;


class GithubRepository : Repository {
	private {
		string m_owner;
		string m_project;
		CommitInfo[string] m_versions;
		CommitInfo[string] m_branches;
		string[] m_versionList;
		string[] m_branchList;
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
		try getVersions(); // download an initial version list
		catch( Exception e ){
			logWarn("Failed to get initial version list for github:%s/%s: %s", owner, project, e.msg);
		}
	}

	string[] getVersions()
	{
		Json tags;
		try downloadCached("https://api.github.com/repos/"~m_owner~"/"~m_project~"/tags", (scope input){ tags = input.readJson(); });
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		m_versionList.length = 0;
		foreach_reverse( tag; tags ){
			try {
				auto tagname = tag.name.get!string;
				if( tagname.length >= 2 && tagname[0] == 'v' ){
					Json commit;
					downloadCached("https://api.github.com/repos/"~m_owner~"/"~m_project~"/commits/"~tag.commit.sha.get!string, (scope input){ commit = input.readJson(); });
					m_versions[tagname[1 .. $]] = CommitInfo(tag.commit.sha.get!string, commit.commit.committer.date.get!string);
					m_versionList ~= tagname[1 .. $];
					logDebug("Found version for %s/%s: %s", m_owner, m_project, tagname);
				}
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag.get!string~": "~e.msg);
			}
		}
		return m_versionList;
	}

	string[] getBranches()
	{
		Json branches;
		downloadCached("https://api.github.com/repos/"~m_owner~"/"~m_project~"/branches", (scope input){ branches = input.readJson(); });
		m_branchList.length = 0;
		foreach_reverse( branch; branches ){
			auto branchname = branch.name.get!string;
			Json commit;
			downloadCached("https://api.github.com/repos/"~m_owner~"/"~m_project~"/commits/"~branch.commit.sha.get!string, (scope input){ commit = input.readJson(); });
			m_branches[branchname] = CommitInfo(branch.commit.sha.get!string, commit.commit.committer.date.get!string);
			m_branchList ~= "~"~branchname;
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return m_branchList;
	}

	PackageVersionInfo getVersionInfo(string ver)
	{
		string url;
		SysTime date;
		if( ver.startsWith("~") ){
			auto pc = ver[1 .. $] in m_branches;
			url = "https://raw.github.com/"~m_owner~"/"~m_project~"/"~ver[1 .. $]~"/package.json";
			if( pc ) date = pc.date.toSysTime();
		} else {
			auto pc = ver in m_versions;
			enforce(pc !is null, "Invalid version identifier.");
			url = "https://raw.github.com/"~m_owner~"/"~m_project~"/"~(pc.sha)~"/package.json";
			date = pc.date.toSysTime();
		}

		PackageVersionInfo ret;
		logInfo("Getting JSON response from %s", url);
		downloadCached(url, (scope input){ ret.info = input.readJson(); });

		if( auto pv = "version" in ret.info ){
			if( *pv != ver )
				logWarn("Package %s/%s package.json contains version and does not match tag: %s vs %s", m_owner, m_project, *pv, ver);
		}
		ret.version_ = ver;
		ret.date = date;
		return ret;
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = "v" ~ ver;
		return "https://github.com/"~m_owner~"/"~m_project~"/archive/"~ver~".zip";
	}
}

private Json readJson(InputStream str)
{
	auto text = str.readAllUtf8();
	return parseJson(text);
}
