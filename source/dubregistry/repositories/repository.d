/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.repository;

import vibe.vibe;

import dubregistry.cache;
import dubregistry.dbcontroller : DbRepository, DbRepoStats;
import std.digest.sha;
import std.typecons;


Repository getRepository(DbRepository repinfo)
@safe {
	if( auto pr = repinfo in s_repositories )
		return *pr;

	logDebug("Returning new repository: %s", repinfo);
	auto pf = repinfo.kind in s_repositoryProviders;
	enforce(pf, "Unknown repository type: "~repinfo.kind);
	auto rep = pf.getRepository(repinfo);
	s_repositories[repinfo] = rep;
	return rep;
}


/** Adds a new provider to support for accessing repositories.

	Note that currently only one provider instance of each `kind` may be used,
	because the `kind` value is used to identify the provider as opposed to its
	URL.
*/
void addRepositoryProvider(string kind, RepositoryProvider factory)
@safe {
	assert(kind !in s_repositoryProviders);
	s_repositoryProviders[kind] = factory;
}

bool supportsRepositoryKind(string kind)
@safe {
	return (kind in s_repositoryProviders) !is null;
}

/** Attempts to parse a URL that points to a repository.

	Throws:
		Will throw an exception if the URL corresponds to a registered
		repository provider, but does not point to a repository.

	Returns:
		`true` is returned $(EM iff) the URL corresponds to any registered
		repository provider.
*/
bool parseRepositoryURL(URL url, out DbRepository repo)
{
	foreach (kind, h; s_repositoryProviders)
		if (h.parseRepositoryURL(url, repo)) {
			assert(repo.kind == kind);
			return true;
		}
	return false;
}


interface RepositoryProvider {
	/** Attempts to parse a URL that points to a repository.

		Throws:
			Will throw an exception if the URL corresponds to the repository
			provider, but does not point to a repository.

		Returns:
			`true` is returned $(EM iff) the URL corresponds to the repository
			provider.
	*/
	bool parseRepositoryURL(URL url, out DbRepository repo) @safe;

	/** Creates a `Repository` instance corresponding to the given repository.
	*/
	Repository getRepository(DbRepository repo) @safe;
}

interface Repository {
@safe:
	RefInfo[] getTags();
	RefInfo[] getBranches();
	/// Get basic repository information, throws FileNotFoundException when the repo no longer exists.
	RepositoryInfo getInfo();
	RepositoryFile[] listFiles(string commit_sha, InetPath path);
	void readFile(string commit_sha, InetPath path, scope void delegate(scope InputStream) @safe reader);
	string getDownloadUrl(string tag_or_branch);
	void download(string tag_or_branch, scope void delegate(scope InputStream) @safe del);
}

struct RepositoryInfo {
	bool isFork;
	DbRepoStats stats;
}

struct RefInfo {
	string name;
	string sha;
	BsonDate date;

	this(string name, string sha, SysTime date)
	@safe {
		this.name = name;
		this.sha = sha;
		this.date = BsonDate(date);
	}
}

struct RepositoryFile {
	enum Type {
		directory,
		file
		// submodule
	}

	/// A commit where this file/directory has the specified properties, not neccessarily the last change.
	string commitSha;
	/// Absolute path of the file in the repository.
	InetPath path;
	/// Size of the file or size_t.max if unknown.
	size_t size = size_t.max;
	/// Type of the entry (directory or file)
	Type type;
}

package Json readJson(string url, bool sanitize = false, bool cache_priority = false,
	RequestModifier request_modifier = null)
@safe {
	import dubregistry.internal.utils : black;

	Json ret;
	logDiagnostic("Getting JSON response from %s", url.black);
	Exception ex;
	foreach (i; 0 .. 2) {
		try {
			downloadCached(url, (scope input){
				scope (failure) clearCacheEntry(url);
				auto text = input.readAllUTF8(sanitize);
				ret = parseJsonString(text);
			}, cache_priority, request_modifier);
			return ret;
		} catch (FileNotFoundException e) {
			throw e;
		} catch (Exception e) {
			logDiagnostic("Failed to parse downloaded JSON document (attempt #%s): %s", i+1, e.msg);
			ex = e;
		}
	}
	throw new Exception(format("Failed to read JSON from %s: %s", url.black, ex.msg), __FILE__, __LINE__, ex);
}

private {
	Repository[DbRepository] s_repositories;
	RepositoryProvider[string] s_repositoryProviders;
}
