module dubregistry.mongodb;

import vibe.core.log;
import vibe.db.mongo.client : MongoClient;
import vibe.db.mongo.mongo : connectMongoDB;
import vibe.db.mongo.settings : MongoClientSettings, MongoAuthMechanism, parseMongoDBUrl;
import std.typecons : Nullable;

/// Database name
string databaseName = "vpmreg";
private Nullable!MongoClientSettings _mongoSettings;

@safe:

/**
Initializes mongoSettings if null

Params:
	allowUnauthenticated = whether to allow unauthenticated access

Examples:
	dub -- --allow-unauthenticated=true

Returns:
	MongoClientSettings
*/
MongoClientSettings mongoSettings(bool allowUnauthenticated = false)
{
	if (_mongoSettings.isNull)
	{
		import std.process : environment;

		auto mongodbURI = environment.get("MONGODB_URI",
				environment.get("MONGO_URI", "mongodb://127.0.0.1"));
		logInfo("Found mongodbURI: %s", mongodbURI);
		_mongoSettings = MongoClientSettings.init;
		parseMongoDBUrl(_mongoSettings, mongodbURI);

		if (!allowUnauthenticated)
			_mongoSettings.authMechanism = MongoAuthMechanism.scramSHA1;

		if (_mongoSettings.database.length > 0)
			databaseName = _mongoSettings.database;

		_mongoSettings.safe = true;
	}
	return _mongoSettings;
}

/**
Returns: MongoClient using the current settings
*/
MongoClient getMongoClient()
{
	return connectMongoDB(mongoSettings);
}
