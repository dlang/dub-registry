import vibe.d;

import registry;

import userman.controller;

VpmRegistry s_registry;

void showHome(HttpServerRequest req, HttpServerResponse res)
{
	Json[] packages;
	foreach( pack; s_registry.availablePackages.sort )
		packages ~= s_registry.getPackageInfo(pack);
	res.renderCompat!("home.dt",
		HttpServerRequest, "req",
		Json[], "packages")(Variant(req), Variant(packages));
}

void showPackage(HttpServerRequest req, HttpServerResponse res)
{
	Json pack = s_registry.getPackageInfo(req.params["packname"]);
	if( pack == null ) return;

	res.renderCompat!("view_package.dt",
		HttpServerRequest, "req", 
		Json, "pack")(Variant(req), Variant(pack));
}

void showMyPackages(HttpServerRequest req, HttpServerResponse res, User user)
{
	res.renderCompat!("my_packages.dt",
		HttpServerRequest, "req",
		User, "user",
		VpmRegistry, "registry")(Variant(req), Variant(user), Variant(s_registry));
}

void showAddPackage(HttpServerRequest req, HttpServerResponse res, User user)
{
	res.renderCompat!("add_package.dt",
		HttpServerRequest, "req",
		User, "user",
		VpmRegistry, "registry")(Variant(req), Variant(user), Variant(s_registry));
}

void addPackage(HttpServerRequest req, HttpServerResponse res, User user)
{
	Json rep = Json.EmptyObject;
	rep["kind"] = req.form["kind"];
	rep["owner"] = req.form["owner"];
	rep["project"] = req.form["project"];
	s_registry.addPackage(rep, user._id);

	res.redirect("/my_packages");
}

void showRemovePackage(HttpServerRequest req, HttpServerResponse res, User user)
{
	res.renderCompat!("remove_package.dt",
		HttpServerRequest, "req",
		User, "user")(Variant(req), Variant(user));
}

void removePackage(HttpServerRequest req, HttpServerResponse res, User user)
{
	s_registry.removePackage(req.form["package"], user._id);
	res.redirect("/my_packages");
}

static this()
{
	setLogLevel(LogLevel.None);
	setLogFile("log.txt", LogLevel.Debug);

	auto router = new UrlRouter;

	// user management
	auto db = connectMongoDB("127.0.0.1");
	auto userdb = new UserDB(db, "vpmreg");
	auto userctrl = new UserDBController(userdb);
	userctrl.register(router, "/");

	// VPM registry
	auto vpmSettings = new VpmRegistrySettings;
	vpmSettings.pathPrefix = "/";
	vpmSettings.metadataPath = Path("public/packages");
	s_registry = new VpmRegistry(db, vpmSettings);
	auto regctrl = new VpmRegistryController(s_registry);
	regctrl.register(router);

	// user front end
	router.get("/", &showHome);
	router.get("/usage", staticTemplate!"usage.dt");
	router.get("/publish", staticTemplate!"publish.dt");
	router.get("/develop", staticTemplate!"develop.dt");
	router.get("/view_package/:packname", &showPackage);
	router.get("/my_packages", userctrl.auth(toDelegate(&showMyPackages)));
	router.get("/my_packages/add", userctrl.auth(toDelegate(&showAddPackage)));
	router.post("/my_packages/add", userctrl.auth(toDelegate(&addPackage)));
	router.post("/my_packages/remove", userctrl.auth(toDelegate(&showRemovePackage)));
	router.post("/my_packages/remove_confirm", userctrl.auth(toDelegate(&removePackage)));
	router.get("*", serveStaticFiles("./public"));
	
	// start the web server
 	auto settings = new HttpServerSettings;
	settings.hostName = "registry.vibed.org";
	settings.bindAddresses = ["127.0.0.1"];
	settings.port = 8005;
	settings.sessionStore = new MemorySessionStore;
	
	listenHttp(settings, router);

	// poll github for new project versions
	setTimer(dur!"minutes"(30), &s_registry.checkForNewVersions, true);
	runTask(&s_registry.checkForNewVersions);
}
