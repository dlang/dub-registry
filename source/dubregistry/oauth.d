/**
	OAuth 2.0 authorization-code + PKCE for native/CLI apps (RFC 8252)
	and optional GitHub OAuth login for the website.

	Copyright: © 2013-2026 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
*/
module dubregistry.oauth;

import dubregistry.config;
import dubregistry.internal.utils : generateRandomHash;
import dubregistry.oauthflags;
import dubregistry.oauthstore;

import core.time;
import std.algorithm : canFind, startsWith;
import std.array : appender;
import std.base64 : Base64URLNoPadding;
import std.conv : to;
import std.datetime.systime;
import std.datetime.timezone;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.string : icmp, indexOf, strip, toLower;
import std.typecons : Nullable;

import userman.api;
import userman.db.controller : UserManController;
import userman.web : createLocalUserManAPI;

import vibe.core.log;
import vibe.data.json;
import vibe.http.client;
import vibe.http.router;
import vibe.http.server;
import vibe.http.status;
import vibe.inet.url;
import vibe.stream.operations : readAllUTF8;
import vibe.textfilter.urlencode;


enum oauthAccessTokenTTL = 90.days;
enum oauthAuthCodeTTL = 5.minutes;
enum oauthDefaultClientId = "native";
enum oauthDefaultScope = "packages";

private __gshared string g_githubClientId;
private __gshared string g_githubClientSecret;
private __gshared string g_serviceURL;

/** Registers native-app OAuth and optional GitHub login routes.

	Must be called before the static-file catch-all.
*/
void registerDubRegistryOAuth(URLRouter router, UserManController userman,
	OAuthStore store, AppConfig appConfig)
{
	g_githubClientId = appConfig.ghoauthid;
	g_githubClientSecret = appConfig.ghoauthsecret;
	g_serviceURL = appConfig.serviceURL;
	githubOAuthEnabled = g_githubClientId.length > 0 && g_githubClientSecret.length > 0;

	auto oauth = new DubRegistryOAuth(userman, store);
	router.get("/oauth/authorize", (req, res) @trusted { oauth.getAuthorize(req, res); });
	router.post("/oauth/authorize", (req, res) @trusted { oauth.postAuthorize(req, res); });
	router.post("/oauth/token", (req, res) @trusted { oauth.postToken(req, res); });
	router.post("/oauth/revoke", (req, res) @trusted { oauth.postRevoke(req, res); });
	router.get("/login/github", (req, res) @trusted { oauth.getGitHubLogin(req, res); });
	router.get("/login/github/callback", (req, res) @trusted { oauth.getGitHubCallback(req, res); });
}

/** Returns the logged-in user for a valid Bearer token, or `Nullable.init`. */
Nullable!User tryBearerAuth(HTTPServerRequest req, UserManController userman, OAuthStore store)
{
	Nullable!User none;
	if (!store || !userman)
		return none;
	auto token = extractBearerToken(req);
	if (!token.length)
		return none;
	auto rec = store.findTokenHash(sha256Hex(token));
	if (rec.isNull)
		return none;
	try {
		auto api = createLocalUserManAPI(userman);
		auto user = api.users.get(User.ID.fromString(rec.get.userId));
		if (!user.active || user.banned)
			return none;
		none = user;
		return none;
	} catch (Exception e) {
		logDiagnostic("Bearer token user lookup failed: %s", e.msg);
		return Nullable!User.init;
	}
}

string extractBearerToken(HTTPServerRequest req)
@safe {
	return extractBearerToken(req.headers.get("Authorization", ""));
}

string extractBearerToken(string h)
@safe {
	if (h.length < 8)
		return null;
	auto space = h.indexOf(' ');
	if (space <= 0)
		return null;
	if (icmp(h[0 .. space], "Bearer") != 0)
		return null;
	auto tok = strip(h[space + 1 .. $]);
	return tok.length ? tok : null;
}

struct AuthorizeRequest {
	string responseType;
	string clientId = oauthDefaultClientId;
	string redirectUri;
	string state;
	string codeChallenge;
	string codeChallengeMethod;
	string scopeName = oauthDefaultScope;
}

