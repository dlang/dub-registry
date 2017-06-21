var gulp = require("gulp");
var uglify = require("gulp-uglify");
var csso = require("gulp-csso");
var del = require("del");

const PATHS = {
	scripts: ["scripts/**/*.js"],
	styles: ["styles/**/*.css"],
	images: ["images/**/*"],
	fonts: ["fonts/**/*.woff"],
	favicon: ["favicon.ico"]
};

const OUTPUTDIR = "../public";

gulp.task("scripts", function() {
	return gulp.src(PATHS.scripts, { base: "." })
		.pipe(uglify())
		.pipe(gulp.dest(OUTPUTDIR));
});

gulp.task("styles", function() {
	return gulp.src(PATHS.styles, { base: "." })
		.pipe(csso())
		.pipe(gulp.dest(OUTPUTDIR));
});

gulp.task("images", function() {
	return gulp.src(PATHS.images, { base: "." })
		.pipe(gulp.dest(OUTPUTDIR));
});

gulp.task("fonts", function() {
	return gulp.src(PATHS.fonts, { base: "." })
		.pipe(gulp.dest(OUTPUTDIR));
});

gulp.task("favicon", function() {
	return gulp.src(PATHS.favicon, { base: "." })
		.pipe(gulp.dest(OUTPUTDIR));
});

gulp.task("scripts-watch", function() {
	return gulp.src(PATHS.scripts, { base: "." })
		.pipe(gulp.dest(OUTPUTDIR));
});
gulp.task("styles-watch", function() {
	return gulp.src(PATHS.styles, { base: "." })
		.pipe(gulp.dest(OUTPUTDIR));
});

gulp.task("watch", ["images", "fonts", "favicon", "scripts-watch", "styles-watch"], function() {
	gulp.watch(PATHS.scripts, ["scripts-watch"]);
	gulp.watch(PATHS.styles, ["styles-watch"]);
	gulp.watch(PATHS.images, ["images"]);
	gulp.watch(PATHS.fonts, ["fonts"]);
	gulp.watch(PATHS.favicon, ["favicon"]);
});

gulp.task("clean", function() {
    return del(OUTPUTDIR, { force: true });
});

gulp.task("default", ["scripts", "styles", "images", "fonts", "favicon"]);
