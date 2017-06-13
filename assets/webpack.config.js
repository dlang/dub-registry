var path = require('path');
var ManifestPlugin = require('webpack-manifest-plugin');
var ExtractTextPlugin = require("extract-text-webpack-plugin");


const OUTPUT = './../public';

module.exports = {
	target: 'web',
	entry: {
		home: './scripts/home.js',
		menu: './scripts/menu.js',
		clipboard: './scripts/clipboard.min.js',
		common: './styles/common.css',
		markdown: './styles/markdown.css',
		top: './styles/top.css',
		top_p: './styles/top_p.css'
	},
	output: {
		filename: '[name].[hash].js',
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
				test: /\.(woff|woff2|eot|ttf|otf)$/,
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
		new ExtractTextPlugin('[name].[contenthash].css'),
	]
};
