function updateLogoPreview(input) {
	var f = input.files[0];
	if (!f) return;

	var logos = document.querySelectorAll(".packageLogoCollection img.packageLogo");

	var image = window.URL.createObjectURL(f);

	for (var i = 0; i < logos.length; i++)
		logos[i].src = image;
}