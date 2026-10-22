# Facelift 2/4 (issue #94) -- THE ONE SWITCH for the record-page template.
#
# A job, a project and a proof each lay their header out differently today: no
# shared skeleton, so every detail page re-decides the order and none of them
# quite matches. When this is true, the three record views render their head
# through ONE shared partial
# (`app/views/application/_record_header.html.erb`: breadcrumb -> gradient
# heading -> badge/meta row -> alias line) and their section headings through
# ONE helper (`ApplicationHelper#record_section`).
#
# MECHANISM, stated once because it is the sharpest requirement in the issue:
# each view keeps its PREVIOUS per-page head VERBATIM in the `else` branch of
# this switch. So a regression is a one-line revert -- set this to false and
# every record page is byte-for-byte what it was -- and the old layout is never
# "removed", only hidden behind the new one.
#
# The switch is a Ruby constant and NOT an ERB comment block, and that is
# deliberate: a record head is full of ERB tags, and an ERB comment ends at the
# FIRST `%>` in its body (`references/layout-and-probe-pitfalls.md` #24), so
# commenting the old head out would swallow the rest of the page and still
# return HTTP 200. A constant is also server-side, so exactly ONE of the two
# heads is ever in the response: nothing double-renders, there is only ever one
# `<h1>` per page, and Turbo Drive's body swap sees a single document either
# way (the shared init in aether-core is untouched by all of this).
RECORD_TEMPLATE_V2 = true
