# frozen_string_literal: true

require "propshaft/compiler"

# Build-time comment redaction. Propshaft ships JS/CSS verbatim (it only
# fingerprints digests and rewrites asset URLs), so every source comment reaches
# the browser. These compilers strip comments from the COMPILED bundles while
# the source files stay fully commented. They run first (prepended in
# config/initializers/assets.rb) so the URL-rewrite compilers see the redacted
# text.
#
# String, template, and regex literals are skipped, so a `//`, `/*`, `"` or `'`
# inside any of them survives. Regex literals MUST be skipped: `/\"/g` and
# `/'/g` (a regex matching a quote) contain a quote character that a naive
# string scan would misread as a string delimiter and then swallow the rest of
# the file unredacted.
module CommentRedactor
  class Js < Propshaft::Compiler
    # Characters that may immediately precede a regex literal (and so mark a `/`
    # as regex, not division). `)` and `]` are deliberately excluded: a slash
    # after either is division (`(n - 1) / 2`, `arr[0] / 2`). This is scoped to
    # the codebase's regexes, which all follow `(` (`.replace(...)`); division
    # here always follows an operand.
    REGEX_PRECEDERS = "([=,:;!&|?".freeze

    def compile(_asset, input)
      out = +""
      i = 0
      n = input.length
      while i < n
        c = input[i]
        if c == "'" || c == '"' || c == '`'
          j = scan_string(input, i, c)
          out << input[i...j]
          i = j
        elsif input[i, 2] == "//"
          j = input.index("\n", i) || n
          i = j
        elsif input[i, 2] == "/*"
          j = input.index("*/", i + 2)
          j = j ? j + 2 : n
          out << input[i...j].scan(/\n/).join
          i = j
        elsif c == "/" && regex_start?(input, i)
          j = scan_regex(input, i)
          out << input[i...j]
          i = j
        else
          out << c
          i += 1
        end
      end
      out
    end

    private

    def regex_start?(input, i)
      j = i - 1
      while j >= 0 && input[j] =~ /[ \t\r\n]/
        j -= 1
      end
      return true if j < 0
      REGEX_PRECEDERS.include?(input[j])
    end

    # Scans a regex literal from the opening `/` to its closing `/` plus any
    # flags, honouring `\` escapes and `[...]` character classes (a class may
    # contain an unescaped `/`, `"` or `'`).
    def scan_regex(input, i)
      n = input.length
      j = i + 1
      in_class = false
      while j < n
        c = input[j]
        if c == "\\"
          j += 2
          next
        end
        if c == "["
          in_class = true
        elsif c == "]"
          in_class = false
        elsif c == "/" && !in_class
          j += 1
          j += 1 while j < n && input[j] =~ /[a-z]/
          return j
        end
        j += 1
      end
      n
    end

    def scan_string(src, i, quote)
      n = src.length
      j = i + 1
      while j < n
        c = src[j]
        if c == "\\"
          j += 2
          next
        end
        break if c == quote
        j += 1
      end
      j + 1
    end
  end

  class Css < Propshaft::Compiler
    def compile(_asset, input)
      out = +""
      i = 0
      n = input.length
      while i < n
        c = input[i]
        if c == "'" || c == '"'
          j = scan_string(input, i, c)
          out << input[i...j]
          i = j
        elsif input[i, 2] == "/*"
          j = input.index("*/", i + 2)
          j = j ? j + 2 : n
          out << input[i...j].scan(/\n/).join
          i = j
        else
          out << c
          i += 1
        end
      end
      out
    end

    private

    def scan_string(src, i, quote)
      n = src.length
      j = i + 1
      while j < n
        c = src[j]
        if c == "\\"
          j += 2
          next
        end
        break if c == quote
        j += 1
      end
      j + 1
    end
  end
end