AuthorizeRequest parseAuthorizeParams(scope HTTPServerRequest req)
@safe {
	string get(string key, string def = "")
	{
		if (req.method == HTTPMethod.POST) {
			auto fv = req.form.get(key, "");
			if (fv.length)
				return fv;
		}
		auto qv = req.query.get(key, def);
		return qv.length ? qv : def;
	}

	AuthorizeRequest ar;
	ar.responseType = get("response_type");
	ar.clientId = get("client_id", oauthDefaultClientId);
	ar.redirectUri = get("redirect_uri");
	ar.state = get("state");
	ar.codeChallenge = get("code_challenge");
	ar.codeChallengeMethod = get("code_challenge_method");
	ar.scopeName = get("scope", oauthDefaultScope);
	if (!ar.clientId.length)
		ar.clientId = oauthDefaultClientId;
	if (!ar.scopeName.length)
		ar.scopeName = oauthDefaultScope;
	return ar;
}

/** Loopback redirect URIs for native apps (RFC 8252 §7.3). */
bool isLoopbackRedirectURI(string uri)
@safe {
	if (!uri.length || uri.length > 512)
		return false;
	if (uri.canFind('\r') || uri.canFind('\n') || uri.canFind('\\'))
		return false;

	URL url;
	try url = URL(uri);
	catch (Exception)
		return false;

	if (url.schema != "http")
		return false;
	if (url.username.length || url.password.length)
		return false;

	auto host = url.host;
	if (host.length >= 2 && host[0] == '[' && host[$ - 1] == ']')
		host = host[1 .. $ - 1];
	if (host != "127.0.0.1" && host != "localhost" && host != "::1")
		return false;

	return true;
}

bool isValidClientId(string id)
@safe {
	import std.ascii : isAlphaNum;
	if (!id.length || id.length > 64)
		return false;
	foreach (dchar ch; id) {
		if (!ch.isAlphaNum && ch != '.' && ch != '_' && ch != '-')
			return false;
	}
	return true;
}

bool isValidPKCEVerifier(string verifier)
@safe {
	import std.ascii : isAlphaNum;
	if (verifier.length < 43 || verifier.length > 128)
		return false;
	foreach (dchar ch; verifier) {
		if (!ch.isAlphaNum && ch != '-' && ch != '.' && ch != '_' && ch != '~')
			return false;
	}
	return true;
}

bool isValidPKCEChallenge(string challenge)
@safe {
	import std.ascii : isAlphaNum;
	if (challenge.length < 43 || challenge.length > 128)
		return false;
	foreach (dchar ch; challenge) {
		if (!ch.isAlphaNum && ch != '-' && ch != '_')
			return false;
	}
	return true;
}

string pkceChallengeS256(string verifier)
@safe {
	auto digest = sha256Of(verifier);
	return Base64URLNoPadding.encode(digest[]).idup;
}

string sha256Hex(string data)
@safe {
	auto hex = toHexString(sha256Of(data));
	return hex[].idup;
}

bool isSafeLocalRedirect(string url)
@safe {
	if (!url.length)
		return false;
	if (url[0] != '/')
		return false;
	if (url.startsWith("//") || url.startsWith("/\\"))
		return false;
	if (url.canFind('\\') || url.canFind('\r') || url.canFind('\n'))
		return false;
	return true;
}

string validateAuthorizeRequest(const ref AuthorizeRequest ar)
@safe {
	if (ar.responseType != "code")
		return "response_type must be \"code\"";
	if (!isValidClientId(ar.clientId))
		return "invalid client_id";
	if (!isLoopbackRedirectURI(ar.redirectUri))
		return "redirect_uri must be an http loopback URI (127.0.0.1, localhost, or [::1])";
	if (ar.codeChallengeMethod != "S256")
		return "code_challenge_method must be S256";
	if (!isValidPKCEChallenge(ar.codeChallenge))
		return "invalid code_challenge";
	if (ar.scopeName != oauthDefaultScope)
		return "unsupported scope (only \"packages\" is allowed)";
	return null;
}

string appendQuery(string uri, string[string] params)
@safe {
	auto app = appender!string();
	app.put(uri);
	bool first = uri.indexOf('?') < 0;
	foreach (key, value; params) {
		app.put(first ? '?' : '&');
		first = false;
		app.put(urlEncode(key));
		app.put('=');
		app.put(urlEncode(value));
	}
	return app.data;
}

