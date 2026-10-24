require "test_helper"
require Rails.root.join("lib/comment_redactor").to_s

# The compiled JS/CSS bundles must ship WITHOUT comments, while the source
# files keep them. The redactor is pure string surgery over the propshaft
# compiler input; it must never eat a comment-looking sequence inside a
# string/template literal or a regex literal.
class CommentRedactorTest < ActiveSupport::TestCase
  def js
    CommentRedactor::Js.new(nil)
  end

  def css
    CommentRedactor::Css.new(nil)
  end

  test "strips // line comments and /* block */ comments from JS" do
    out = js.compile(nil, "var a = 1; // inline note\nvar b = 2; /* block\n note */\nvar c = 3;\n")
    refute_includes out, "// inline note"
    refute_includes out, "/* block"
    assert_includes out, "var a = 1;"
    assert_includes out, "var b = 2;"
    assert_includes out, "var c = 3;"
  end

  test "preserves // and /* inside string and template literals" do
    out = js.compile(nil,
      "var u = \"https://example.com/x\";\n" \
      "var s = '// not a comment';\n" \
      "var t = `a // b /* c */`;\n")
    assert_includes out, "https://example.com/x"
    assert_includes out, "'// not a comment'"
    assert_includes out, "`a // b /* c */`"
  end

  test "regex literals survive intact" do
    src = "var x = s.replace(/&/g, '&amp;').replace(/</g, '&lt;');\n"
    assert_equal src, js.compile(nil, src)
  end

  test "regex literals containing quotes are not mistaken for strings" do
    src = "var e = v.replace(/\\\"/g, '&quot;').replace(/'/g, '&#39;');\n"
    out = js.compile(nil, src)
    assert_equal src, out
  end

  test "a regex character class with quotes survives, and division is untouched" do
    src = "var s = v.replace(/[&<>\"']/g, fn); var half = (n - 1) / 2;\n"
    out = js.compile(nil, src)
    assert_equal src, out
  end

  test "a // comment after a regex on the next line is still stripped" do
    src = "var e = v.replace(/&/g, '&amp;');\n// trailing note\nvar done = true;\n"
    out = js.compile(nil, src)
    refute_includes out, "trailing note"
    assert_includes out, "replace(/&/g, '&amp;');"
    assert_includes out, "var done = true;"
  end

  test "preserves newlines so line numbers do not drift" do
    src = "a(); // one\nb();\n"
    out = js.compile(nil, src)
    assert_equal src.count("\n"), out.count("\n")
  end

  test "strips /* block */ comments from CSS but preserves url() and content strings" do
    src = "/* header rule */\n.a { background: url(\"img/a.png\"); content: \"/* x */\"; }\n"
    out = css.compile(nil, src)
    refute_includes out, "header rule"
    assert_includes out, 'url("img/a.png")'
    assert_includes out, 'content: "/* x */"'
  end
end
