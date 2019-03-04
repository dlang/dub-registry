var logoUploadButton = document.getElementById("logo-upload-button");
logoUploadButton.disabled = true;
function updateLogoPreview(input) {
	var f = input.files[0];
	if (!f) return;
	logoUploadButton.disabled = true;
	var error = false;
	document.querySelector(".logoError").textContent = "";
	if (f.type != "image/png" && f.type != "image/gif" && f.type != "image/jpeg" && f.type != "image/bmp")
		document.querySelector(".logoError").textContent += "Warning: Invalid image type. ";
	else if (f.size > 1024 * 1024) {
		document.querySelector(".logoError").textContent += "Error: Image file size too large! ";
		error = true;
	}
	var img = document.querySelector("img.packageLogo");
	img.src = window.URL.createObjectURL(f);
	img.onload = function () {
		if (img.naturalWidth && img.naturalHeight) {
			if (img.naturalWidth < 2 || img.naturalHeight < 2 || img.naturalWidth > 2048 || img.naturalHeight > 2048) {
				document.querySelector(".logoError").textContent += "Invalid image dimenstions, must be between 2x2 and 2048x2048. ";
				error = true;
			}
			if (!error)
				logoUploadButton.disabled = false;
		}
	};
}

/* TABS */

/**
 * @param {HTMLElement} subtabs
 * @param {string} [openPage] the page to open by default or undefined to resolve from hash. If not found, the first page will be shown instead.
 */
function upgradeSubtabs(subtabs, openPage) {
	if (openPage === undefined)
		openPage = window.location.hash.substr(1);

	var links = subtabs.querySelectorAll("a.tab");

	if (openPage && !subtabsHasPage(subtabs, openPage))
		return;

	var first;
	var gotActive = false;

	for (var i = 0; i < links.length; i++) {
		var link = links[i];
		if (link.classList.contains("external"))
			continue;

		var page = link.getAttribute("data-tab");
		if (!page)
			continue;

		if (!openPage)
			openPage = page;
		if (!first)
			first = link;

		var subtab = document.getElementById("tab-" + page);
		if (!subtab)
			continue;

		var show = page == openPage;
		upgradeSubtabPage(subtab, page, show);

		if (show) {
			link.classList.add("active");
			gotActive = true;
		}
		else
			link.classList.remove("active");
	}

	if (!gotActive && first) {
		first.classList.add("active");
		var page = first.getAttribute("data-tab");
		upgradeSubtabPage(document.getElementById("tab-" + page), page, true);
	}
}

/**
 * @param {HTMLElement} subtabs the subtabs header containing links
 * @param {string} page
 */
function subtabsHasPage(subtabs, page)
{
	var links = subtabs.querySelectorAll("a.tab");
	for (var i = 0; i < links.length; i++)
		if (links[i].getAttribute("data-tab") == page)
			return true;
	return false;
}

/**
 * @param {HTMLElement} subtab
 * @param {string} page
 * @param {boolean} show
 */
function upgradeSubtabPage(subtab, page, show) {
	var header = subtab.firstElementChild;
	if (header.tagName == "A" && header.getAttribute("name") == page) {
		var link = header;
		header = header.nextElementSibling;
		link.parentElement.removeChild(link);
	}

	if (header.tagName == "H2")
		header.style.display = "none";

	subtab.style.display = show ? "" : "none";
	subtab.classList.add("js");
}

/**
 * @param {string} [openPage]
 */
function upgradeAllSubtabs(openPage) {
	var subtabs = document.querySelectorAll(".subtabsHeader");
	for (var i = 0; i < subtabs.length; i++)
		upgradeSubtabs(subtabs[i], openPage);
}

if (window.location.hash.length)
	upgradeAllSubtabs(window.location.hash.substr(1));
else
	upgradeAllSubtabs("");

window.addEventListener("hashchange", function () {
	upgradeAllSubtabs();
});
