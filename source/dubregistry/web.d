/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.web;

import dubregistry.dbcontroller;
import dubregistry.internal.utils;
import dubregistry.repositories.bitbucket;
import dubregistry.repositories.github;
import dubregistry.registry;
import dubregistry.viewutils; // dummy import to make rdmd happy

import dub.semver;
import std.algorithm : sort, startsWith, splitter;
import std.array;
import std.file;
import std.path;
import std.string;
import userman.web;
import userman.db.controller : UserManController;
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
		static struct CachedPackageSlot {
			static struct Version {
				string version_;
				SysTime date;
			}

			BsonObjectID id;
			string name;
			DbPackageStats stats;
			string[] categories;
			Version[] versions;
			@property SysTime dateAdded() { return id.timeStamp; }
		}

		DubRegistry m_registry;
		UserManController m_userman;
		Category[] m_categories;
		Category[string] m_categoryMap;
		CachedPackageSlot[] m_packages;
	}

	this(DubRegistry registry, UserManController userman)
	{
		m_registry = registry;
		m_userman = userman;
		updateCategories();
		updatePackageList();
		setTimer(30.seconds, &updatePackageList, true);
	}

	private auto searchForPackages(string sort = "updated", string category = null, ulong skip = 0, ulong limit = 20)
	{
		import std.algorithm.comparison : min;
		import std.algorithm.iteration : filter, map;
		import std.typecons : tuple;

		static import std.algorithm.sorting;
		import std.algorithm.searching : any;

		CachedPackageSlot[] packages;
		if (category.length) {
			packages = m_packages
				.filter!(p => p.categories.any!(c => c.startsWith(category)))
				.array;
		} else {
			packages = m_packages.dup;
		}
		auto pcount = packages.length;

		// sort by date of last version
		SysTime getDate(in ref CachedPackageSlot p) {
			if (p.versions.length == 0) return SysTime(0, UTC());
			return p.versions[$-1].date;
		}
		bool compare(in ref CachedPackageSlot a, in ref CachedPackageSlot b) {
			bool a_has_ver = a.versions.any!(v => !v.version_.startsWith("~"));
			bool b_has_ver = b.versions.any!(v => !v.version_.startsWith("~"));
			if (a_has_ver != b_has_ver) return a_has_ver;
			return getDate(a) > getDate(b);
		}
		switch (sort) {
			case "name": std.algorithm.sorting.sort!((a, b) => a.name < b.name)(packages); break;
			case "score": std.algorithm.sorting.sort!((a, b) => a.stats.score > b.stats.score)(packages); break;
			case "added": std.algorithm.sorting.sort!((a, b) => a.dateAdded > b.dateAdded)(packages); break;
			case "updated":
			default: std.algorithm.sorting.sort!compare(packages); break;
		}
		// TODO: No need to use untyped Json
		static struct Package { DbPackageStats stats; Json _; alias _ this; }

		// limit package list to current page
		packages = packages[min(skip, $) .. min(skip + limit, $)];

		// collect package infos
		Json[string] infos;
		foreach (p; m_registry.getPackageInfos(packages.map!(p => p.name).array))
			infos[p.info["name"].opt!string] = p.info;

		return tuple(packages.map!(p => Package(p.stats, infos.get(p.name, Json.init))).array, pcount);

	}

	void search(string sort = "updated", string category = null, ulong skip = 0, ulong limit = 20)
	{
		auto packages = searchForPackages(sort, category, skip, limit);

		static struct Info {
			typeof(searchForPackages()[0]) packages;
			size_t packageCount;
			ulong skip;
			ulong limit;
			Category[] categories;
			Category[string] categoryMap;
		}

		Info info = {
			packageCount: packages[1],
			packages: packages[0],
			skip: skip,
			limit: limit,
			categories: m_categories,
			categoryMap: m_categoryMap,
		};

		render!("home.dt", info);
	}


	@path("/")
	void getHome(string sort = "updated", string category = null, ulong skip = 0, ulong limit = 20)
	{
		if (request.requestURI != "/")
			return search(sort, category, skip, limit);

		limit = 5;
		auto topScored = searchForPackages("score", null, 0, limit)[0];
		auto topAdded = searchForPackages("added", null, 0, limit)[0];
		auto topUpdated = searchForPackages("updated", null, 0, limit)[0];

		static struct Info {
			size_t packageCount;
			Category[] categories;
			Category[string] categoryMap;
		}
		Info info = {
			packageCount: m_packages.length,
			categories: m_categories,
			categoryMap: m_categoryMap,
		};
		render!("start.dt", topScored, topAdded, topUpdated, info);
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

	@path("/packages/:packname/logo")
	void getPackageLogo(HTTPServerRequest req, HTTPServerResponse res, string _packname)
	{
		bdata_t rev, logo;
		logo = m_registry.getPackageLogo(_packname, rev);

		if (logo.length) {
			// TODO: add caching, etag (using rev), content-control, etc.
			res.writeBody(logo, "image/png");
		} else {
			bool acceptsSVG;
			// make sure requester actually supports svg, if a custom IDE or tool for fetching images is used it should only get png if it doesn't support svg.
			// if requester is an IDE sending Accept: */*, but not accepting SVG it's their own fault.
			foreach (accept; req.headers.get("Accept", "").splitter(",")) {
				if (accept.startsWith("image/*", "image/svg", "*/*", "*/svg")) {
					acceptsSVG = true;
					break;
				}
			}
			auto settings = new HTTPFileServerSettings();
			if (acceptsSVG)
				sendFile(req, res, NativePath("public/images/default-logo.svg"), settings);
			else
				sendFile(req, res, NativePath("public/images/default-logo.png"), settings);
		}
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

		PackageInfo packinfo;
		PackageVersionInfo verinfo;
		if (!getPackageInfo(pname, ver, packinfo, verinfo))
			return;

		auto packageInfo = packinfo.info;
		auto versionInfo = verinfo.info;

		if (ext == "zip") {
			if (pname.canFind(":")) return;

			// This log line is a weird workaround to make otherwise undefined Json fields
			// available. Smells like a compiler bug.
			logDebug("%s %s", packageInfo["id"].toString(), verinfo.downloadURL);

			// add download to statistic
			m_registry.addDownload(BsonObjectID.fromString(packageInfo["id"].get!string), ver, req.headers.get("User-agent", null));
			if (verinfo.downloadURL.length > 0) {
				// redirect to hosting service specific URL
				redirect(verinfo.downloadURL);
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
			userman.db.controller.User user;
			if (m_userman) {
				try user = m_userman.getUser(User.ID.fromString(packageInfo["owner"].get!string));
				catch (Exception e) {
					logDebug("Failed to get owner '%s' for %s %s: %s",
						packageInfo["owner"].get!string, pname, ver, e.msg);
				}
			}

			auto gitVer = verinfo.version_;
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
							else return format("https://github.com/%s/%s/blob/%s/%s", owner, project, gitVer, url.startsWith("#") ? "README.md" ~ url : url);
					}
				}

				return url;
			}

			auto packageName = pname;
			auto registry = m_registry;
			auto readmeContents = m_registry.getReadme(versionInfo, packageInfo["repository"].deserializeJson!DbRepository);
			//auto sampleURLs = ["test1", "test2"]; /* TODO: actually make this array exist and embed samples generated from repository */
			string[] sampleURLs;
			auto activeTab = req.query.get("tab", "info");
			render!("view_package.dt",
					packageName,
					user,
					packinfo,
					versionInfo,
					readmeContents,
					sampleURLs,
					urlFilter,
					registry,
					activeTab,
			);
		}
	}

	@path("/packages/:packname/versions")
	void getAllPackageVersions(HTTPServerRequest req, HTTPServerResponse res, string _packname) {
		import std.algorithm : canFind;

		auto pname = _packname;

		auto ppath = _packname.urlDecode().split(":");
		auto packageInfo = m_registry.getPackageInfo(ppath[0]);

		auto packageName = pname;
		auto registry = m_registry;
		render!("view_package.versions.dt",
			packageName,
			packageInfo,
			registry);
	}

	private bool getPackageInfo(string pack_name, string pack_version, out PackageInfo pkg_info, out PackageVersionInfo ver_info) {
		import std.algorithm : map;
		auto ppath = pack_name.urlDecode().split(":");

		if (!ppath.length || !ppath[0].length) return false;

		pkg_info = m_registry.getPackageInfo(ppath[0]);
		if (pkg_info.info.type == Json.Type.null_) return false;

		if (pack_version.length) {
			foreach (ref v; pkg_info.versions) {
				if (v.version_ == pack_version) {
					ver_info = v;
					break;
				}
			}
			if (ver_info.info.type != Json.Type.object) return false;
		} else {
			import dubregistry.viewutils;
			if (pkg_info.versions.length == 0) return false;
			auto vidx = getBestVersionIndex(pkg_info.versions.map!(v => v.version_));
			ver_info = pkg_info.versions[vidx];
		}

		foreach (i; 1 .. ppath.length) {
			if ("subPackages" !in ver_info.info) return false;
			bool found = false;
			foreach (sp; ver_info.info["subPackages"]) {
				if (sp["name"] == ppath[i]) {
					Json newv = Json.emptyObject;
					// inherit certain fields
					foreach (field; ["version", "date", "license", "authors", "homepage"])
						if (auto pv = field in ver_info.info) newv[field] = *pv;
					// copy/overwrite the rest frmo the sub package
					foreach (string name, value; sp) newv[name] = value;
					ver_info.info = newv;
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
			Json icons = json["icons"];
			foreach_reverse (i; 0 .. path.length) {
				string dotPath = path[0 .. i+1].join(".");
				if (dotPath in icons) {
					cat.imageName = icons[dotPath].get!string;
					cat.imageDescription = path[0 .. i+1].join("/");
					break;
				}
			}

			catmap[cat.name] = cat;

			if ("categories" in node)
				foreach (subcat; node["categories"])
					cat.subCategories ~= processNode(subcat, path);

			return cat;
		}

		Category[] cats;
		foreach (top_level_cat; json["list"])
			cats ~= processNode(top_level_cat, null);

		m_categories = cats;
		m_categoryMap = catmap;
	}

	private void updatePackageList()
	{
		import std.algorithm.iteration : map;
		import core.memory : GC;
		() @trusted { GC.collect(); } ();


		// NOTE: all string/array data is reallocated to avoid pinning the
		//       underlying buffer that holds the MongoDB reply
		PackedStringAllocator strings;
		auto newpacks = appender!(CachedPackageSlot[]);
		newpacks.reserve(m_packages.length);
		foreach (p; m_registry.db.getPackageDump()) {
			CachedPackageSlot cp;
			cp.id = p._id;
			cp.name = strings.alloc(p.name);
			cp.stats = p.stats;
			cp.categories = p.categories.map!(c => strings.alloc(c)).array;
			cp.versions = p.versions
				.map!(v => CachedPackageSlot.Version(strings.alloc(v.version_), v.date))
				.array;
			newpacks ~= cp;
		}
		m_packages = newpacks.data;
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

	void getGettingStarted() { redirect("https://dub.pm/getting_started"); }
	void getAbout() { getGettingStarted(); }
	void getUsage() { getGettingStarted(); }
	void getAdvancedUsage() { redirect("https://dub.pm/getting_started"); }

	void getPublish() { redirect("https://dub.pm/publish"); }
	void getDevelop() { redirect("https://dub.pm/commandline"); }

	@path("/package-format")
	void getPackageFormat(string lang = null)
	{
		switch (lang) {
			default: redirect("https://dub.pm/package-format-json"); break;
			case "json": redirect("https://dub.pm/package-format-json"); break;
			case "sdl": redirect("https://dub.pm/package-format-sdl"); break;
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
			auto name = NativePath(de.name).head.name;

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
		redirect("https://github.com/dlang/dub/releases");
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
	void getRegisterPackage(User _user, string url = null, string _error = null)
	{
		auto user = _user;
		string error = _error;
		auto registry = m_registry;
		render!("my_packages.register.dt", user, url, error, registry);
	}

	@auth @path("/register_package") @errorDisplay!getRegisterPackage
	void postRegisterPackage(string url, User _user, bool ignore_fork = false)
	{
		import std.algorithm.searching : canFind;
		DbRepository rep;
		if (!url.canFind("://"))
			url = "https://" ~ url;
		rep.parseURL(URL.fromString(url));

		string kind = rep.kind;
		string owner = rep.owner;
		string project = rep.project;

		if (!ignore_fork) {
			auto info = m_registry.getRepositoryInfo(rep);
			if (info.isFork) {
				render!("my_packages.register.warn_fork.dt", url);
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
		auto nfo = m_registry.getPackageInfo(packageName, PackageInfoFlags.includeErrors);
		if (nfo.info.type == Json.Type.null_) return;
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

		redirect("/my_packages/"~_packname~"#categories");
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

		redirect("/my_packages/"~_packname~"#repository");
	}

	@auth @path("/my_packages/:packname/set_logo") @errorDisplay!getMyPackagesPackage
	void postSetLogo(scope HTTPServerRequest request, string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);
		const FilePart logo = request.files.get("logo");
		enforceBadRequest(logo != FilePart.init);
		auto info = getFileInfo(logo.tempPath);
		enforceBadRequest(info.size < 1024 * 1024, "Logo too big, at most 1 MB");
		auto renamed = NativePath(logo.tempPath.toString ~ logo.filename.name.extension);
		moveFile(logo.tempPath, renamed, true);
		scope (exit)
			removeFile(renamed);
		m_registry.setPackageLogo(_packname, renamed);

		redirect("/my_packages/"~_packname);
	}

	@auth @path("/my_packages/:packname/delete_logo")
	void postDeleteLogo(scope HTTPServerRequest request, string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);
		m_registry.unsetPackageLogo(_packname);

		redirect("/my_packages/"~_packname);
	}

	@auth @path("/my_packages/:packname/set_documentation_url") @errorDisplay!getMyPackagesPackage
	void postSetDocumentationURL(scope HTTPServerRequest request, string documentation_url, string _packname, User _user)
	{
		enforceUserPackage(_user, _packname);
		auto isValidURL = documentation_url.empty || documentation_url.startsWith("http://", "https://");
		enforceBadRequest(isValidURL, "URL is neither null nor starts with http:// or https://");
		m_registry.setDocumentationURL(_packname, documentation_url);
		redirect("/my_packages/"~_packname);
	}

	@path("/docs/commandline")
	void getCommandLineDocs()
	{
		redirect("https://dub.pm/commandline");
	}

	private void enforceUserPackage(User user, string package_name)
	{
		enforceHTTP(m_registry.isAdmin(user) || m_registry.isUserPackage(user.id, package_name),
			HTTPStatus.forbidden, "You don't have access rights for this package.");
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
	string name, description, indentedDescription, imageName, imageDescription;
	Category[] subCategories;
}
