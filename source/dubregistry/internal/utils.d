module dubregistry.internal.utils;

import vibe.inet.url;

URL black(URL url)
@safe {
	if (url.username.length > 0) url.username = "***";
	if (url.password.length > 0) url.password = "***";
	return url;
}

string black(string url)
@safe {
	return black(URL(url)).toString();
}
