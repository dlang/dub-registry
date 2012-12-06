import vibe.vibe;


private {
	Repository[string] s_repositories;
}

Repository getRepository(Json repinfo, ref RepositoryETags etags)
{
	auto ident = repinfo.toString();
	if( auto pr = ident in s_repositories )
		return *pr;

	enforce(repinfo.kind == "github");
	auto rep = new GithubRepository(repinfo.owner.get!string, repinfo.project.get!string, etags);
	s_repositories[ident] = rep;
	return rep;
}

interface Repository {
	string[] getVersions(ref RepositoryETags etags);
	string[] getBranches(ref RepositoryETags etags);
	Json getPackageInfo(string ver, ref RepositoryETags etags);
	string getDownloadUrl(string ver);
}

struct RepositoryETags {
	string tags;
	string branches;
	string[string] packageInfo;
}

class GithubRepository : Repository {
	private {
		string m_owner;
		string m_project;
		string[string] m_versions;
		string[string] m_branches;
		string[] m_versionList;
		string[] m_branchList;
	}

	this(string owner, string project, ref RepositoryETags etags)
	{
		m_owner = owner;
		m_project = project;
		getVersions(etags); // download an initial version list
	}

	string[] getVersions(ref RepositoryETags etags)
	{
		auto url = "https://api.github.com/repos/"~m_owner~"/"~m_project~"/tags";
		auto res = requestHttp(url, (req){
				if( etags.tags.length ) req.headers["If-None-Match"] = etags.tags;
			});
		if( res.statusCode == HttpStatus.NotModified ){
			logDebug("No new tags for %s/%s", m_owner, m_project);
			return m_versionList;
		}
		if( res.statusCode != HttpStatus.OK ){
			logDebug("GITHUB REPLY FOR TAG QUERY: %s", res.bodyReader.readAllUtf8());
		}
		enforce(res.statusCode == HttpStatus.OK, "Failed to get tags using the github API for "~m_owner~"/"~m_project~": "~httpStatusText(res.statusCode));
		etags.tags = res.headers["ETag"];

		auto tags = res.readJson();
		m_versionList.length = 0;
		foreach_reverse( tag; tags ){
			auto tagname = tag.name.get!string;
			if( tagname.length >= 2 && tagname[0] == 'v' ){
				m_versions[tagname[1 .. $]] = tag.commit.sha.get!string;
				m_versionList ~= tagname[1 .. $];
				logDebug("Found version for %s/%s: %s", m_owner, m_project, tagname);
			}
		}
		return m_versionList;
	}

	string[] getBranches(ref RepositoryETags etags)
	{
		auto url = "https://api.github.com/repos/"~m_owner~"/"~m_project~"/branches";
		auto res = requestHttp(url, (req){
				if( etags.branches.length ) req.headers["If-None-Match"] = etags.branches;
			});
		if( res.statusCode == HttpStatus.NotModified ){
			logDebug("No new branches for %s/%s", m_owner, m_project);
			return m_branchList;
		}
		if( res.statusCode != HttpStatus.OK ){
			logDebug("GITHUB REPLY FOR TAG QUERY: %s", res.bodyReader.readAllUtf8());
		}
		enforce(res.statusCode == HttpStatus.OK, "Failed to get tags using the github API for "~m_owner~"/"~m_project~": "~httpStatusText(res.statusCode));
		etags.branches = res.headers["ETag"];

		auto branches = res.readJson();
		m_branchList.length = 0;
		foreach_reverse( branch; branches ){
			auto branchname = branch.name.get!string;
			m_branches[branchname] = branch.commit.sha.get!string;
			m_branchList ~= "~"~branchname;
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return m_branchList;
	}

	Json getPackageInfo(string ver, ref RepositoryETags etags)
	{
		string url;
		if( ver.startsWith("~") ){
			url = "https://raw.github.com/"~m_owner~"/"~m_project~"/"~ver[1 .. $]~"/package.json";
		} else {
			auto pc = ver in m_versions;
			enforce(pc !is null, "Invalid version identifier.");
			url = "https://raw.github.com/"~m_owner~"/"~m_project~"/"~(*pc)~"/package.json";
		}
		auto res = requestHttp(url, (req){
				auto etag = etags.packageInfo.get(ver, "");
				if( etag.length ) req.headers["If-None-Match"] = etag;
			});
		if( res.statusCode == HttpStatus.NotModified ){
			logDebug("Package has not changed for %s/%s", m_owner, m_project);
			return Json();
		}
		enforce(res.statusCode == HttpStatus.OK, "Failed to get package.json for version "~ver);
		etags.packageInfo[ver] = res.headers["ETag"];
		logInfo("Getting JSON response from %s", url);
		auto ret = res.readJson();
		if( auto pv = "version" in ret )
			if( *pv != ver )
				logWarn("Package %s/%s package.json contains version and does not match tag: %s vs %s", m_owner, m_project, *pv, ver);
		ret["version"] = ver;
		ret.url = getDownloadUrl(ver);
		ret.downloadUrl = getDownloadUrl(ver);
		return ret;
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = "v" ~ ver;
		return "https://github.com/"~m_owner~"/"~m_project~"/archive/"~ver~".zip";
	}
}