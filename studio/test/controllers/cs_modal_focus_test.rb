require "test_helper"

# The glass modal (CsModal) is a dialog, so opening it must move focus INTO it
# and keep Tab from escaping to the page behind it, and it must lock scroll
# through the shared lock rather than a bare `body.style.overflow` write (#86).
class CsModalFocusTest < ActiveSupport::TestCase
  CORE = Rails.root.join("app/javascript/aether-core.js").read(encoding: "UTF-8")

  test "openCsModal locks scroll through the shared lock and focuses a control inside the modal" do
    open_fn = CORE[/function openCsModal\(.*?\n  \}/m]
    refute_nil open_fn, "openCsModal must be its own function"

    assert_includes open_fn, "lockScroll()",
      "the modal must lock through the shared lock, which reserves the scrollbar width"
    refute_includes open_fn, "document.body.style.overflow",
      "a bare overflow write from the modal is the #86 defect: it widens the viewport"

    # Focus lands on a control INSIDE the modal (the close button), not on BODY.
    assert_match(/querySelector\('#csModalClose'\)[\s\S]*?\.focus\(\)/, open_fn,
      "the modal must focus its close control so the user starts inside the dialog")
    assert_includes CORE, 'id="csModalClose"',
      "the close control must carry the id the focus target looks up"
  end

  test "Tab is trapped inside the open modal" do
    assert_includes CORE, "function csTrapTab("
    assert_includes CORE, "e.key !== 'Tab'"
    assert_match(/classList\.contains\('open'\)/, CORE,
      "the trap must only act while the modal is open")
    assert_includes CORE, "last.focus()", "Shift+Tab from the first control wraps to the last"
    assert_includes CORE, "first.focus()", "Tab from the last control wraps to the first"
    assert_match(/s\.display !== 'none' && s\.visibility !== 'hidden'/, CORE,
      "the ring must exclude controls the browser cannot focus, or the trap wraps to a hidden one")
    # Bound once, when the modal element is created.
    assert_includes CORE, "csTrapTab(wrap, e)"
  end

  test "closeCsModal releases the shared lock" do
    close_fn = CORE[/function closeCsModal\(.*?\n  \}/m]
    refute_nil close_fn, "closeCsModal must be its own function"
    assert_includes close_fn, "unlockScroll()"
    refute_includes close_fn, "document.body.style.overflow"
  end

  # The lock is ONE implementation: the site module's popups delegate to the core
  # lock, so the modal and the popups cannot drift apart.
  test "the lock is one implementation shared with the popups" do
    site = Rails.root.join("app/javascript/aether.js").read(encoding: "UTF-8")
    assert_includes site, "var lockScroll = core.lockScroll"
    refute_includes site, "function lockScroll(",
      "the site module must delegate to the core lock, not keep a second copy"
  end
end
