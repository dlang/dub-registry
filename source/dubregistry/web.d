/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.web;

import dubregistry.dbcontroller;
import dubregistry.repositories.bitbucket;
import dubregistry.repositories.github;
import dubregistry.registry;
import dubregistry.viewutils; // dummy import to make rdmd happy

import dub.semver;
import std.algorithm : sort, startsWith;
import std.array;
import std.file;
import std.path;
import std.string;
import userman.web;
import vibe.d;


DubRegistryWebFrontend registerDubRegistryWebFrontend(URLRouter router, DubRegistry registry, UserManController userman)
{
	DubRegistryWebFrontend webfrontend;
	if (userman) {
		auto ff = new DubRegistryFullWebFrontend(registry, userman);
		webfrontend = ff;
		router.registerWebInterface(ff);
		router.registerUserManWebInterface(userman);
	} else {
		webfrontend = new DubRegistryWebFrontend(registry, userman);
		router.registerWebInterface(webfrontend);
	}
	router.get("*", serveStaticFiles("./public"));
	return webfrontend;
}

class DubRegistryWebFrontend {
	protected {
		DubRegistry m_registry;
		UserManController m_userman;
		Category[] m_categories;
		Category[string] m_categoryMap;
	}

	this(DubRegistry registry, UserManController userman)
	{
		m_registry = registry;
		m_userman = userman;
		updateCategories();
	}

	@path("/")
	void getHome(string sort = "updated", string category = null)
	{
		static import std.algorithm.sorting;
		import std.algorithm.searching : any;

		// collect the package list
		auto packapp = appender!(Json[])();
		packapp.reserve(200);
		if (category.length) {
			foreach (pname; m_registry.availablePackages) {
				auto pack = m_registry.getPackageInfo(pname);
				foreach (c; pack["categories"]) {
					if (c.get!string.startsWith(category)) {
						packapp.put(pack);
						break;
					}
				}
			}
		} else {
			foreach (pack; m_registry.availablePackages)
				packapp.put(m_registry.getPackageInfo(pack));
		}
		auto packages = packapp.data;

		// sort by date of last version
		string getDate(Json p) {
			if( p.type != Json.Type.Object || "versions" !in p ) return null;
			if( p["versions"].length == 0 ) return null;
			return p["versions"][p["versions"].length-1]["date"].get!string;
		}
		SysTime getDateAdded(Json p) {
			return SysTime.fromISOExtString(p["dateAdded"].get!string);
		}
		bool compare(Json a, Json b) {
			bool a_has_ver = a["versions"].get!(Json[]).any!(v => !v["version"].get!string.startsWith("~"));
			bool b_has_ver = b["versions"].get!(Json[]).any!(v => !v["version"].get!string.startsWith("~"));
			if (a_has_ver != b_has_ver) return a_has_ver;
			return getDate(a) > getDate(b);
		}
		switch (sort) {
			default: std.algorithm.sorting.sort!((a, b) => compare(a, b))(packages); break;
			case "name": std.algorithm.sorting.sort!((a, b) => a["name"] < b["name"])(packages); break;
			case "added": std.algorithm.sorting.sort!((a, b) => getDateAdded(a) > getDateAdded(b))(packages); break;
		}

		auto categories = m_categories;
		auto categoryMap = m_categoryMap;
		render!("home.dt", categories, categoryMap, packages);
	}

	// compatibility route
	void getAvailable(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.redirect("/packages/index.json");
	}

	@path("/packages/index.json")
	void getPackages(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.writeJsonBody(m_registry.availablePackages.array);
	}

	@path("/view_package/:packname")
	void getRedirectViewPackage(string _packname)
	{
		redirect("/packages/"~_packname);
	}

	@path("/packages/:packname")
	void getPackage(HTTPServerRequest req, HTTPServerResponse res, string _packname)
	{
		getPackageVersion(req, res, _packname, null);
	}

