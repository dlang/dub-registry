function setupCategoryForm()
{
	el("category-form").style.display = "none";
	el("category-dynamic-form").style.display = "block";
	selected_cats = el("category").value.split(".");
	var parentcat = null;
	setCategory(el("category").value);
}

function updateCategorySelector(i, parentcat)
{
	var sel = getSel(i);
	var cats = i > 0 ? parentcat.subCategories : window.categories;
	if (!cats.length) {
		sel.style.display = "none";
		return;
	}

	var newhtml;
	newhtml += "<option value=''>---</option>";
	for (i in cats) {
		var cat = cats[i];
		newhtml += "<option value='"+cat.name+"'>"+cat.description+"</option>"; // <img class='category-icon' src='images/categories/"+cat.image+".png'>
	}
	sel.innerHTML = newhtml;
	sel.style.display = "inline-block";
}

function setCategoryFromSelector(selidx)
{
	var cat = getSel(selidx).value;
	if (selidx > 0 && cat == "") cat = getSel(selidx-1);
	setCategory(cat);
}

function setCategory(catname)
{
	var cats = window.categories;
	var cat = null;
	var parts = catname.length ? catname.split(".") : [];
	for (i in parts) {
		updateCategorySelector(i, cat);
		var pcat = parts[0];
		for (var j = 1; j <= i; j++) pcat += "." + parts[j];
		getSel(i).value = pcat;
		cat = getCat(cats, pcat);
		cats = cat.subCategories;
	}

	updateCategorySelector(parts.length, cat);

	for (var i = parts.length+1; i < 6; i++)
		getSel(i).style.display = "none";

	var catsel = el("category");
	if (catsel.value != catname) {
		catsel.value = catname;
		catsel.onchange();
	}
}

function getCat(cats, cat)
{
	for (var i in cats) {
		if (cats[i].name == cat)
			return cats[i];
	}
	return null;
}

function el(name) { return document.getElementById(name); }
function getSel(idx) { return el("categories_"+idx); }
