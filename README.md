DUB registry
============

![vibe.d logo](public/images/logo-small.png) Online registry for [dub](https://github.com/dlang/dub/) packages, see <http://code.dlang.org/>.

[![Build Status](https://travis-ci.org/dlang/dub-registry.svg)](https://travis-ci.org/dlang/dub-registry)

[![Deploy](https://www.herokucdn.com/deploy/button.png)](https://heroku.com/deploy)

How to build & run locally
--------------------------

Requirements:
- OpenSSL
- MongoDB

```
dub
```

Running as a mirror
-------------------

```
dub -- --mirror=https://code.dlang.org
```

GitHub/GitLab API
-----------------

By default the GitHub/GitLab update cron job will use anonymous authentication on your local machine. As GitHub's API without authentication is quite rate-limited, you probably want to use authenticated API requests.
You can do so by creating a `settings.json` in the root folder of the dub-registry and adding credentials for the needed APIs:

```json
{
	"github-user": "<your-fancy-user-name>",
	"github-password": "<your-fancy-password>",
	"gitlab-url": "https://gitlab.com/",
	"gitlab-auth": "<gitlab-api-token from https://gitlab.com/profile/personal_access_tokens>",
	"bitbucket-user": "<your-fancy-user-name>",
	"bitbucket-password": "<your-fancy-password>"
}
```

It's recommended to create a separate account for the DUB registry GitHub authentication. Equally, if no GitLab packages are used in your local repository, no GitLab authentication is needed.

### SECURITY NOTICE

Development versions prior to 2.3.0 were leaking the GitLab private token in error messages shown to the user. Please make sure to use the latest version along with a freshly generated token.

Running without the cron job
----------------------------

For local development it's often useful to disable the cron job, you can do so with the `--no-monitoring` flag:

```
dub -- --no-monitoring
```

Importing a one-time snapshot from the registry
-----------------------------------------------

You can download a dump of all packages and import it into your local registry for development:

```
curl https://code.dlang.org/api/packages/dump | gunzip > mirror.json
dub -- --mirror=mirror.json
```

Starting the registry with `mirror.json` will import all packages within the JSON file.
Once all packages have been imported, you can start the registry as you normally would:

```
dub
```

And you should notice that it now contains all packages which are listed on code.dlang.org

Note that `--mirror=mirror.json` and `--mirror=https://code.dlang.org` are very similar and the `mirror.json` is only preferred for local development because it allows to easily nuke the entire mongo database and re-initialize it without needing any connection to the internet.

Deploy your private dub-registry with Docker
--------------------------------------------

The [dlangcommunity/dub-registry](https://hub.docker.com/r/dlangcommunity/dub-registry/) Docker image is available for an easy setup:

```
docker run --rm -ti -p 9095:9095 -v $DUB_REGISTRY_HOME:/bitnami -v $DUB_REGISTRY_HOME:/dub dlang-community/dub-registry
```

This will run both `mongodb` and `dub-registry` while persisting the database in the `$DUB_REGISTRY_HOME` location. The registry is accessible at http://127.0.0.1:9095

To run it as a daemon and make it auto-restart use:

```
docker run -d --restart=always -ti -p 9095:9095 -v $DUB_REGISTRY_HOME:/bitnami -v $DUB_REGISTRY_HOME:/dub dlang-community/dub-registry
```

The registry can be configured by adding the `settings.json` file in `$DUB_REGISTRY_HOME` folder.

Staging server
--------------

An auto-deployed version of `master` can be found at https://dub-registry-staging.herokuapp.com.

FAQ: I'm getting an "undefined reference to 'SSLv23_client_method'"
-------------------------------------------------------------------

Link with OpenSSL 1.1:

```
dub --override-config="vibe-d:tls/openssl-1.1"
```
