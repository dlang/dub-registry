module dubregistry.internal.utils;

import vibe.inet.url;

URL black(URL url)
{
	if (url.username.length > 0) url.username = "***";
	if (url.password.length > 0) url.password = "***";
	return url;
}

string black(string url)
{
	return black(URL(url)).toString();
}
