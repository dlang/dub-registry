/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module app;

import dubregistry.dbcontroller;
import dubregistry.mirror;
import dubregistry.repositories.bitbucket;
import dubregistry.repositories.github;
import dubregistry.registry;
import dubregistry.web;
import dubregistry.api;

import std.algorithm : sort;
import std.file;
import std.path;
import userman.web;
import vibe.d;


Task s_checkTask;
DubRegistry s_registry;
DubRegistryWebFrontend s_web;
string s_mirror;

void startMonitoring()
{
	void monitorNewVersions()
	{
		while(true){
			if (s_mirror.length) s_registry.mirrorRegistry(URL(s_mirror));
			else s_registry.checkForNewVersions();
			sleep(30.minutes());
		}
	}
	s_checkTask = runTask(&monitorNewVersions);
}

shared static this()
{
	setLogFile("log.txt", LogLevel.diagnostic);

	string hostname = "code.dlang.org";

	readOption("mirror", &s_mirror, "URL of a package registry that this instance should mirror (WARNING: will overwrite local database!)");
	readOption("hostname", &hostname, "Domain name of this instance (default: code.dlang.org)");

	version (linux) {
		logInfo("Enforcing certificate trust.");
		HTTPClient.setTLSSetupCallback((ctx) {
			ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
			ctx.peerValidationMode = TLSPeerValidationMode.trustedCert;
		});
	}

	import dub.internal.utils : jsonFromFile;
	auto regsettingsjson = jsonFromFile(Path("settings.json"), true);
	auto ghuser = regsettingsjson["github-user"].opt!string;
	auto ghpassword = regsettingsjson["github-password"].opt!string;

	GithubRepository.register(ghuser, ghpassword);
	BitbucketRepository.register();

	auto router = new URLRouter;
	if (s_mirror.length) router.any("*", (req, res) { req.params["mirror"] = s_mirror; });
	router.get("*", (req, res) { if (!s_checkTask.running) startMonitoring(); });

	// VPM registry
	auto regsettings = new DubRegistrySettings;
	s_registry = new DubRegistry(regsettings);

	UserManController userdb;

	if (!s_mirror.length) {
		// user management
		auto udbsettings = new UserManSettings;
		udbsettings.serviceName = "DUB - The D package registry";
		udbsettings.serviceUrl = URL("http://code.dlang.org/");
		udbsettings.serviceEmail = "noreply@vibed.org";
		udbsettings.databaseURL = "mongodb://127.0.0.1:27017/vpmreg";
		udbsettings.requireAccountValidation = false;
		userdb = createUserManController(udbsettings);
	}

	// web front end
	s_web = router.registerDubRegistryWebFrontend(s_registry, userdb);
	router.registerDubRegistryAPI(s_registry);

	// start the web server
 	auto settings = new HTTPServerSettings;
	settings.hostName = hostname;
	settings.bindAddresses = ["127.0.0.1"];
	settings.port = 8005;
	settings.sessionStore = new MemorySessionStore;

	listenHTTP(settings, router);

	// poll github for new project versions
	startMonitoring();
}
