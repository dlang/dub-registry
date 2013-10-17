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

import std.algorithm : sort, startsWith;
import std.array;
import std.file;
import std.path;
import std.string;
import userman.web;
import vibe.d;

class DubRegistryWebFrontend {
	private {
		struct Category { string name, description, indentedDescription; }

		DubRegistry m_registry;
		UserManWebInterface m_usermanweb;
		Category[] m_categories;
	}

	this(DubRegistry registry, UserManController userman)
	{
		m_registry = registry;
		m_usermanweb = new UserManWebInterface(userman);

		updateCategories();
	}

	void register(URLRouter router)
	{
		m_usermanweb.register(router);

		// user front end
		router.get("/", &showHome);
		router.get("/search", &showSearchResults);
		router.get("/about", staticTemplate!"usage.dt");
		router.get("/usage", staticRedirect("/about"));
		router.get("/download", &showDownloads);
		router.get("/publish", staticTemplate!"publish.dt");
		router.get("/develop", staticTemplate!"develop.dt");
		router.get("/package-format", staticTemplate!"package_format.dt");
		router.get("/available", &showAvailable);
		router.get("/packages/index.json", &showAvailable);
		router.get("/packages/:packname", &showPackage); // HTML or .json
		router.get("/packages/:packname/:version", &showPackageVersion); // HTML or .zip or .json
		router.get("/view_package/:packname", &redirectViewPackage);
		router.get("/my_packages", m_usermanweb.auth(toDelegate(&showMyPackages)));
		router.get("/my_packages/register", m_usermanweb.auth(toDelegate(&showAddPackage)));
		router.post("/my_packages/register", m_usermanweb.auth(toDelegate(&addPackage)));
		router.get("/my_packages/:packname", m_usermanweb.auth(toDelegate(&showMyPackagesPackage)));
		router.post("/my_packages/:packname/update", m_usermanweb.auth(toDelegate(&updatePackage)));
		router.post("/my_packages/:packname/remove", m_usermanweb.auth(toDelegate(&showRemovePackage)));
		router.post("/my_packages/:packname/remove_confirm", m_usermanweb.auth(toDelegate(&removePackage)));
		router.post("/my_packages/:packname/set_categories", m_usermanweb.auth(toDelegate(&updatePackageCategories)));
		router.get("*", serveStaticFiles("./public"));
	}

	void showAvailable(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.writeJsonBody(m_registry.availablePackages);
	}

	void showHome(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto browse_by = req.query.get("browse-by", "updated");
		auto category = req.query.get("category", null);


		// collect the package list
		auto packapp = appender!(Json[])();
		packapp.reserve(200);
		switch (browse_by) {
			default:
				foreach (pack; m_registry.availablePackages)
					packapp.put(m_registry.getPackageInfo(pack));
				break;
			case "category":
				foreach (pname; m_registry.availablePackages) {
					auto pack = m_registry.getPackageInfo(pname);
					foreach (c; pack.categories) {
						if (c.get!string.startsWith(category)) {
							packapp.put(pack);
							break;
						}
					}
				}
				break;
		}
		auto packages = packapp.data;

		// sort by date of last version
		string getDate(Json p){
			if( p.type != Json.Type.Object || "versions" !in p ) return null;
			if( p.versions.length == 0 ) return null;
			return p.versions[p.versions.length-1].date.get!string;
		}
		bool compare(Json a, Json b)
		{
			bool a_has_ver = a.versions.get!(Json[]).canFind!(v => !v["version"].get!string.startsWith("~"));
			bool b_has_ver = b.versions.get!(Json[]).canFind!(v => !v["version"].get!string.startsWith("~"));
			if (a_has_ver != b_has_ver) return a_has_ver;
			return getDate(a) > getDate(b);
		}
		sort!((a, b) => compare(a, b))(packages);

		res.renderCompat!("home.dt",
			HTTPServerRequest, "req",
			Category[], "categories",
			Json[], "packages")(req, m_categories, packages);
	}

	void showSearchResults(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto queryString = req.query.get("q", "");
		auto keywords = queryString.split();
		auto results = m_registry.searchPackages(keywords);
		res.render!("search_results.dt", req, queryString, results);
	}

	void showDownloads(HTTPServerRequest req, HTTPServerResponse res)
	{
		static struct DownloadFile {
			string fileName;
		}

		static struct DownloadVersion {
			string id;
			DownloadFile[string] files;
		}

		static struct Info {
			DownloadVersion[] versions;
			void addFile(string ver, string platform, string filename)
			{
				auto df = DownloadFile(filename);
				foreach(ref v; versions)
					if( v.id == ver ){
						v.files[platform] = df;
						return;
					}
				DownloadVersion dv = DownloadVersion(ver);
				dv.files[platform] = df;
				versions ~= dv;
			}
		}

		Info info;

		foreach(de; dirEntries("public/files", "*.{zip,gz,tgz,exe}", SpanMode.shallow)){
			auto name = Path(de.name).head.toString();
			auto basename = stripExtension(name);
			if( basename.endsWith(".tar") ) basename = basename[0 .. $-4];
			auto parts = basename.split("-");
			if( parts.length < 3 ) continue;
			if( parts[0] != "dub" ) continue;
			if( parts[2] == "setup" ) info.addFile(parts[1], "windows-x86", name);
			else if( parts.length == 4 ) info.addFile(parts[1], parts[2]~"-"~parts[3], name);
		}

		info.versions.sort!((a, b) => vcmp(a.id, b.id))();

		res.renderCompat!("download.dt",
			HTTPServerRequest, "req",
			Info*, "info")(req, &info);
	}

