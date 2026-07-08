import Testing
@testable import AppRouterCore

/// The reviewer's central criterion: the JSONC preprocessor must not corrupt `//` or
/// `/* */` sequences that live *inside* string values (URLs, regexes).
@Suite struct JSONCPreprocessorTests {

    @Test func stripsLineComments() {
        let input = """
        {
          "a": 1, // trailing comment
          // full-line comment
          "b": 2
        }
        """
        let out = JSONCPreprocessor.strip(input)
        #expect(!out.contains("trailing comment"))
        #expect(!out.contains("full-line comment"))
        #expect(out.contains("\"a\""))
        #expect(out.contains("\"b\""))
    }

    @Test func stripsBlockComments() {
        let input = #"{ "a": /* inline */ 1, /* multi\n line */ "b": 2 }"#
        let out = JSONCPreprocessor.strip(input)
        #expect(!out.contains("inline"))
        #expect(!out.contains("multi"))
        #expect(out.contains("\"a\""))
    }

    // The double-slash reviewer criterion: http:// inside a string must survive.
    @Test func preservesDoubleSlashInsideURLString() {
        let input = #"{ "url": "http://example.com/path" }"#
        let out = JSONCPreprocessor.strip(input)
        #expect(out.contains("http://example.com/path"))
    }

    @Test func preservesDoubleSlashWithTrailingComment() {
        let input = #"{ "url": "https://a.com" } // note"#
        let out = JSONCPreprocessor.strip(input)
        #expect(out.contains("https://a.com"))
        #expect(!out.contains("note"))
    }

    @Test func preservesCommentDelimitersInRegexString() {
        // A regex value containing /* and // must not be treated as a comment.
        let input = #"{ "match": "foo/*bar//baz" }"#
        let out = JSONCPreprocessor.strip(input)
        #expect(out.contains(#"foo/*bar//baz"#))
    }

    @Test func handlesEscapedQuoteInsideString() {
        // The escaped quote must not end the string early, so the // stays literal.
        let input = #"{ "s": "a \" // still-in-string" }"#
        let out = JSONCPreprocessor.strip(input)
        #expect(out.contains(#"// still-in-string"#))
    }

    @Test func handlesEscapedBackslashBeforeQuote() {
        // "path\\" — the backslash is escaped, so the following quote DOES close.
        let input = #"{ "p": "c:\\", "x": 1 // c }"#
        let out = JSONCPreprocessor.strip(input)
        #expect(out.contains(#""p": "c:\\""#))
        #expect(!out.contains("c }")) // the // comment after the closed string is stripped
    }

    @Test func outputStripsToValidJSON() throws {
        let input = """
        {
          // config
          "extensions": { "md": [ { "name": "X", "app": "/A.app" } ] }, /* end */
          "urls": []
        }
        """
        let config = try ConfigLoader.load(jsonc: input)
        #expect(config.extensions["md"]?.count == 1)
    }

    @Test func emptyAndNoCommentInputsUnchanged() {
        #expect(JSONCPreprocessor.strip("") == "")
        let plain = #"{"a":1}"#
        #expect(JSONCPreprocessor.strip(plain) == plain)
    }
}
