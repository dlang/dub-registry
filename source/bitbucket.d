module bitbucket;

import cache;
import repository;
import std.array;
import std.string;
import vibe.vibe;


class BitbucketRepository : Repository {
	private {
		string m_owner;
		string m_project;
		CommitInfo[string] m_versions;
		CommitInfo[string] m_branches;
		string[] m_versionList;
		string[] m_branchList;
		bool m_gotVersions = false;
		bool m_gotBranches = false;
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

	string[] getVersions()
	{
		m_gotVersions = true;

		Json tags;
		try downloadCached("https://api.bitbucket.org/1.0/repositories/"~m_owner~"/"~m_project~"/tags", (scope input){ tags = input.readJson(); });
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		m_versionList.length = 0;
		foreach( string tagname, tag; tags ){
			try {
				if( tagname.length >= 2 && tagname[0] == 'v' ){
					auto commit_hash = tag.raw_node.get!string();
					auto commit_date = bbToIsoDate(tag.utctimestamp.get!string());
					m_versions[tagname[1 .. $]] = CommitInfo(commit_hash, commit_date);
					m_versionList ~= tagname[1 .. $];
					logDebug("Found version for %s/%s: %s", m_owner, m_project, tagname);
				}
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag.name.get!string~": "~e.msg);
			}
		}
		return m_versionList;
	}

	string[] getBranches()
	{
		Json branches;
		downloadCached("https://api.bitbucket.org/1.0/repositories/"~m_owner~"/"~m_project~"/branches", (scope input){ branches = input.readJson(); });
		m_branchList.length = 0;
		foreach( string branchname, branch; branches ){
			auto commit_hash = branch.raw_node.get!string();
			auto commit_date = bbToIsoDate(branch.utctimestamp.get!string());
			m_branches[branchname] = CommitInfo(commit_hash, commit_date);
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
			if( !m_gotBranches ) getBranches();
			auto pc = ver[1 .. $] in m_branches;
			url = "https://bitbucket.org/api/1.0/repositories/"~m_owner~"/"~m_project~"/raw/"~ver[1 .. $]~"/package.json";
			if( pc ) date = pc.date.toSysTime();
		} else {
			if( !m_gotVersions ) getVersions();
			auto pc = ver in m_versions;
			enforce(pc !is null, "Invalid version identifier.");
			url = "https://bitbucket.org/api/1.0/repositories/"~m_owner~"/"~m_project~"/raw/"~(pc.sha)~"/package.json";
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
		return "https://bitbucket.org/"~m_owner~"/"~m_project~"/get/"~ver~".zip";
	}
}

private Json readJson(InputStream str, bool sanitize = false)
{
	auto text = str.readAllUtf8(sanitize);
	return parseJson(text);
}

private string bbToIsoDate(string bbdate)
{
	auto ttz = bbdate.split("+");
	if( ttz.length < 2 ) ttz ~= "00:00";
	auto parts = ttz[0].split("-");
	parts = parts[0 .. $-1] ~ parts[$-1].split(" ");
	parts = parts[0 .. $-1] ~ parts[$-1].split(":");

	return SysTime.fromISOString(format("%s%s%sT%s%s%s+%s", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], ttz[1])).toISOExtString();
}