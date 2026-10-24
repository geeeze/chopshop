# The BP client: ONE entry point for the whole blend-plot service.
#
# The service serves six operations behind one JSON contract, and this app
# already had two clients for it — PlotClient for the five that answer with an
# SVG document, BlenderClient for `blender`, which answers with rendered files.
# A BP job is one action covering all six, so it needs one client — and the
# honest shape for that is a DISPATCHER over the two, not a third wire
# implementation. The envelope, the bearer token, the timeouts and the refusal
# parsing all stay where they are and where they are already tested; this file
# adds no protocol of its own and deliberately reads no environment variable the
# two it delegates to do not already read.
#
# The one thing it does say is which operation answers HOW, because that is the
# only branch a caller has to know about:
#
#   blender            -> rendered FILES  (image/png, or a frames manifest)
#   everything else    -> one SVG document (image/svg+xml)
#
# Both refusals are the same protocol refusal — a JSON `{"error": …, "kind": …}`
# envelope — which is why a blender failure can be reported as a BP failure
# without losing anything.
module BpClient
  # ONE failure name for a BP job. The two delegated clients raise their own
  # errors, and a BP job that failed because the service is down would otherwise
  # be reported as "PLOT: ..." — a name the site no longer offers. run_bp
  # re-raises either as this, so the operator reads the half that actually
  # answered in the MESSAGE and a single BP name in the prefix.
  class Error < StandardError; end

  # Re-exported so a caller that only knows about BP can rescue one name.
  PlotError = PlotClient::PlotError
  BlenderError = BlenderClient::BlenderError
  SpecError = BlenderClient::SpecError
  Unavailable = BlenderClient::Unavailable

  # The extension of the file an operation's answer is stored as, which is what
  # a caller needs to record the result without inspecting the bytes.
  def self.extension_for(op)
    op.to_s.strip == "blender" ? ".png" : ".svg"
  end

  # Post one operation. `runs` is the drawing operations' transport field and is
  # sent only when the caller passes it — the query operation requires it and
  # every other operation must not receive it.
  def self.render(base, op, doc, runs: nil)
    return BlenderClient.render(base, doc) if op.to_s.strip == "blender"
    PlotClient.render(base, op, doc, runs: runs)
  end

  # Whether the service is answering, and which operations it advertises. The
  # service's own /health needs no token and lists what the RUNNING build
  # serves, so a deployment behind origin/main reports the older list rather
  # than this app's expectations.
  def self.health(base)
    PlotClient.health(base)
  end
end
