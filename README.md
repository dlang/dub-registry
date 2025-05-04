DUB registry
============

![vibe.d logo](public/images/logo-small.png) Online registry for [dub](https://github.com/dlang/dub/) packages, see <http://code.dlang.org/>.

[![Deploy](https://www.herokucdn.com/deploy/button.png)](https://www.heroku.com/deploy?template=https://github.com/dlang/dub-registry)

How to build & run locally
--------------------------

Requirements:

- OpenSSL
- MongoDB

```console
dub
```

Running as a mirror
-------------------

```console
dub -- --mirror=https://code.dlang.org
```

GitHub/GitLab API
-----------------

By default the GitHub/GitLab update cron job will use anonymous authentication on your local machine. As GitHub's API without authentication is quite rate-limited, you probably want to use authenticated API requests.
You can do so by creating a `settings.json` in the root folder of the dub-registry and adding credentials for the needed APIs:

```json
{
	"github-auth": "<github-personal-access-token from https://github.com/settings/tokens>",
	"gitlab-url": "https://gitlab.com/",
	"gitlab-auth": "<gitlab-api-token from https://gitlab.com/-/profile/personal_access_tokens>",
	"bitbucket-user": "<your-fancy-user-name>",
	"bitbucket-password": "<your-fancy-password>"
}
```

It's recommended to create a separate account for the DUB registry GitHub authentication. Equally, if no GitLab packages are used in your local repository, no GitLab authentication is needed.

It's absolutely recommended to create a personal access token without any extra permissions for your GitHub account instead of entering your password plain text into the settings file. You can generate an access token at https://github.com/settings/tokens (Settings -> Developer Settings -> Personal access tokens)

### SECURITY NOTICE

Development versions prior to 2.3.0 were leaking the GitLab private token in error messages shown to the user. Please make sure to use the latest version along with a freshly generated token.

Running without the cron job
----------------------------

For local development it's often useful to disable the cron job, you can do so with the `--no-monitoring` flag:

```console
dub -- --no-monitoring
```

Importing a one-time snapshot from the registry
-----------------------------------------------

You can download a dump of all packages and import it into your local registry for development:

```console
curl https://code.dlang.org/api/packages/dump > mirror.json
dub -- --mirror=mirror.json
```

Starting the registry with `mirror.json` will import all packages within the JSON file.
Once all packages have been imported, you can start the registry as you normally would:

```console
dub
```

And you should notice that it now contains all packages which are listed on code.dlang.org

Note that `--mirror=mirror.json` and `--mirror=https://code.dlang.org` are very similar and the `mirror.json` is only preferred for local development because it allows to easily nuke the entire mongo database and re-initialize it without needing any connection to the internet.

Build/Running dub-registry with Docker
---------------------------------------

- Build:

```console
export DUB_REGISTRY_HOME=$PWD
docker compose build
```

- Run:

```console
docker compose up -d --remove-orphans
```

- Stop:

```console
docker compose down --remove-orphans
```

This will run both `mongodb` and `dub-registry` while persisting the database in the `$DUB_REGISTRY_HOME` location. The registry is accessible at http://127.0.0.1:9095

The registry can be configured by adding the `settings.json` file in `$DUB_REGISTRY_HOME` folder.
