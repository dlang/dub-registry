module dubregistry.repositories.repository;

import vibe.vibe;

import dubregistry.cache;
import std.digest.sha;


Repository getRepository(Json repinfo)
{
	auto ident = repinfo.toString();
	if( auto pr = ident in s_repositories )
		return *pr;

	logDebug("Returning new repository: %s", ident);
	auto pf = repinfo.kind.get!string in s_repositoryFactories;
	enforce(pf, "Unknown repository type: "~repinfo.kind.get!string);
	auto rep = (*pf)(repinfo);
	s_repositories[ident] = rep;
	return rep;
}

void addRepositoryFactory(string kind, RepositoryFactory factory)
{
	assert(kind !in s_repositoryFactories);
	s_repositoryFactories[kind] = factory;
}


alias RepositoryFactory = Repository delegate(Json);

struct PackageVersionInfo {
	SysTime date;
	string version_;
	Json info;
}

interface Repository {
	string[] getVersions();
	string[] getBranches();
	PackageVersionInfo getVersionInfo(string ver);
	string getDownloadUrl(string ver);
}

struct CommitInfo {
	string sha;
	BsonDate date;

	this(string sha, string date)
	{
		this.sha = sha;
		this.date = BsonDate(SysTime.fromISOExtString(date));
	}
}

private {
	Repository[string] s_repositories;
	RepositoryFactory[string] s_repositoryFactories;
}