	@path("/packages/:packname/:version")
	void getPackageVersion(HTTPServerRequest req, HTTPServerResponse res, string _packname, string _version)
	{
		import std.algorithm : canFind;

		auto pname = _packname;
		auto ver = _version.replace(" ", "+");
		string ext;

		if (_version.length) {
			if (ver.endsWith(".zip")) ext = "zip", ver = ver[0 .. $-4];
			else if( ver.endsWith(".json") ) ext = "json", ver = ver[0 .. $-5];
		} else {
			if (pname.endsWith(".json")) {
				pname = pname[0 .. $-5];
				ext = "json";
			}
		}

		Json packageInfo, versionInfo;
		if (!getPackageInfo(pname, ver, packageInfo, versionInfo))
			return;

		User user;
		if (m_userman) user = m_userman.getUser(User.ID.fromString(packageInfo["owner"].get!string));

		if (ext == "zip") {
			if (pname.canFind(":")) return;

			// This log line is a weird workaround to make otherwise undefined Json fields
			// available. Smells like a compiler bug.
			logDebug("%s %s", packageInfo["id"].toString(), versionInfo["url"].toString());

			// add download to statistic
			m_registry.addDownload(BsonObjectID.fromString(packageInfo["id"].get!string), ver, req.headers.get("User-agent", null));
			if (versionInfo["url"].get!string.length > 0) {
				// redirect to hosting service specific URL
				redirect(versionInfo["url"].get!string);
			} else {
				// directly forward from hoster
				res.headers["Content-Disposition"] = "attachment; filename=\""~pname~"-"~(ver.startsWith("~") ? ver[1 .. $] : ver) ~ ".zip\"";
				m_registry.downloadPackageZip(pname, ver.startsWith("~") ? ver : "v"~ver, (scope data) {
					res.writeBody(data, "application/zip");
				});
			}
		} else if (ext == "json") {
			if (pname.canFind(":")) return;
			res.writeJsonBody(_version.length ? versionInfo : packageInfo);
		} else {
			auto gitVer = versionInfo["version"].get!string;
			gitVer = gitVer.startsWith("~") ? gitVer[1 .. $] : "v"~gitVer;
			string urlFilter(string url, bool is_image)
			{
				if (url.startsWith("http://") || url.startsWith("https://"))
					return url;

				if (auto pr = "repository" in packageInfo) {
					auto owner = (*pr)["owner"].get!string;
					auto project = (*pr)["project"].get!string;
					switch ((*pr)["kind"].get!string) {
						default: return url;
						// TODO: BitBucket + GitLab
						case "github":
							if (is_image) return format("https://github.com/%s/%s/raw/%s/%s", owner, project, gitVer, url);
							else return format("https://github.com/%s/%s/blob/%s/%s", owner, project, gitVer, url);
					}
				}

				return url;
			}

			auto packageName = pname;
			render!("view_package.dt", packageName, user, packageInfo, versionInfo, urlFilter);
		}
	}

	private bool getPackageInfo(string pack_name, string pack_version, out Json pkg_info, out Json ver_info)
	{
		auto ppath = pack_name.urlDecode().split(":");

		pkg_info = m_registry.getPackageInfo(ppath[0]);
		if (pkg_info.type == Json.Type.null_) return false;

		if (pack_version.length) {
			foreach (v; pkg_info["versions"]) {
				if (v["version"].get!string == pack_version) {
					ver_info = v;
					break;
				}
			}
			if (ver_info.type != Json.Type.Object) return false;
		} else {
			import dubregistry.viewutils;
			if (pkg_info["versions"].length == 0) return false;
			ver_info = getBestVersion(pkg_info["versions"]);
		}

		foreach (i; 1 .. ppath.length) {
			if ("subPackages" !in ver_info) return false;
			bool found = false;
			foreach (sp; ver_info["subPackages"]) {
				if (sp["name"] == ppath[i]) {
					Json newv = Json.emptyObject;
					// inherit certain fields
					foreach (field; ["version", "date", "license", "authors", "homepage"])
						if (auto pv = field in ver_info) newv[field] = *pv;
					// copy/overwrite the rest frmo the sub package
					foreach (string name, value; sp) newv[name] = value;
					ver_info = newv;
					found = true;
					break;
				}
			}
			if (!found) return false;
		}
		return true;
	}

	private void updateCategories()
	{
		auto catfile = openFile("categories.json");
		scope(exit) catfile.close();
		auto json = parseJsonString(catfile.readAllUTF8());

		Category[string] catmap;

		Category processNode(Json node, string[] path)
		{
			path ~= node["name"].get!string;
			auto cat = new Category;
			cat.name = path.join(".");
			cat.description = node["description"].get!string;
			if (path.length > 2)
				cat.indentedDescription = "\u00a0\u00a0\u00a0\u00a0".replicate(path.length-2) ~ "\u00a0└ " ~ cat.description;
			else if (path.length == 2)
				cat.indentedDescription = "\u00a0└ " ~ cat.description;
			else cat.indentedDescription = cat.description;
			foreach_reverse (i; 0 .. path.length)
				if (existsFile("public/images/categories/"~path[0 .. i+1].join(".")~".png")) {
					cat.imageName = path[0 .. i+1].join(".");
					break;
				}

			catmap[cat.name] = cat;

			if ("categories" in node)
				foreach (subcat; node["categories"])
					cat.subCategories ~= processNode(subcat, path);

			return cat;
		}

		Category[] cats;
		foreach (top_level_cat; json)
			cats ~= processNode(top_level_cat, null);

		m_categories = cats;
		m_categoryMap = catmap;
	}
}

