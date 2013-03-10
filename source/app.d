/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module app;

import dubregistry.dbcontroller;
import dubregistry.repositories.bitbucket;
import dubregistry.repositories.github;
import dubregistry.registry;
import dubregistry.web;

import std.algorithm : sort;
import std.file;
import std.path;
import userman.web;
import vibe.d;


Task s_checkTask;
DubRegistry s_registry;

void startMonitoring()
{
	void monitorNewVersions()
	{
		while(true){
			s_registry.checkForNewVersions();
			sleep(15.minutes());
		}
	}
	s_checkTask = runTask(&monitorNewVersions);
}

static this()
{
	setLogLevel(LogLevel.None);
	setLogFile("log.txt", LogLevel.Debug);

	GithubRepository.register();
	BitbucketRepository.register();

	auto router = new UrlRouter;
	router.get("*", (req, res){ if( !s_checkTask.running ) startMonitoring(); });

	// user management
	auto udbsettings = new UserManSettings;
	udbsettings.serviceName = "DUB registry";
	udbsettings.serviceUrl = Url("http://registry.vibed.org/");
	udbsettings.serviceEmail = "noreply@vibed.org";
	udbsettings.databaseName = "vpmreg";
	auto userdb = new UserManController(udbsettings);

	// VPM registry
	auto regsettings = new DubRegistrySettings;
	s_registry = new DubRegistry(regsettings);

	// web front end
	auto webfrontend = new DubRegistryWebFrontend(s_registry, userdb);
	webfrontend.register(router);
	
	// start the web server
 	auto settings = new HttpServerSettings;
	settings.hostName = "registry.vibed.org";
	settings.bindAddresses = ["127.0.0.1"];
	settings.port = 8005;
	settings.sessionStore = new MemorySessionStore;
	
	listenHttp(settings, router);

	// poll github for new project versions
	startMonitoring();
}
