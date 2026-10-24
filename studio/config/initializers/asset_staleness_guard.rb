# Warn at boot when the compiled asset manifest predates the sources it was
# built from (studio #8).
#
# The Dockerfile precompiles assets at image build time, so the guard is not
# replacing a manual step -- it is a cheap CHECK that fires if the deployed
# manifest ever falls behind `app/assets` (a non-container deploy, a CDN that
# serves stale bytes, a box rebuilt without the precompile step). The failure
# mode is a page that renders fine but whose CSS/JS no longer matches the
# repository, so this is a loud WARNING in the log rather than a boot refusal:
# see the class comment in `AssetStalenessGuard` for why a stale asset is a
# deploy smell and not a runtime fault.
#
# The check lives in the guard rather than here so it can be exercised
# against tmpdir fixtures with controlled mtimes in the test suite -- an
# initializer is the ONE place a Rails app cannot be tested, and the whole
# point is that the warning is real rather than decorative.
require_relative "../../app/lib/asset_staleness_guard"

AssetStalenessGuard.verify!
