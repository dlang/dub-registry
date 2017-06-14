var path = require('path');
var ManifestPlugin = require('webpack-manifest-plugin');
var ExtractTextPlugin = require("extract-text-webpack-plugin");


const OUTPUT = './../public';

module.exports = {
	target: 'web',
	entry: [
		'./scripts/bundle.js',
		'./images/bundle.js',
		'./styles/bundle.css',
		'./favicon.ico'
	],
	output: {
		filename: '[chunkhash].js',
		path: path.resolve(__dirname, OUTPUT)
	},
	module: {
		rules: [
			{
				test: /\.css$/,
				use: ExtractTextPlugin.extract({
					fallback: "style-loader",
					use: "css-loader"
				})
			},
			{
				test: /\.(woff|woff2|eot|ttf|otf|png|svg|ico)$/,
				use: [
					'file-loader'
				]
			}
		]
	},
	plugins: [
		new ManifestPlugin({
			stripSrc: true
		}),
		new ExtractTextPlugin('[contenthash].css'),
	]
};
