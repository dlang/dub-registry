/**
	Copyright: © 2025 Sönke Ludwig
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.forgejo;

import dubregistry.dbcontroller : DbRepository;
import dubregistry.repositories.repository;
import dubregistry.repositories.gitea;
import std.algorithm.searching : startsWith;
import vibe.inet.url : URL;


class ForgejoRepositoryProvider : GiteaRepositoryProvider {
@safe:

	private this(string token, string url)
	{
		if (!url.length) url = "https://codeberg.org/";
		super(token, url);
	}

	static void register(string token, string url)
	{
		auto h = new ForgejoRepositoryProvider(token, url);
		addRepositoryProvider("forgejo", h);
	}

	override bool parseRepositoryURL(URL url, out DbRepository repo)
	@safe {
		if (!super.parseRepositoryURL(url, repo))
			return false;

		repo.kind = "forgejo";
		return true;
	}

	override Repository getRepository(DbRepository repo)
	@safe {
		return new ForgejoRepository(repo.owner, repo.project, m_token, m_url);
	}
}


class ForgejoRepository : GiteaRepository {
@safe:

	this(string owner, string project, string auth_token, string url)
	{
		super(owner, project, auth_token, url);
		m_public = url.startsWith("https://codeberg.org/");
	}
}
