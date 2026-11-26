/**
 * @file .graph grammar
 * @author christopher-wood
 * @license MIT
 *
 * `.graph` is a data definition language, structurally similar to JSON: a
 * sequence of newline delimited `key value` statements, where values may be
 * strings, numbers, bare identifiers, objects, or - for a handful of keys -
 * interpreted expressions introduced by `=`.
 *
 * The only reserved word is `fn`, which introduces a function definition.
 * Everything else (`graph`, `use`, `saveto`, `filter`, ...) is just an object
 * key, so this grammar deliberately does not special-case any particular key.
 *
 * This is an approximation of the Zig implementation in `src/parse/`, and is
 * tuned for syntax highlighting rather than for reproducing its diagnostics.
 */

/* eslint-disable arrow-parens */
/* eslint-disable camelcase */
/* eslint-disable-next-line spaced-comment */
/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "graph",

  // `;` runs to the end of the line. The Zig lexer turns a comment into a
  // newline, so newlines are not significant here and the comment can simply
  // be an extra.
  extras: ($) => [/[\t\r \uFEFF\u2060\u200B]/, $.comment],

  // Enables keyword extraction: `fn` is lexed as its own token rather than as
  // an `identifier`, matching `kwd_fn` in the Zig lexer. Access type names
  // (`max`, `min`, `current`, ...) are deliberately *not* extracted as
  // keywords, because they are valid bare identifiers in value position
  // (`select max`), exactly as in the Zig lexer.
  word: ($) => $.identifier,

  rules: {
    source_file: ($) => repeat($._statement),

    // At the top level a statement is either a `fn` definition or a key/value
    // pair. Inside an object only pairs are allowed.
    _statement: ($) => choice($.function_definition, $.pair),

    EOS: ($) => "\n",

    empty_statement: ($) => $.EOS,

    fn: ($) => "fn",

    /// `fn name(a, b) = expression`
    function_definition: ($) =>
      seq(
        field("fn", $.fn),
        field("name", $.identifier),
        field("parameters", $.parameter_list),
        "=",
        field("body", $._expression),
        $.EOS,
      ),

    parameter_list: ($) => seq("(", optional(commaSep1($.parameter)), ")"),

    parameter: ($) => $.identifier,

    /// `key value`, or `key = expression` for an interpreted value.
    ///
    /// The optional `value_ref` after the key binds a name to this entry so
    /// that `#name` and `!#name` can refer back to it elsewhere, e.g.
    /// `value #kalmanpos = ...`.
    ///
    /// The `=` is part of this rule rather than part of `_value` so that the
    /// parser can tell a literal value from an expression before it has seen
    /// the operand. Otherwise a bare number like `x 1` would be ambiguous
    /// between the two.
    pair: ($) =>
      choice(
        seq(
          field("key", $.identifier),
          optional(field("name", $.value_ref)),
          choice(
            field("value", $._value),
            seq("=", field("value", $.expression)),
          ),
          $.EOS,
        ),
        $.empty_statement,
      ),

    null: ($) => "null",
    _value: ($) =>
      choice(
        field("null", $.null),
        $.string,
        $.number,
        $.negative_number,
        field("enum_value", $.identifier),
        $.naked_value_ref,
        $.object,
      ),

    object: ($) => seq("{", optional(seq(repeat($.pair))), "}"),

    /// The body of a function, or the right hand side of an interpreted value.
    expression: ($) => $._expression,

    parenthesized_expression: ($) => seq("(", $._expression, ")"),

    _expression: ($) =>
      choice(
        $.parenthesized_expression,
        $.binary_expression,
        $.number,
        $.unary_expression,
        $.identifier,
        $.call,
        $.keyref,
        $.value_ref,
      ),

    unary_expression: ($) =>
      prec.left(
        9,
        seq(field("operator", "-"), field("operand", $._expression)),
      ),

    /// The Zig parser borrows C's operator precedence: `*` `/` bind tighter
    /// than `+` `-`, which bind tighter than the comparisons. All operators are
    /// left associative.
    binary_expression: ($) =>
      choice(
        prec.left(
          3,
          seq(
            field("left", $._expression),
            field("operator", choice("*", "/")),
            field("right", $._expression),
          ),
        ),
        prec.left(
          2,
          seq(
            field("left", $._expression),
            field("operator", choice("+", "-")),
            field("right", $._expression),
          ),
        ),
        prec.left(
          1,
          seq(
            field("left", $._expression),
            field("operator", choice(">", "<", ">=", "<=")),
            field("right", $._expression),
          ),
        ),
      ),

    /// `name(arg, arg)`
    call: ($) =>
      seq(field("function", $.identifier), field("arguments", $.arguments)),

    arguments: ($) =>
      seq("(", optional(commaSep1(field("parameter", $._expression))), ")"),

    /// A `.dotted.path` reference into the data being graphed, optionally
    /// followed by an access type: `.kalmanPosZ_m_agl:last`.
    keyref: ($) =>
      seq(
        field("path", $.keyref_path),
        optional(field("access", $.access_type)),
      ),

    keyref_path: (_) => token(/[.][a-zA-Z0-9_.]*/),

    /// `:first`, `:last`, `:min`, `:max`, `:mean`, `:current`, `:prev`.
    /// The name is validated after the fact, so it is a plain identifier here.
    access_type: ($) => seq(":", field("name", $.identifier)),

    /// `#name`, referring to a key that declared that name.
    value_ref: ($) =>
      seq(
        "#",
        field("name", $.identifier),
        optional(field("access", $.access_type)),
      ),

    /// `!#name`, referencing a declared value directly.
    naked_value_ref: ($) => seq("!", field("name", $.value_ref)),

    string: (_) =>
      token(choice(seq('"', /[^"]*/, '"'), seq("'", /[^']*/, "'"))),

    number: (_) => token(/[0-9]+([.][0-9]*)?/),

    /// The Zig lexer rejects a `-` that is not immediately followed by a number,
    /// so a negative value is only ever a plain literal, never an expression.
    negative_number: (_) => token(seq("-", /[0-9]+([.][0-9]*)?/)),

    identifier: (_) => /[a-zA-Z_][a-zA-Z0-9_]*/,

    comment: (_) => token(/;[^\n]*/),
  },
});

/**
 * Creates a rule matching one or more occurrences of `rule`, separated by
 * commas.
 *
 * @param {RuleOrLiteral} rule
 * @returns {SeqRule}
 */
function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)));
}
