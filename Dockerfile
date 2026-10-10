# chopshop-studio — containerised Rails 8 app (production).
#
# Ruby 3.3 (matches the host's .ruby-version / system ruby 3.3.8).  This is a
# real deploy image, unlike Dockerfile.dev (which is a verification-only image
# that bind-mounts the tree).  Here the app, its bundle, and precompiled assets
# are baked in; only the DATABASE + storage tree and secrets are mounted at
# runtime, so the image is portable and the running container never drifts from
# what was built.
#
# Fronting: the host nginx (nginx-chopshop.conf) already proxies
# 127.0.0.1:3001 -> this container's 3001 with the X-Forwarded-* headers, and
# does its own TLS/compression.  So this container runs PLAIN Puma on 3001
# (loopback-published) -- no Thruster in front (nginx covers that), and the
# nginx config is not touched by containerising the app.
#
# Solid Queue runs as threads inside Puma when SOLID_QUEUE_IN_PUMA is set (see
# config/puma.rb), so there is no separate worker container to run.

FROM ruby:3.3-slim

# build-essential/libssl-dev/libyaml-dev: native gem builds (sqlite3, puma,
# nokogiri, etc).  libvips42: Active Storage variant processing.  git: some
# gems resolve from git.  tzdata: Rails time zone data.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libssl-dev libyaml-dev \
        libsqlite3-0 libsqlite3-dev \
        libvips42 \
        git curl tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Bundle FIRST on its own layer so app edits don't bust the gem cache.
# BUNDLE_WITHOUT strips dev + test: the production image ships only runtime
# gems.  BUNDLE_DEPLOYMENT (set below) makes this a clean, frozen bundle.
COPY Gemfile Gemfile.lock ./
RUN gem install bundler --no-document \
    && bundle config set --local without 'development test' \
    && bundle install --jobs 4 --retry 3

# Copy the app (respects .dockerignore).  The DB + storage/ + log/ are NOT
# copied in -- they are bind-mounted at runtime so they persist.
COPY . .

# Precompile assets at BUILD time, so boot is fast and deterministic.  Rails 8
# needs SECRET_KEY_BASE present to precompile; a throwaway value is fine here
# because the real one is supplied at RUN time via the environment.  If the
# precompile fails, the build fails -- a broken asset pipeline never ships.
#
# `log/` is bind-mounted at runtime, but production.rb builds a file Logger
# (log/production.log) for fail2ban parsing at ENVIRONMENT LOAD -- which
# assets:precompile triggers.  So create the dir + touch the file here, or the
# precompile dies opening a file in a dir .dockerignore kept out of the image.
RUN mkdir -p log tmp && touch log/production.log \
    && SECRET_KEY_BASE=precompile-placeholder \
    RAILS_ENV=production \
    bundle exec rails assets:precompile \
    && rm -rf tmp/cache

EXPOSE 3001

# Runs plain Puma, bound to all interfaces inside the container; compose
# publishes it as 127.0.0.1:3001 so it stays loopback-only to the host, exactly
# like the native unit.  Solid Queue runs in-Puma when SOLID_QUEUE_IN_PUMA is
# set in the environment.
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "-b", "tcp://0.0.0.0:3001"]