class DubRegistryFullWebFrontend : DubRegistryWebFrontend {
	private {
		UserManWebAuthenticator m_usermanauth;
	}

	this(DubRegistry registry, UserManController userman)
	{
		super(registry, userman);
		m_usermanauth = new UserManWebAuthenticator(userman);
	}

	void querySearch(string q = "")
	{
		auto results = m_registry.searchPackages(q);
		auto queryString = q;
		render!("search_results.dt", queryString, results);
	}

	void getGettingStarted() { render!("getting_started.dt"); }
	void getAbout() { redirect("/getting_started"); }
	void getUsage() { redirect("/getting_started"); }

	void getPublish() { render!("publish.dt"); }
	void getDevelop() { render!("develop.dt"); }

	@path("/package-format")
	void getPackageFormat(string lang = null)
	{
		switch (lang) {
			default: redirect("package-format?lang=json"); break;
			case "json": render!("package_format_json.dt"); break;
			case "sdl": render!("package_format_sdl.dt"); break;
		}
	}

	private auto downloadInfo()
	{
		static struct DownloadFile {
			string fileName;
			string platformCaption;
			string typeCaption;
		}

		static struct DownloadVersion {
			string id;
			DownloadFile[][string] files;
		}

		static struct Info {
			DownloadVersion[] versions;
			string latest = "";

			void addFile(string ver, string platform, string filename)
			{

				auto df = DownloadFile(filename);
				switch (platform) {
					default:
						auto pts = platform.split("-");
						df.platformCaption = format("%s%s (%s)", pts[0][0 .. 1].toUpper(), pts[0][1 .. $], pts[1].replace("_", "-").toUpper());
						break;
					case "osx-x86": df.platformCaption = "OS X (X86)"; break;
					case "osx-x86_64": df.platformCaption = "OS X (X86-64)"; break;
				}

				if (filename.endsWith(".tar.gz")) df.typeCaption = "binary tarball";
				else if (filename.endsWith(".zip")) df.typeCaption = "zipped binaries";
				else if (filename.endsWith(".rpm")) df.typeCaption = "binary RPM package";
				else if (filename.endsWith("setup.exe")) df.typeCaption = "installer";
				else df.typeCaption = "Unknown";

				foreach(ref v; versions)
					if( v.id == ver ){
						v.files[platform] ~= df;
						return;
					}
				DownloadVersion dv = DownloadVersion(ver);
				dv.files[platform] = [df];
				versions ~= dv;
				if (!isPreReleaseVersion(ver) && (latest.empty || compareVersions(ver, latest) > 0))
					latest = ver;
			}
		}

		Info info;

		if (!"public/files".exists || !"public/files".isDir)
			return info;

		import std.regex;
		Regex!char[][string] platformPatterns;
		platformPatterns["windows-x86"] = [
			regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.*))?(?:-setup\\.exe|-windows-x86\\.zip)$")
		];
		platformPatterns["linux-x86_64"] = [
			regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-linux-x86_64\\.tar\\.gz$"),
			regex("^dub-(?P<version>[^-]+)-(?:0\\.(?P<prerelease>.+)|[^0].*)\\.x86_64\\.rpm$")
		];
		platformPatterns["linux-x86"] = [
			regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-linux-x86\\.tar\\.gz$"),
			regex("^dub-(?P<version>[^-]+)-(?:0\\.(?P<prerelease>.+)|[^0].*)\\.x86\\.rpm$")
		];
		platformPatterns["linux-arm"] = [
			regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-linux-arm\\.tar\\.gz$"),
			regex("^dub-(?P<version>[^-]+)-(?:0\\.(?P<prerelease>.+)|[^0].*)\\.arm\\.rpm$")
		];
		platformPatterns["osx-x86_64"] = [
			regex("^dub-(?P<version>[^-]+)(?:-(?P<prerelease>.+))?-osx-x86_64\\.tar\\.gz$"),
		];

		foreach(de; dirEntries("public/files", "*.*", SpanMode.shallow)) {
			auto name = Path(de.name).head.toString();

			foreach (platform, rexes; platformPatterns) {
				foreach (rex; rexes) {
					auto match = match(name, rex).captures;//matchFirst(name, rex);
					if (match.empty) continue;
					auto ver = match["version"] ~ (match["prerelease"].length ? "-" ~ match["prerelease"] : "");
					if (!ver.isValidVersion()) continue;
					info.addFile(ver, platform, name);
				}
			}
		}

		info.versions.sort!((a, b) => vcmp(a.id, b.id))();
		return info;
	}

	void getDownload()
	{
		auto info = downloadInfo();
		render!("download.dt", info);
	}

	@path("/download/LATEST")
	void getLatest(HTTPServerResponse res)
	{
		auto info = downloadInfo();
		enforceHTTP(!info.latest.empty, HTTPStatus.notFound, "No version available.");
		res.writeBody(info.latest);
	}


	@auth
	void getMyPackages(User _user)
	{
		auto user = _user;
		auto registry = m_registry;
		render!("my_packages.dt", user, registry);
	}

	@auth @path("/register_package")
	void getRegisterPackage(User _user, string kind = null, string owner = null, string project = null, string _error = null)
	{
		auto user = _user;
		string error = _error;
		auto registry = m_registry;
		render!("my_packages.register.dt", user, kind, owner, project, error, registry);
	}

	@auth @path("/register_package") @errorDisplay!getRegisterPackage
	void postRegisterPackage(string kind, string owner, string project, User _user, bool ignore_fork = false)
	{
		DbRepository rep;
		rep.kind = kind;
		rep.owner = owner;
		rep.project = project;

		if (!ignore_fork) {
			auto info = m_registry.getRepositoryInfo(rep);
			if (info.isFork) {
				render!("my_packages.register.warn_fork.dt", kind, owner, project);
				return;
			}
		}

		m_registry.addPackage(rep, _user.id);
		redirect("/my_packages");
	}

	@auth @path("/my_packages/:packname")
	void getMyPackagesPackage(string _packname, User _user, string _error = null)
	{
		enforceUserPackage(_user, _packname);
		auto packageName = _packname;
		auto nfo = m_registry.getPackageInfo(packageName);
		if (nfo.type == Json.Type.null_) return;
		auto categories = m_categories;
		auto registry = m_registry;
		auto user = _user;
		auto error = _error;
		render!("my_packages.package.dt", packageName, categories, user, registry, error);
	}

	@auth @path("/my_packages/:packname/update")
	void postUpdatePackage(string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);
		m_registry.triggerPackageUpdate(_packname);
		redirect("/my_packages/"~_packname);
	}

	@auth @path("/my_packages/:packname/remove")
	void postShowRemovePackage(string _packname, User _user)
	{
		auto packageName = _packname;
		auto user = _user;
		enforceUserPackage(user, packageName);
		render!("my_packages.remove.dt", packageName, user);
	}

	@auth @path("/my_packages/:packname/remove_confirm")
	void postRemovePackage(string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);
		m_registry.removePackage(_packname, _user.id);
		redirect("/my_packages");
	}

	@auth @path("/my_packages/:packname/set_categories")
	void postSetPackageCategories(string[] categories, string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);
		string[] uniquecategories;
		outer: foreach (cat; categories) {
			if (!cat.length) continue;
			foreach (j, ec; uniquecategories) {
				if (cat.startsWith(ec)) continue outer;
				if (ec.startsWith(cat)) {
					uniquecategories[j] = cat;
					continue outer;
				}
			}
			uniquecategories ~= cat;
		}
		m_registry.setPackageCategories(_packname, uniquecategories);

		redirect("/my_packages/"~_packname);
	}

	@auth @path("/my_packages/:packname/set_repository") @errorDisplay!getMyPackagesPackage
	void postSetPackageRepository(string kind, string owner, string project, string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);

		DbRepository rep;
		rep.kind = kind;
		rep.owner = owner;
		rep.project = project;
		m_registry.setPackageRepository(_packname, rep);

		redirect("/my_packages/"~_packname);
	}

	@path("/docs/commandline")
	void getCommandLineDocs()
	{
		import dub.commandline;
		auto commands = getCommands();
		render!("docs.commandline.dt", commands);
	}

	private void enforceUserPackage(User user, string package_name)
	{
		enforceHTTP(m_registry.isUserPackage(user.id, package_name), HTTPStatus.forbidden, "You don't have access rights for this package.");
	}

	// Attribute for authenticated routes
	private enum auth = before!performAuth("_user");
	mixin PrivateAccessProxy;

	private User performAuth(HTTPServerRequest req, HTTPServerResponse res)
	{
		return m_usermanauth.performAuth(req, res);
	}
}

final class Category {
	string name, description, indentedDescription, imageName;
	Category[] subCategories;
}
