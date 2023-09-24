/*******************************************************************************

    Configuration file for dub-registry.

*******************************************************************************/

module dubregistry.config;

import dub.internal.configy.Attributes;
import dub.internal.configy.Read;

import vibe.mail.smtp;

import std.array;
import std.conv;
import std.process;
import std.string;

public struct AppConfig
{
	@Name("github-auth") @Optional
	string ghauth;
	@Name("gitlab-url") @Optional
	string glurl;
	@Name("gitlab-auth") @Optional
	string glauth;
	@Name("bitbucket-user") @Optional
	string bbuser;
	@Name("bitbucket-password") @Optional
	string bbpassword;
	@Name("gitea-url") @Optional
	string giteaurl;
	@Name("gitea-auth") @Optional
	string giteaauth;
	@Name("enforce-certificate-trust")
	bool enforceCertificateTrust = false;

	@Name("service-name")
	string serviceName = "DUB - The D package registry";
	@Name("service-url")
	string serviceURL = "https://code.dlang.org/";
	@Name("service-email")
	string serviceEmail = "noreply@rejectedsoftware.com";

	@Name("mail-server") @Optional
	string mailServer;
	@Name("mail-server-port") @Optional
	ushort mailServerPort;
	@Name("mail-connection-type") @Optional
	SMTPConnectionType mailConnectionType;
	@Name("mail-client-name") @Optional
	string mailClientName;
	@Name("mail-user") @Optional
	string mailUser;
	@Name("mail-password") @Optional
	string mailPassword;

	@Name("administrators") @Optional
	string[] administrators;

	static AppConfig read (string path = "settings.json")
	{
        import std.file : exists;

		if (!path.exists) return AppConfig.init;
		auto configN = parseConfigFileSimple!AppConfig(path);
		if (configN.isNull()) return AppConfig.init;
		return configN.get().readEnvOverrides();
	}

	static AppConfig readString (string content, string path = "/dev/null")
	{
		return parseConfigString!AppConfig(content, path)
			.readEnvOverrides();
	}

	private ref AppConfig readEnvOverrides () @safe return
	{
		import std.traits : getUDAs;

		// Check environment variables for overrides
		static foreach (idx; 0 .. AppConfig.tupleof.length) {{
			alias T = typeof(this.tupleof[idx]);
			alias uda = getUDAs!(AppConfig.tupleof[idx], Name);
			static immutable string Name_ = uda.length ? uda[0].name :
				__traits(identifier, AppConfig.tupleof[idx]);

			auto ev = environment.get(Name_.replace("-", "_").toUpper);
			if (ev.length)
				this.tupleof[idx] = AppConfig.getEnvType!T(ev);
		}}
		return this;
	}

	static T getEnvType (T) (string envValue)
	{
		static if (is(T == string[]))
			return envValue.split(',');
		else
			return envValue.to!T;
	}
}

unittest
{
	immutable str = `{
  "github-auth": "foo",
  "enforce-certificate-trust": true,
  "mail-connection-type": "startTLS",
  "administrators": [ "Joe Bloggs", "Walter Bright", "root" ]
}
`;
	auto conf = AppConfig.readString(str);
    assert(conf.ghauth == "foo");
    assert(conf.glauth.length == 0);
    assert(conf.enforceCertificateTrust == true);
    assert(conf.mailConnectionType == SMTPConnectionType.startTLS);
    assert(conf.administrators == [ "Joe Bloggs", "Walter Bright", "root" ]);

    environment["MAIL_CONNECTION_TYPE"] = "tls";
    auto c2 = AppConfig.readString(str);
    assert(c2.mailConnectionType == SMTPConnectionType.tls);
}
