/**
	Shared flags for OAuth UI. Kept separate so Diet templates can read them
	without importing the full OAuth module (avoids a userman.web cycle).
*/
module dubregistry.oauthflags;

/// True when a GitHub OAuth App is configured for website login.
__gshared bool githubOAuthEnabled;
