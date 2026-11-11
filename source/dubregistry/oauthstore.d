/**
	MongoDB persistence for OAuth authorization codes and access tokens.

	Copyright: © 2013-2026 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
*/
module dubregistry.oauthstore;

import dubregistry.mongodb : getMongoClient;

import std.datetime.systime;
import std.datetime.timezone;
import std.typecons : Nullable;

import vibe.data.bson;
import vibe.data.serialization;
import vibe.db.mongo.collection;


struct OAuthAuthCode {
	BsonObjectID _id;
	string codeHash;
	string userId;
	string clientId;
	string redirectUri;
	string codeChallenge;
	string codeChallengeMethod;
	@name("scope") string scopeName;
	SysTime expiresAt;
}

struct OAuthAccessToken {
	BsonObjectID _id;
	string tokenHash;
	string userId;
	string clientId;
	@name("scope") string scopeName;
	SysTime createdAt;
	SysTime expiresAt;
}

final class OAuthStore {
@safe:
	private {
		MongoCollection m_codes;
		MongoCollection m_tokens;
	}

	this(string dbname)
	{
		auto db = getMongoClient.getDatabase(dbname);
		m_codes = db["oauth_codes"];
		m_tokens = db["oauth_tokens"];

		IndexOptions unique;
		unique.unique = true;
		m_codes.createIndexes([
			IndexModel().add("codeHash", 1).withOptions(unique)
		]);
		m_tokens.createIndexes([
			IndexModel().add("tokenHash", 1).withOptions(unique),
			IndexModel().add("userId", 1)
		]);
	}

	void putCode(ref OAuthAuthCode rec)
	{
		if (rec._id == BsonObjectID.init)
			rec._id = BsonObjectID.generate();
		m_codes.insertOne(rec);
	}

	Nullable!OAuthAuthCode takeCode(string codeHash)
	{
		Nullable!OAuthAuthCode none;
		auto rec = m_codes.findOne!OAuthAuthCode(["codeHash": codeHash]);
		if (rec.isNull)
			return none;
		m_codes.deleteOne(["_id": rec.get._id]);
		if (rec.get.expiresAt < Clock.currTime(UTC()))
			return none;
		return rec;
	}

	void putToken(ref OAuthAccessToken rec)
	{
		if (rec._id == BsonObjectID.init)
			rec._id = BsonObjectID.generate();
		m_tokens.insertOne(rec);
	}

	Nullable!OAuthAccessToken findTokenHash(string tokenHash)
	{
		Nullable!OAuthAccessToken none;
		auto rec = m_tokens.findOne!OAuthAccessToken(["tokenHash": tokenHash]);
		if (rec.isNull)
			return none;
		if (rec.get.expiresAt < Clock.currTime(UTC())) {
			m_tokens.deleteOne(["_id": rec.get._id]);
			return none;
		}
		return rec;
	}

	void deleteToken(string tokenHash)
	{
		m_tokens.deleteOne(["tokenHash": tokenHash]);
	}
}