private string requestTarget(HTTPServerRequest req)
@safe {
	auto path = req.requestPath.toString();
	if (req.queryString.length)
		return path ~ "?" ~ req.queryString;
	return path;
}

private final class DubRegistryOAuth {
	private {
		UserManController m_userman;
		UserManAPI m_api;
		OAuthStore m_store;
	}

	this(UserManController userman, OAuthStore store)
	{
		m_userman = userman;
		m_api = createLocalUserManAPI(userman);
		m_store = store;
	}

	void getAuthorize(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto ar = parseAuthorizeParams(req);
		if (auto err = validateAuthorizeRequest(ar)) {
			auto error = err;
			res.statusCode = HTTPStatus.badRequest;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto userN = currentUser(req);
		if (userN.isNull) {
			res.redirect("/login?redirect=" ~ urlEncode(requestTarget(req)));
			return;
		}

		User user = userN.get;
		string error;
		res.render!("oauth.authorize.dt", req, ar, error, user);
	}

	void postAuthorize(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto ar = parseAuthorizeParams(req);
		if (auto err = validateAuthorizeRequest(ar)) {
			auto error = err;
			res.statusCode = HTTPStatus.badRequest;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto user = currentUser(req);
		if (user.isNull) {
			string[string] q;
			q["response_type"] = ar.responseType;
			q["client_id"] = ar.clientId;
			q["redirect_uri"] = ar.redirectUri;
			q["state"] = ar.state;
			q["code_challenge"] = ar.codeChallenge;
			q["code_challenge_method"] = ar.codeChallengeMethod;
			q["scope"] = ar.scopeName;
			res.redirect("/login?redirect=" ~ urlEncode(appendQuery("/oauth/authorize", q)));
			return;
		}
		if (!user.get.active || user.get.banned) {
			auto error = "This account cannot authorize applications.";
			res.statusCode = HTTPStatus.forbidden;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto allow = req.form.get("allow", "");
		if (allow != "1") {
			string[string] errq;
			errq["error"] = "access_denied";
			errq["error_description"] = "The user denied the request";
			if (ar.state.length)
				errq["state"] = ar.state;
			res.redirect(appendQuery(ar.redirectUri, errq));
			return;
		}

		auto code = generateRandomHash!32;
		OAuthAuthCode rec;
		rec.codeHash = sha256Hex(code);
		rec.userId = user.get.id.toString();
		rec.clientId = ar.clientId;
		rec.redirectUri = ar.redirectUri;
		rec.codeChallenge = ar.codeChallenge;
		rec.codeChallengeMethod = ar.codeChallengeMethod;
		rec.scopeName = ar.scopeName;
		rec.expiresAt = Clock.currTime(UTC()) + oauthAuthCodeTTL;
		m_store.putCode(rec);

		string[string] q;
		q["code"] = code;
		if (ar.state.length)
			q["state"] = ar.state;
		res.redirect(appendQuery(ar.redirectUri, q));
	}

	void postToken(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			auto grant = oauthParam(req, "grant_type");
			enforceOAuth(grant == "authorization_code", "unsupported_grant_type",
				"grant_type must be authorization_code", HTTPStatus.badRequest);

			auto code = oauthParam(req, "code");
			auto redirectUri = oauthParam(req, "redirect_uri");
			auto verifier = oauthParam(req, "code_verifier");
			auto clientId = oauthParam(req, "client_id", oauthDefaultClientId);
			if (!clientId.length)
				clientId = oauthDefaultClientId;

			enforceOAuth(code.length && redirectUri.length && verifier.length,
				"invalid_request", "code, redirect_uri and code_verifier are required",
				HTTPStatus.badRequest);
			enforceOAuth(isValidClientId(clientId), "invalid_client", "invalid client_id",
				HTTPStatus.badRequest);
			enforceOAuth(isValidPKCEVerifier(verifier), "invalid_request",
				"invalid code_verifier", HTTPStatus.badRequest);

			auto rec = m_store.takeCode(sha256Hex(code));
			enforceOAuth(!rec.isNull, "invalid_grant", "invalid or expired authorization code",
				HTTPStatus.badRequest);
			enforceOAuth(rec.get.redirectUri == redirectUri, "invalid_grant",
				"redirect_uri does not match", HTTPStatus.badRequest);
			enforceOAuth(rec.get.clientId == clientId, "invalid_grant",
				"client_id does not match", HTTPStatus.badRequest);
			enforceOAuth(pkceChallengeS256(verifier) == rec.get.codeChallenge,
				"invalid_grant", "PKCE verification failed", HTTPStatus.badRequest);

			auto accessToken = generateRandomHash!32;
			OAuthAccessToken tok;
			tok.tokenHash = sha256Hex(accessToken);
			tok.userId = rec.get.userId;
			tok.clientId = rec.get.clientId;
			tok.scopeName = rec.get.scopeName;
			tok.createdAt = Clock.currTime(UTC());
			tok.expiresAt = tok.createdAt + oauthAccessTokenTTL;
			m_store.putToken(tok);

			Json body = Json.emptyObject;
			body["access_token"] = accessToken;
			body["token_type"] = "Bearer";
			body["expires_in"] = oauthAccessTokenTTL.total!"seconds";
			body["scope"] = rec.get.scopeName;
			res.writeJsonBody(body);
		} catch (OAuthHTTPException e) {
			writeOAuthError(res, e);
		} catch (Exception e) {
			logWarn("OAuth token endpoint failed: %s", e.msg);
			writeOAuthError(res, new OAuthHTTPException("server_error",
				"token request failed", HTTPStatus.internalServerError));
		}
	}

	void postRevoke(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto token = oauthParam(req, "token");
		if (token.length)
			m_store.deleteToken(sha256Hex(token));
		res.statusCode = HTTPStatus.ok;
		res.writeBody("", "text/plain");
	}

	void getGitHubLogin(HTTPServerRequest req, HTTPServerResponse res)
	{
		if (!githubOAuthEnabled) {
			auto error = "GitHub login is not configured on this instance.";
			res.statusCode = HTTPStatus.serviceUnavailable;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto redirectTo = req.query.get("redirect", "");
		if (redirectTo.length && !isSafeLocalRedirect(redirectTo))
			redirectTo = "";

		if (!req.session)
			req.session = res.startSession();
		auto state = generateRandomHash!16;
		req.session.set("github_oauth_state", state);
		req.session.set("github_oauth_redirect", redirectTo);

		string[string] q;
		q["client_id"] = g_githubClientId;
		q["redirect_uri"] = githubCallbackURL();
		q["state"] = state;
		q["scope"] = "read:user user:email";
		res.redirect(appendQuery("https://github.com/login/oauth/authorize", q));
	}

	void getGitHubCallback(HTTPServerRequest req, HTTPServerResponse res)
	{
		if (!githubOAuthEnabled) {
			auto error = "GitHub login is not configured on this instance.";
			res.statusCode = HTTPStatus.serviceUnavailable;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto errCode = req.query.get("error", "");
		if (errCode.length) {
			auto error = "GitHub login was cancelled or failed (" ~ errCode ~ ").";
			res.statusCode = HTTPStatus.badRequest;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto state = req.query.get("state", "");
		auto code = req.query.get("code", "");
		auto sessState = req.session ? req.session.get!string("github_oauth_state", "") : "";
		if (!code.length || !state.length || !sessState.length || state != sessState) {
			auto error = "Invalid GitHub login callback. Please try again.";
			res.statusCode = HTTPStatus.badRequest;
			res.render!("oauth.error.dt", req, error);
			return;
		}

		auto redirectTo = req.session.get!string("github_oauth_redirect", "");
		req.session.remove("github_oauth_state");
		req.session.remove("github_oauth_redirect");

		try {
			auto user = loginOrRegisterFromGitHub(code);
			startUserSession(req, res, user);
			if (!isSafeLocalRedirect(redirectTo))
				redirectTo = "/";
			res.redirect(redirectTo);
		} catch (Exception e) {
			logWarn("GitHub OAuth login failed: %s", e.msg);
			auto error = "GitHub login failed: " ~ e.msg;
			res.statusCode = HTTPStatus.badGateway;
			res.render!("oauth.error.dt", req, error);
		}
	}

	private Nullable!User currentUser(HTTPServerRequest req)
	@safe {
		Nullable!User none;
		if (!req.session)
			return none;
		auto name = req.session.get!string("userName", "");
		if (!name.length)
			return none;
		try {
			none = m_api.users.getByName(name);
			return none;
		} catch (Exception)
			return Nullable!User.init;
	}

	private void startUserSession(HTTPServerRequest req, HTTPServerResponse res, User user)
	@safe {
		if (!req.session)
			req.session = res.startSession();
		req.session.set("userEmail", user.email);
		req.session.set("userName", user.name);
		req.session.set("userFullName", user.fullName);
		req.session.set("userID", user.id.toString());
	}

	private User loginOrRegisterFromGitHub(string code)
	{
		auto ghToken = exchangeGitHubCode(code);
		auto ghUser = githubAPI("https://api.github.com/user", ghToken);
		auto emails = githubAPI("https://api.github.com/user/emails", ghToken);

		string ghId;
		if (ghUser["id"].type == Json.Type.string)
			ghId = ghUser["id"].get!string;
		else
			ghId = ghUser["id"].to!string;
		auto login = ghUser["login"].opt!string;
		auto fullName = ghUser["name"].opt!string;
		if (!fullName.length)
			fullName = login;
		auto email = pickGitHubEmail(ghUser, emails);
		enforce(email.length, "GitHub account has no verified email address.");

		User user;
		bool found;
		try {
			user = m_api.users.getByEmail(email);
			found = true;
		} catch (Exception) {}

		if (!found) {
			auto username = sanitizeUserName(login, ghId);
			auto password = generateRandomHash!16;
			try {
				auto id = m_api.users.register(email, username, fullName, password);
				user = m_api.users.get(id);
			} catch (Exception e) {
				username = "gh-" ~ ghId;
				auto id = m_api.users.register(email, username, fullName, password);
				user = m_api.users.get(id);
			}
		}

		enforce(user.active, "This account is not yet activated.");
		enforce(!user.banned, "This account is banned.");
		m_userman.setProperty(user.id, "github_id", Json(ghId));
		return user;
	}
}

private string sanitizeUserName(string login, string ghId)
@safe {
	import std.ascii : isAlphaNum;
	auto app = appender!string();
	foreach (dchar ch; login.toLower) {
		if (ch.isAlphaNum || ch == '_')
			app.put(ch);
	}
	auto name = app.data;
	if (name.length < 3)
		return "gh-" ~ ghId;
	if (name.length > 32)
		name = name[0 .. 32];
	return name;
}

private string pickGitHubEmail(Json user, Json emails)
@safe {
	if (emails.type == Json.Type.array) {
		foreach (e; emails) {
			if (e["primary"].opt!bool && e["verified"].opt!bool)
				return e["email"].opt!string;
		}
		foreach (e; emails) {
			if (e["verified"].opt!bool)
				return e["email"].opt!string;
		}
	}
	if (user["email"].type == Json.Type.string)
		return user["email"].get!string;
	return null;
}

private string githubCallbackURL()
@safe {
	auto base = g_serviceURL;
	if (!base.length)
		base = "https://code.dlang.org/";
	if (base[$ - 1] != '/')
		base ~= "/";
	return base ~ "login/github/callback";
}

private string exchangeGitHubCode(string code)
{
	Json body;
	requestHTTP("https://github.com/login/oauth/access_token",
		(scope req) {
			req.method = HTTPMethod.POST;
			req.headers["Accept"] = "application/json";
			req.headers["User-Agent"] = "dub-registry";
			Json payload = Json.emptyObject;
			payload["client_id"] = g_githubClientId;
			payload["client_secret"] = g_githubClientSecret;
			payload["code"] = code;
			payload["redirect_uri"] = githubCallbackURL();
			req.writeJsonBody(payload);
		},
		(scope res) {
			enforce(res.statusCode < 400, "GitHub token exchange failed");
			body = parseJsonString(res.bodyReader.readAllUTF8());
		});
	auto token = body["access_token"].opt!string;
	enforce(token.length, "GitHub did not return an access token");
	return token;
}

private Json githubAPI(string url, string token)
{
	Json body;
	requestHTTP(url,
		(scope req) {
			req.headers["Accept"] = "application/vnd.github+json";
			req.headers["Authorization"] = "Bearer " ~ token;
			req.headers["User-Agent"] = "dub-registry";
		},
		(scope res) {
			enforce(res.statusCode < 400, "GitHub API request failed");
			body = parseJsonString(res.bodyReader.readAllUTF8());
		});
	return body;
}

private string oauthParam(HTTPServerRequest req, string key, string def = "")
@safe {
	auto ct = req.contentType;
	if (ct.startsWith("application/json")) {
		if (req.json.type == Json.Type.object) {
			auto v = req.json[key].opt!string;
			if (v.length)
				return v;
		}
		return def;
	}
	auto fv = req.form.get(key, "");
	return fv.length ? fv : def;
}

private class OAuthHTTPException : Exception {
	string error;
	int status;
	this(string error, string description, int status)
	{
		super(description);
		this.error = error;
		this.status = status;
	}
}

private void enforceOAuth(bool cond, string error, string description, int status)
{
	if (!cond)
		throw new OAuthHTTPException(error, description, status);
}

private void writeOAuthError(HTTPServerResponse res, OAuthHTTPException e)
{
	res.statusCode = e.status;
	Json body = Json.emptyObject;
	body["error"] = e.error;
	body["error_description"] = e.msg;
	res.writeJsonBody(body);
}

@safe unittest
{
	assert(isLoopbackRedirectURI("http://127.0.0.1:43781/callback"));
	assert(isLoopbackRedirectURI("http://127.0.0.1/oauth/cb"));
	assert(isLoopbackRedirectURI("http://localhost:8080/"));
	assert(isLoopbackRedirectURI("http://[::1]:9/cb"));
	assert(!isLoopbackRedirectURI("https://127.0.0.1/callback"));
	assert(!isLoopbackRedirectURI("http://example.com/callback"));
	assert(!isLoopbackRedirectURI("http://127.0.0.1.evil.test/callback"));
	assert(!isLoopbackRedirectURI("http://evil.com#@127.0.0.1/"));
	assert(!isLoopbackRedirectURI("http://127.0.0.1:80/cb\r\nLocation: http://evil"));
	assert(!isLoopbackRedirectURI(""));
}

@safe unittest
{
	assert(isValidClientId("native"));
	assert(isValidClientId("dub-publish"));
	assert(isValidClientId("dubx"));
	assert(!isValidClientId(""));
	assert(!isValidClientId("has space"));
	assert(!isValidClientId("slash/nope"));
}

@safe unittest
{
	// RFC 7636 appendix B
	enum verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
	assert(pkceChallengeS256(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
	assert(isValidPKCEVerifier(verifier));
	assert(isValidPKCEChallenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
}

@safe unittest
{
	assert(isSafeLocalRedirect("/oauth/authorize?response_type=code"));
	assert(isSafeLocalRedirect("/my_packages"));
	assert(!isSafeLocalRedirect("https://evil.test/"));
	assert(!isSafeLocalRedirect("//evil.test/"));
	assert(!isSafeLocalRedirect("/\\evil.test"));
	assert(!isSafeLocalRedirect(""));
}

@safe unittest
{
	AuthorizeRequest ar;
	ar.responseType = "code";
	ar.clientId = "native";
	ar.redirectUri = "http://127.0.0.1:1234/callback";
	ar.codeChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
	ar.codeChallengeMethod = "S256";
	ar.scopeName = "packages";
	assert(validateAuthorizeRequest(ar) is null);

	auto bad = ar;
	bad.redirectUri = "https://code.dlang.org/callback";
	assert(validateAuthorizeRequest(bad) !is null);

	bad = ar;
	bad.codeChallengeMethod = "plain";
	assert(validateAuthorizeRequest(bad) !is null);
}

@safe unittest
{
	assert(extractBearerToken("Bearer abc") == "abc");
	assert(extractBearerToken("bearer xyz") == "xyz");
	assert(!extractBearerToken("Basic abc").length);
	assert(!extractBearerToken("").length);
}
