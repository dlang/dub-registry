module dubregistry.package_;

class PackageVersion {
	string name;
	string description;
	string homepage;
	string copyright;
	string[] authors;
	string[string] dependencies;
	RepositoryInfo repository;
}

struct RepositoryInfo {
	string type;
	string url;
}