	void redirectViewPackage(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.redirect("/packages/"~req.params["packname"]);
	}

	void showPackage(HTTPServerRequest req, HTTPServerResponse res)
	{
		bool json = false;
		auto pname = req.params["packname"];
		if( pname.endsWith(".json") ){
			pname = pname[0 .. $-5];
			json = true;
		}

		Json pack = m_registry.getPackageInfo(pname);
		if( pack == null ) return;

		if( json ){
			res.writeJsonBody(pack);
		} else {
			res.renderCompat!("view_package.dt",
				HTTPServerRequest, "req", 
				Json, "pack",
				string, "ver")(req, pack, "");
		}
	}

	void showPackageVersion(HTTPServerRequest req, HTTPServerResponse res)
	{
		Json pack = m_registry.getPackageInfo(req.params["packname"]);
		if( pack == null ) return;

		auto ver = req.params["version"];
		string ext;
		if( ver.endsWith(".zip") ) ext = "zip", ver = ver[0 .. $-4];
		else if( ver.endsWith(".json") ) ext = "json", ver = ver[0 .. $-5];

		foreach( v; pack.versions )
			if( v["version"].get!string == ver ){
				if( ext == "zip" ){
					res.redirect(v.downloadUrl.get!string);
				} else if( ext == "json"){
					res.writeJsonBody(v);
				} else {
					res.renderCompat!("view_package.dt",
						HTTPServerRequest, "req", 
						Json, "pack",
						string, "ver")(req, pack, v["version"].get!string);
				}
				return;
			}
	}

	void showMyPackages(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		res.renderCompat!("my_packages.dt",
			HTTPServerRequest, "req",
			User, "user",
			DubRegistry, "registry")(req, user, m_registry);
	}

	void showMyPackagesPackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto packageName = req.params["packname"];
		auto nfo = m_registry.getPackageInfo(packageName);
		if (nfo.type == Json.Type.null_) return;
		enforceUserPackage(user, packageName);
		res.renderCompat!("my_packages.package.dt",
			HTTPServerRequest, "req",
			string, "packageName",
			Category[], "categories",
			User, "user",
			DubRegistry, "registry")(req, packageName, m_categories, user, m_registry);
	}

	void showAddPackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		res.renderCompat!("my_packages.register.dt",
			HTTPServerRequest, "req",
			User, "user",
			DubRegistry, "registry")(req, user, m_registry);
	}

	void addPackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		Json rep = Json.emptyObject;
		rep["kind"] = req.form["kind"];
		rep["owner"] = req.form["owner"];
		rep["project"] = req.form["project"];
		m_registry.addPackage(rep, user._id);

		res.redirect("/my_packages");
	}

	void updatePackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);
		m_registry.triggerPackageUpdate(pack_name);
		res.redirect("/my_packages/"~pack_name);
	}

	void showRemovePackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto packageName = req.params["packname"];
		enforceUserPackage(user, packageName);
		res.renderCompat!("my_packages.remove.dt",
			HTTPServerRequest, "req",
			string, "packageName",
			User, "user")(req, packageName, user);
	}

	void removePackage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);
		m_registry.removePackage(pack_name, user._id);
		res.redirect("/my_packages");
	}

	void updatePackageCategories(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		auto pack_name = req.params["packname"];
		enforceUserPackage(user, pack_name);
		string[] categories;
		outer: foreach (i; 0 .. 100) {
			auto pv = format("category%d", i) in req.form;
			if (!pv) break;
			string cat = *pv;
			if (cat.length == 0) continue;
			foreach (j, ec; categories) {
				if (cat.startsWith(ec)) continue outer;
				if (ec.startsWith(cat)) {
					categories[j] = cat;
					continue outer;
				}
			}
			categories ~= cat;
		}
		m_registry.setPackageCategories(pack_name, categories);
		res.redirect("/my_packages/"~pack_name);
	}

	private void enforceUserPackage(User user, string package_name)
	{
		// TODO!
	}

	private void updateCategories()
	{
		auto catfile = openFile("categories.json");
		scope(exit) catfile.close();
		auto json = parseJsonString(catfile.readAllUTF8());

		Category[] cats;
		void processNode(Json node, string[] path)
		{
			path ~= node.name.get!string;
			Category cat;
			cat.name = path.join(".");
			cat.description = node.description.get!string;
			if (path.length > 2)
				cat.indentedDescription = "\u00a0\u00a0\u00a0\u00a0".replicate(path.length-2) ~ "\u00a0└ " ~ cat.description;
			else if (path.length == 2)
				cat.indentedDescription = "\u00a0└ " ~ cat.description;
			else cat.indentedDescription = cat.description;
			cats ~= cat;
			if ("categories" in node)
				foreach (subcat; node.categories)
					processNode(subcat, path);
		}
		foreach (top_level_cat; json)
			processNode(top_level_cat, null);
		m_categories = cats;
	}
}
