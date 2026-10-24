# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
# Bumped 1.0 -> 2.0 when comment redaction was added: the compiled bundles
# changed (comments stripped) but their SOURCE did not, and Propshaft digests
# raw content — so without a version bump the far-future-cached bundles would
# keep serving the commented bytes.
Rails.application.config.assets.version = "2.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# Strip comments from the COMPILED JS/CSS bundles (Propshaft ships them
# verbatim by default). Runs before the URL-rewrite compilers so they see the
# redacted text; the source files under app/javascript and app/assets stay
# fully commented.
require Rails.root.join("lib/comment_redactor").to_s

Rails.application.config.assets.compilers.prepend(
  ["text/javascript", CommentRedactor::Js],
  ["text/css", CommentRedactor::Css]
)
